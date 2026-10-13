// .npcproj loading, static checks, request building and the sample project.
#include "Project.hpp"
#include "Codec.hpp"
#include "CodecInternal.hpp"

#include <algorithm>
#include <fstream>
#include <set>
#include <sstream>
#include <stdexcept>

namespace npc::dialogue {

namespace fs=std::filesystem;
using codec::detail::characterAt;
using codec::detail::commandSpecAt;
using codec::detail::fallbackAt;
using codec::detail::factAt;
using codec::detail::worldAt;
using io::Reader;
using io::Writer;
using io::listOf;

namespace {

std::string readFile(const fs::path& p){
    std::ifstream in(p,std::ios::binary);
    if(!in) throw std::runtime_error("cannot read "+p.string());
    std::ostringstream ss;ss<<in.rdbuf();
    return ss.str();
}
void writeFile(const fs::path& p,std::string_view text){
    std::ofstream out(p,std::ios::binary|std::ios::trunc);
    if(!out) throw std::runtime_error("cannot write "+p.string());
    out<<text;
}

ProjectDefaults defaultsAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    ProjectDefaults d;
    if(const auto* b=r.get("budget")) d.budget=codec::detail::budgetAt(*b,r.pathOf("budget"));
    if(const auto* s=r.get("sampling")) d.sampling=codec::detail::samplingAt(*s,r.pathOf("sampling"));
    d.maxCommands=r.u32("maxCommands",d.maxCommands);
    r.finish();
    return d;
}

// Splits the project-only keys off a character file, then decodes the profile strictly.
ProjectCharacter characterFile(const json::Value& root,const std::string& path){
    if(root.kind!=json::Kind::Object) io::fail(path,"expected an object");
    json::Value profile=root;
    profile.object.clear();
    const json::Value* fallbacks=nullptr;
    const json::Value* commands=nullptr;
    for(const auto& kv:root.object){
        if(kv.first=="fallbacks") fallbacks=&kv.second;
        else if(kv.first=="commands") commands=&kv.second;
        else profile.object.push_back(kv);
    }
    ProjectCharacter c;
    c.profile=characterAt(profile,path);
    json::Value extra;extra.kind=json::Kind::Object;
    if(fallbacks) extra.object.emplace_back("fallbacks",*fallbacks);
    if(commands) extra.object.emplace_back("commands",*commands);
    Reader r(extra,path);
    c.fallbacks=listOf<FallbackLine>(r,"fallbacks",fallbackAt);
    c.commandKinds=r.strings("commands");
    r.finish();
    return c;
}

Pronunciation pronunciationAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    Pronunciation p{r.str("word"),r.str("phonemes"),Language::English};
    if(const auto* l=r.get("language")) p.language=codec::detail::languageAt(*l,r.pathOf("language"));
    r.finish();
    if(p.word.empty()) io::fail(path+".word","must not be empty");
    if(p.phonemes.empty()) io::fail(path+".phonemes","must not be empty");
    return p;
}

void writePronunciations(Writer& w,const std::vector<Pronunciation>& ps){
    w.beginArray();
    for(const auto& p:ps){w.beginObject();w.key("word").string(p.word);w.key("phonemes").string(p.phonemes);w.key("language").string(languageTag(p.language));w.endObject();}
    w.endArray();
}

void writeFact(Writer& w,const Fact& f){
    w.beginObject();
    w.key("id").string(f.id);w.key("text").string(f.text);
    w.key("knownBy").strings(f.knownBy);w.key("requiredFlags").strings(f.requiredFlags);
    w.key("tags").strings(f.tags);w.key("leakKeywords").strings(f.leakKeywords);
    w.key("salience").number(f.salience);
    w.endObject();
}
void writeCommand(Writer& w,const CommandSpec& c){
    w.beginObject();
    w.key("kind").string(c.kind);w.key("description").string(c.description);w.key("targets").strings(c.allowedTargets);
    w.endObject();
}
void writeBudget(Writer& w,const Budget& b){
    w.beginObject();
    w.key("deadlineMs").number(static_cast<double>(b.deadline.count()));
    w.key("maxOutputTokens").number(b.maxOutputTokens);
    w.key("maxPromptTokens").number(b.maxPromptTokens);
    w.key("maxFacts").number(b.maxFacts);
    w.key("maxPerception").number(b.maxPerception);
    w.key("maxExchanges").number(b.maxExchanges);
    w.key("maxMemories").number(b.maxMemories);
    w.endObject();
}

std::string asciiLower(std::string_view s){
    std::string r(s);
    for(char& c:r) if(c>='A'&&c<='Z') c=static_cast<char>(c-'A'+'a');
    return r;
}

} // namespace

const ProjectCharacter* Project::character(std::string_view id) const{
    for(const auto& c:characters) if(c.profile.id==id) return &c;
    return nullptr;
}

const std::vector<std::string>& knownVoices(){
    static const std::vector<std::string> v{"af_heart","af_bella","am_michael","am_fenrir","jf_alpha","jf_tebukuro","jm_kumo"};
    return v;
}
std::optional<Language> voiceLanguage(std::string_view voice){
    if(voice.empty()) return std::nullopt;
    if(voice[0]=='a'||voice[0]=='b') return Language::English;
    if(voice[0]=='j') return Language::Japanese;
    return std::nullopt;
}

// ---------------------------------------------------------------- load

Project loadProject(const fs::path& dir){
    if(!fs::is_directory(dir)) throw std::runtime_error("not a project folder: "+dir.string());
    Project p;
    p.name=dir.filename().replace_extension().string();
    {
        const auto file=dir/"project.json";
        auto root=io::parseDocument(readFile(file),"project.json");
        Reader r(root,"project.json");
        if(r.str("format")!="npcvoice-project") io::fail(r.pathOf("format"),"expected \"npcvoice-project\"");
        if(r.u32("version",0)!=1) io::fail(r.pathOf("version"),"unsupported version (this build reads version 1)");
        if(const auto* n=r.get("name");n&&n->kind==json::Kind::String&&!n->string.empty()) p.name=n->string;
        if(const auto* w=r.get("world")) p.world=worldAt(*w,r.pathOf("world"));
        if(const auto* d=r.get("defaults")) p.defaults=defaultsAt(*d,r.pathOf("defaults"));
        p.pronunciations=listOf<Pronunciation>(r,"pronunciations",pronunciationAt);
        r.finish();
    }
    if(fs::exists(dir/"facts.json")){
        auto root=io::parseDocument(readFile(dir/"facts.json"),"facts.json");
        Reader r(root,"facts.json");
        p.facts=listOf<Fact>(r,"facts",factAt);
        r.finish();
    }
    if(fs::exists(dir/"commands.json")){
        auto root=io::parseDocument(readFile(dir/"commands.json"),"commands.json");
        Reader r(root,"commands.json");
        p.commands=listOf<CommandSpec>(r,"commands",commandSpecAt);
        r.finish();
    }
    if(fs::is_directory(dir/"characters")){
        std::vector<fs::path> files;
        for(const auto& e:fs::directory_iterator(dir/"characters"))
            if(e.is_regular_file()&&e.path().extension()==".json") files.push_back(e.path());
        std::sort(files.begin(),files.end());
        for(const auto& f:files){
            const std::string rel="characters/"+f.filename().string();
            auto root=io::parseDocument(readFile(f),rel);
            p.characters.push_back(characterFile(root,rel));
        }
    }
    return p;
}

Project decodeProject(std::string_view text){
    auto root=io::parseDocument(text,"project");
    Reader r(root,"project");
    Project p;
    p.name=r.str("name");
    if(const auto* w=r.get("world")) p.world=worldAt(*w,r.pathOf("world"));
    if(const auto* d=r.get("defaults")) p.defaults=defaultsAt(*d,r.pathOf("defaults"));
    p.characters=listOf<ProjectCharacter>(r,"characters",characterFile);
    p.facts=listOf<Fact>(r,"facts",factAt);
    p.commands=listOf<CommandSpec>(r,"commands",commandSpecAt);
    p.pronunciations=listOf<Pronunciation>(r,"pronunciations",pronunciationAt);
    r.finish();
    std::sort(p.characters.begin(),p.characters.end(),[](const ProjectCharacter& a,const ProjectCharacter& b){return a.profile.id<b.profile.id;});
    return p;
}

// ---------------------------------------------------------------- static checks

std::vector<ProjectDiagnostic> diagnose(const Project& p){
    using S=ProjectDiagnostic::Severity;
    std::vector<ProjectDiagnostic> d;
    auto add=[&](S s,std::string path,std::string msg){d.push_back({s,std::move(path),std::move(msg)});};
    if(p.characters.empty()) add(S::Warning,"characters/","the project has no characters yet");

    std::set<std::string> ids;
    for(const auto& c:p.characters) ids.insert(c.profile.id);
    std::set<std::string> commandKinds;
    for(const auto& c:p.commands){
        if(!commandKinds.insert(c.kind).second) add(S::Error,"commands.json: "+c.kind,"duplicate command kind");
    }
    std::set<std::string> factIds;
    for(const auto& f:p.facts){
        if(!factIds.insert(f.id).second) add(S::Error,"facts.json: "+f.id,"duplicate fact id");
        for(const auto& k:f.knownBy) if(!ids.contains(k)) add(S::Warning,"facts.json: "+f.id+".knownBy","unknown character '"+k+"'");
    }

    std::set<std::pair<std::string,int>> words;
    for(const auto& pr:p.pronunciations)
        if(!words.insert({pr.word,static_cast<int>(pr.language)}).second)
            add(S::Error,"project.json: pronunciations","duplicate pronunciation for '"+pr.word+"'");

    std::set<std::string> seen;
    for(const auto& pc:p.characters){
        const auto& c=pc.profile;
        const std::string file="characters/"+c.id+".json";
        if(c.id.empty()){add(S::Error,"characters/","a character has an empty id");continue;}
        if(!seen.insert(c.id).second) add(S::Error,file+": id","duplicate character id");
        if(c.displayName.empty()) add(S::Error,file+": displayName","is required");
        if(c.persona.empty()) add(S::Warning,file+": persona","is empty; lines will be generic");
        if(c.voiceId.empty()) add(S::Error,file+": voice","is required");
        else{
            const auto& known=knownVoices();
            if(std::find(known.begin(),known.end(),c.voiceId)==known.end())
                add(S::Warning,file+": voice","'"+c.voiceId+"' is not a bundled voice; speech will be unavailable");
            else if(voiceLanguage(c.voiceId)!=c.language)
                add(S::Error,file+": voice","'"+c.voiceId+"' does not speak "+std::string(languageTag(c.language)));
        }
        for(const auto& rel:c.relationships)
            if(rel.targetId!="player"&&!ids.contains(rel.targetId))
                add(S::Warning,file+": relationships","unknown character '"+rel.targetId+"'");
        for(const auto& k:pc.commandKinds)
            if(!commandKinds.contains(k)) add(S::Error,file+": commands","unknown command '"+k+"'");
        if(pc.fallbacks.empty()) add(S::Warning,file+": fallbacks","no fallback lines; the built-in default line will be used");
        for(const auto& f:pc.fallbacks){
            const std::string folded=asciiLower(f.text);
            for(const auto& t:c.forbiddenTerms)
                if(!t.empty()&&folded.find(asciiLower(t))!=std::string::npos)
                    add(S::Error,file+": fallbacks","fallback line uses forbidden term '"+t+"'");
            if(!c.allowedIntents.empty()&&std::find(c.allowedIntents.begin(),c.allowedIntents.end(),f.intent)==c.allowedIntents.end())
                add(S::Warning,file+": fallbacks","fallback intent '"+std::string(intentToken(f.intent))+"' is not in allowedIntents");
        }
        // The full prompt must fit the budget with every fact this character could know.
        try{
            DialogueRequest probe;
            probe.world=p.world;probe.character=c;probe.context.facts=p.facts;
            probe.playerUtterance="Hello.";probe.budget=p.defaults.budget;
            (void)preparePrompt(probe);
        }catch(const std::exception& e){add(S::Error,file,std::string("prompt check failed: ")+e.what());}
    }
    return d;
}

std::string encodeDiagnostics(const std::vector<ProjectDiagnostic>& d){
    Writer w;
    w.beginArray();
    for(const auto& x:d){
        w.beginObject();
        w.key("severity").string(x.severity==ProjectDiagnostic::Severity::Error?"error":"warning");
        w.key("path").string(x.path);
        w.key("message").string(x.message);
        w.endObject();
    }
    w.endArray();
    return w.take();
}

std::string encodeProject(const Project& p){
    Writer w;
    w.beginObject();
    w.key("name").string(p.name);
    w.key("world");codec::detail::writeWorld(w,p.world);
    w.key("defaults").beginObject();
    w.key("budget");writeBudget(w,p.defaults.budget);
    w.key("sampling");codec::detail::writeSampling(w,p.defaults.sampling);
    w.key("maxCommands").number(p.defaults.maxCommands);
    w.endObject();
    w.key("characters").beginArray();
    for(const auto& c:p.characters){
        // A character object plus its project-only keys.
        Writer cw;codec::detail::writeCharacter(cw,c.profile);
        std::string obj=cw.take();
        obj.pop_back();
        Writer extra;
        extra.beginObject();
        extra.key("fallbacks").beginArray();
        for(const auto& f:c.fallbacks){extra.beginObject();extra.key("text").string(f.text);extra.key("intent").string(intentToken(f.intent));extra.key("emotion").string(emotionToken(f.emotion));extra.endObject();}
        extra.endArray();
        extra.key("commands").strings(c.commandKinds);
        extra.endObject();
        std::string e=extra.take();
        obj+=","+e.substr(1);
        w.raw(obj);
    }
    w.endArray();
    w.key("facts").beginArray();
    for(const auto& f:p.facts) writeFact(w,f);
    w.endArray();
    w.key("commands").beginArray();
    for(const auto& c:p.commands) writeCommand(w,c);
    w.endArray();
    w.key("pronunciations");writePronunciations(w,p.pronunciations);
    w.endObject();
    return w.take();
}

// ---------------------------------------------------------------- game calls

DialogueRequest buildRequest(const Project& p,std::string_view callJson){
    auto root=io::parseDocument(callJson,"call");
    Reader r(root,"call");
    const std::string id=r.str("character");
    if(id.empty()) io::fail(r.pathOf("character"),"is required");
    const ProjectCharacter* pc=p.character(id);
    if(!pc) io::fail(r.pathOf("character"),"no character '"+id+"' in project '"+p.name+"'");

    DialogueRequest q;
    q.world=p.world;
    q.character=pc->profile;
    if(auto mood=r.str("mood");!mood.empty()) q.character.mood=mood;
    // The model sees names, not ids ("Tamsin Reed: a smuggler...").
    for(auto& rel:q.character.relationships)
        if(const ProjectCharacter* other=p.character(rel.targetId)) rel.targetId=other->profile.displayName;
    q.context.facts=p.facts;
    q.context.progressFlags=r.strings("flags");
    q.context.location=r.str("location");
    q.context.objective=r.str("objective");
    // Reuse the request decoders for the structured context lists.
    {
        json::Value ctx;ctx.kind=json::Kind::Object;
        for(const char* k:{"perception","exchanges","memories","topics"})
            if(const auto* v=r.get(k)) ctx.object.emplace_back(k,*v);
        auto c=codec::detail::contextAt(ctx,"call");
        q.context.perception=std::move(c.perception);
        q.context.recentExchanges=std::move(c.recentExchanges);
        q.context.memories=std::move(c.memories);
        q.context.topicTags=std::move(c.topicTags);
    }
    q.playerUtterance=r.str("playerUtterance");
    q.trigger=r.str("trigger");
    for(const auto& kind:pc->commandKinds){
        auto it=std::find_if(p.commands.begin(),p.commands.end(),[&](const CommandSpec& s){return s.kind==kind;});
        if(it==p.commands.end()) io::fail("characters/"+id+".json: commands","unknown command '"+kind+"'");
        q.commands.push_back(*it);
    }
    q.maxCommands=r.u32("maxCommands",p.defaults.maxCommands);
    q.fallbacks=pc->fallbacks;
    q.budget=p.defaults.budget;
    if(const auto* b=r.get("budget")) q.budget=codec::detail::budgetAt(*b,r.pathOf("budget"));
    q.sampling=p.defaults.sampling;
    if(const auto* s=r.get("sampling")) q.sampling=codec::detail::samplingAt(*s,r.pathOf("sampling"));
    q.allowCache=r.boolean("allowCache",true);
    q.priority=r.u32("priority",0);
    r.finish();
    if(q.playerUtterance.empty()&&q.trigger.empty()) io::fail("call","needs \"playerUtterance\" or \"trigger\"");
    return q;
}

// ---------------------------------------------------------------- sample

namespace {
constexpr std::string_view SampleProject=R"({
  "format": "npcvoice-project",
  "version": 1,
  "name": "Harbor Town",
  "world": {
    "name": "Harbor Town",
    "setting": "A rain-soaked fishing port on the edge of a crumbling kingdom. Smugglers outnumber honest sailors, and the tide brings strange cargo.",
    "tone": "Wry, grounded low fantasy with moments of warmth",
    "contentRating": "Teen: mild peril, no profanity, no graphic violence",
    "rules": [
      "There is no magic anyone can rely on; rumors of it are just rumors.",
      "Coin is silver marks; a room costs three marks a night."
    ]
  },
  "defaults": {
    "maxCommands": 2
  },
  "pronunciations": [
    {"word": "Saltwren", "phonemes": "sˈɔltɹɛn", "language": "en"},
    {"word": "Tamsin", "phonemes": "tˈæmzɪn", "language": "en"}
  ]
}
)";

constexpr std::string_view SampleFacts=R"({
  "facts": [
    {"id": "tide_tonight", "text": "The high tide tonight is the highest in ten years.", "tags": ["weather", "harbor"], "salience": 0.6},
    {"id": "room_price", "text": "A room at the Gull & Lantern costs three silver marks a night.", "knownBy": ["marta"], "tags": ["room", "inn", "price"], "salience": 0.7},
    {"id": "missing_ship", "text": "The merchant ship Saltwren is three days overdue.", "tags": ["rumor", "ship"], "salience": 0.6},
    {"id": "east_gate", "text": "The east gate closes at the eighth bell, and nobody passes after without a writ.", "knownBy": ["rhys", "marta"], "tags": ["gate", "curfew"], "salience": 0.6},
    {"id": "smuggler_cave", "text": "The Saltwren's cargo is hidden in the sea cave below the lighthouse.", "knownBy": ["tamsin"], "requiredFlags": ["earned_tamsin_trust"], "tags": ["ship", "cargo", "rumor"], "leakKeywords": ["sea cave", "lighthouse cave", "below the lighthouse"], "salience": 0.9},
    {"id": "rhys_debt", "text": "Captain Rhys owes Tamsin forty marks from a card game.", "knownBy": ["tamsin", "rhys"], "tags": ["rhys", "debt"], "leakKeywords": ["forty marks", "card debt"], "salience": 0.5},
    {"id": "shrine_bell", "text": "海辺の祠の鈴は、嵐の前の晩にひとりでに鳴る。", "knownBy": ["aiko"], "tags": ["shrine", "rumor", "weather"], "salience": 0.7}
  ]
}
)";

constexpr std::string_view SampleCommands=R"({
  "commands": [
    {"kind": "give_item", "description": "Hand the player an item you have", "targets": ["room_key", "harbor_map", "lantern"]},
    {"kind": "open_gate", "description": "Open the east gate for the player"},
    {"kind": "call_guards", "description": "Shout for the town guard"},
    {"kind": "follow_player", "description": "Start walking with the player"}
  ]
}
)";

constexpr std::string_view SampleMarta=R"({
  "id": "marta",
  "displayName": "Marta Venn",
  "role": "innkeeper of the Gull & Lantern",
  "persona": "A widowed innkeeper who has heard every sailor's lie twice and still feeds the ones who cannot pay.",
  "traits": ["warm", "shrewd", "gossipy", "protective of regulars"],
  "goals": ["keep the inn full before the storm", "find out what happened to the Saltwren"],
  "mood": "busy but cheerful",
  "relationships": [
    {"target": "player", "description": "a new face; possibly trouble, possibly a paying guest"},
    {"target": "rhys", "description": "an honest man who drinks too much on rest days"}
  ],
  "speechStyle": "Brisk, motherly, fond of calling people 'love'. Short sentences.",
  "voice": "af_heart",
  "language": "en",
  "allowedEmotions": ["neutral", "happy", "concentration", "fatigue", "surprise", "sad", "contempt"],
  "allowedIntents": ["inform", "greet", "farewell", "request", "deflect", "warn", "refuse"],
  "forbiddenTopics": ["her late husband"],
  "forbiddenTerms": [],
  "fallbacks": [
    {"text": "Busy night, love. Ask me again in a moment.", "intent": "deflect", "emotion": "concentration"},
    {"text": "Not a chance, love.", "intent": "refuse", "emotion": "contempt"},
    {"text": "Welcome to the Gull & Lantern. Mind the puddle.", "intent": "greet", "emotion": "happy"}
  ],
  "commands": ["give_item"]
}
)";

constexpr std::string_view SampleRhys=R"({
  "id": "rhys",
  "displayName": "Captain Rhys Hallow",
  "role": "captain of the east gate watch",
  "persona": "A tired, by-the-book watch captain who wants to retire before something goes badly wrong on his watch.",
  "traits": ["dutiful", "suspicious", "dry humor", "secretly in debt"],
  "goals": ["keep the gate closed after the eighth bell", "hide his card debt"],
  "relationships": [
    {"target": "player", "description": "a stranger who should prove they are not a smuggler"},
    {"target": "tamsin", "description": "a smuggler he cannot afford to arrest"}
  ],
  "speechStyle": "Clipped and formal, military cadence. Never jokes about the law.",
  "voice": "am_michael",
  "language": "en",
  "allowedEmotions": ["neutral", "angry", "fatigue", "contempt", "surprise", "concentration"],
  "forbiddenTopics": ["his card debts"],
  "forbiddenTerms": ["forty marks"],
  "fallbacks": [
    {"text": "Move along. The watch is busy.", "intent": "deflect", "emotion": "fatigue"},
    {"text": "No writ, no passage.", "intent": "refuse", "emotion": "neutral"}
  ],
  "commands": ["open_gate", "call_guards"]
}
)";

constexpr std::string_view SampleTamsin=R"({
  "id": "tamsin",
  "displayName": "Tamsin Reed",
  "role": "smuggler",
  "persona": "A charming smuggler who trades in secrets as readily as in contraband, and never gives either away for free.",
  "traits": ["charming", "evasive", "loyal to her crew", "allergic to the watch"],
  "goals": ["move the Saltwren cargo before the tide turns", "find out whether the player can be trusted"],
  "relationships": [
    {"target": "player", "description": "a potential partner, if they can keep their mouth shut"},
    {"target": "rhys", "description": "a useful fool who owes her money"}
  ],
  "speechStyle": "Playful, teasing, answers questions with questions. Uses sailing slang.",
  "voice": "am_fenrir",
  "language": "en",
  "allowedEmotions": ["neutral", "happy", "contempt", "surprise", "concentration", "fear"],
  "forbiddenTerms": [],
  "fallbacks": [
    {"text": "Now why would I tell you that?", "intent": "deflect", "emotion": "contempt"},
    {"text": "Ask me when the tide turns.", "intent": "deflect", "emotion": "happy"}
  ],
  "commands": ["follow_player"]
}
)";

constexpr std::string_view SampleAiko=R"({
  "id": "aiko",
  "displayName": "アイコ",
  "role": "海辺の祠の守り人",
  "persona": "異国から流れ着き、港の外れの小さな祠を守っている静かな女性。",
  "traits": ["物静か", "観察眼が鋭い", "迷信深い"],
  "goals": ["嵐の前に祠を守ること"],
  "relationships": [
    {"target": "player", "description": "興味深い旅人"}
  ],
  "speechStyle": "丁寧語で、短く静かに話す。",
  "voice": "jf_alpha",
  "language": "ja",
  "fallbacks": [
    {"text": "……今は、お答えできません。", "intent": "deflect", "emotion": "neutral"},
    {"text": "ようこそ、旅の方。", "intent": "greet", "emotion": "happy"}
  ],
  "commands": []
}
)";
} // namespace

void writeSampleProject(const fs::path& dir){
    if(fs::exists(dir)) throw std::runtime_error("already exists: "+dir.string());
    fs::create_directories(dir/"characters");
    writeFile(dir/"project.json",SampleProject);
    writeFile(dir/"facts.json",SampleFacts);
    writeFile(dir/"commands.json",SampleCommands);
    writeFile(dir/"characters"/"marta.json",SampleMarta);
    writeFile(dir/"characters"/"rhys.json",SampleRhys);
    writeFile(dir/"characters"/"tamsin.json",SampleTamsin);
    writeFile(dir/"characters"/"aiko.json",SampleAiko);
}

} // namespace npc::dialogue
