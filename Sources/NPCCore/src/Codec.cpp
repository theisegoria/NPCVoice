// JSON contract for the dialogue core (docs/JSON.md).
#include "Codec.hpp"
#include "DialogueJson.hpp"
#include "CodecInternal.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>

namespace npc::dialogue::codec {

using io::Reader;
using io::Writer;
using io::listOf;

namespace detail {

Language languageAt(const json::Value& v,const std::string& path){
    if(v.kind!=json::Kind::String) io::fail(path,"expected a language tag");
    auto l=parseLanguageTag(v.string);
    if(!l) io::fail(path,"unsupported language '"+v.string+"' (expected \"en\" or \"ja\")");
    return *l;
}
Emotion emotionAt(const json::Value& v,const std::string& path){
    if(v.kind!=json::Kind::String) io::fail(path,"expected an emotion token");
    auto e=parseEmotionToken(v.string);
    if(!e) io::fail(path,"unknown emotion '"+v.string+"'");
    return *e;
}
Intent intentAt(const json::Value& v,const std::string& path){
    if(v.kind!=json::Kind::String) io::fail(path,"expected an intent token");
    auto i=parseIntentToken(v.string);
    if(!i) io::fail(path,"unknown intent '"+v.string+"'");
    return *i;
}
std::string_view speakerToken(Speaker s){return s==Speaker::Player?"player":s==Speaker::Character?"character":"other";}

WorldProfile worldAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    WorldProfile w;
    w.name=r.str("name");
    w.setting=r.str("setting");
    w.tone=r.str("tone");
    w.contentRating=r.str("contentRating");
    w.rules=r.strings("rules");
    r.finish();
    return w;
}

CharacterProfile characterAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    CharacterProfile c;
    c.id=r.str("id");
    c.displayName=r.str("displayName");
    c.role=r.str("role");
    c.persona=r.str("persona");
    c.traits=r.strings("traits");
    c.goals=r.strings("goals");
    c.mood=r.str("mood");
    c.relationships=listOf<Relationship>(r,"relationships",[](const json::Value& x,const std::string& p){
        Reader rr(x,p);
        Relationship rel{rr.str("target"),rr.str("description")};
        rr.finish();
        if(rel.targetId.empty()) io::fail(p+".target","must not be empty");
        return rel;});
    c.speechStyle=r.str("speechStyle");
    c.voiceId=r.str("voice");
    if(const auto* l=r.get("language")) c.language=languageAt(*l,r.pathOf("language"));
    c.allowedEmotions=listOf<Emotion>(r,"allowedEmotions",emotionAt);
    c.allowedIntents=listOf<Intent>(r,"allowedIntents",intentAt);
    c.maxLineCodePoints=r.u32("maxLineCharacters",0);
    c.forbiddenTopics=r.strings("forbiddenTopics");
    c.forbiddenTerms=r.strings("forbiddenTerms");
    r.finish();
    return c;
}

Fact factAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    Fact f;
    f.id=r.str("id");
    f.text=r.str("text");
    f.knownBy=r.strings("knownBy");
    f.requiredFlags=r.strings("requiredFlags");
    f.tags=r.strings("tags");
    f.leakKeywords=r.strings("leakKeywords");
    f.salience=static_cast<float>(r.number("salience",0.5));
    r.finish();
    if(f.id.empty()) io::fail(path+".id","must not be empty");
    if(f.text.empty()) io::fail(path+".text","must not be empty");
    if(!(f.salience>=0&&f.salience<=1)) io::fail(path+".salience","must be within [0, 1]");
    return f;
}

CommandSpec commandSpecAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    CommandSpec c{r.str("kind"),r.str("description"),r.strings("targets")};
    r.finish();
    if(c.kind.empty()) io::fail(path+".kind","must not be empty");
    return c;
}

FallbackLine fallbackAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    FallbackLine f;
    f.text=r.str("text");
    if(const auto* i=r.get("intent")) f.intent=intentAt(*i,r.pathOf("intent"));
    if(const auto* e=r.get("emotion")) f.emotion=emotionAt(*e,r.pathOf("emotion"));
    r.finish();
    if(f.text.empty()) io::fail(path+".text","must not be empty");
    return f;
}

GroundingContext contextAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    GroundingContext x;
    x.facts=listOf<Fact>(r,"facts",factAt);
    x.progressFlags=r.strings("progressFlags");
    x.location=r.str("location");
    x.objective=r.str("objective");
    x.perception=listOf<Observation>(r,"perception",[](const json::Value& o,const std::string& p){
        if(o.kind==json::Kind::String) return Observation{o.string,0.5f};
        Reader rr(o,p);
        Observation ob{rr.str("text"),static_cast<float>(rr.number("salience",0.5))};
        rr.finish();
        return ob;});
    x.recentExchanges=listOf<Exchange>(r,"exchanges",[](const json::Value& o,const std::string& p){
        Reader rr(o,p);
        Exchange e;
        const std::string s=rr.str("speaker","player");
        if(s=="player") e.speaker=Speaker::Player;
        else if(s=="character") e.speaker=Speaker::Character;
        else if(s=="other") e.speaker=Speaker::Other;
        else io::fail(rr.pathOf("speaker"),"expected \"player\", \"character\" or \"other\"");
        e.text=rr.str("text");
        rr.finish();
        return e;});
    x.memories=r.strings("memories");
    x.topicTags=r.strings("topics");
    r.finish();
    return x;
}

Budget budgetAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    Budget b;
    b.deadline=std::chrono::milliseconds(r.u32("deadlineMs",static_cast<std::uint32_t>(b.deadline.count())));
    b.maxOutputTokens=r.u32("maxOutputTokens",b.maxOutputTokens);
    b.maxPromptTokens=r.u32("maxPromptTokens",b.maxPromptTokens);
    b.maxFacts=r.u32("maxFacts",b.maxFacts);
    b.maxPerception=r.u32("maxPerception",b.maxPerception);
    b.maxExchanges=r.u32("maxExchanges",b.maxExchanges);
    b.maxMemories=r.u32("maxMemories",b.maxMemories);
    r.finish();
    return b;
}

Sampling samplingAt(const json::Value& v,const std::string& path){
    Reader r(v,path);
    Sampling s;
    s.greedy=r.boolean("greedy",s.greedy);
    s.temperature=r.number("temperature",s.temperature);
    s.seed=r.u64("seed",0);
    r.finish();
    return s;
}

void writeWorld(Writer& w,const WorldProfile& x){
    w.beginObject();
    w.key("name").string(x.name);
    w.key("setting").string(x.setting);
    w.key("tone").string(x.tone);
    w.key("contentRating").string(x.contentRating);
    w.key("rules").strings(x.rules);
    w.endObject();
}
void writeCharacter(Writer& w,const CharacterProfile& c){
    w.beginObject();
    w.key("id").string(c.id);
    w.key("displayName").string(c.displayName);
    w.key("role").string(c.role);
    w.key("persona").string(c.persona);
    w.key("traits").strings(c.traits);
    w.key("goals").strings(c.goals);
    w.key("mood").string(c.mood);
    w.key("relationships").beginArray();
    for(const auto& r:c.relationships){w.beginObject();w.key("target").string(r.targetId);w.key("description").string(r.description);w.endObject();}
    w.endArray();
    w.key("speechStyle").string(c.speechStyle);
    w.key("voice").string(c.voiceId);
    w.key("language").string(languageTag(c.language));
    w.key("allowedEmotions").beginArray();
    for(auto e:c.allowedEmotions) w.string(emotionToken(e));
    w.endArray();
    w.key("allowedIntents").beginArray();
    for(auto i:c.allowedIntents) w.string(intentToken(i));
    w.endArray();
    w.key("maxLineCharacters").number(c.maxLineCodePoints);
    w.key("forbiddenTopics").strings(c.forbiddenTopics);
    w.key("forbiddenTerms").strings(c.forbiddenTerms);
    w.endObject();
}
void writeSampling(Writer& w,const Sampling& s){
    w.beginObject();
    w.key("greedy").boolean(s.greedy);
    w.key("temperature").number(s.temperature);
    w.key("seed").number(static_cast<double>(s.seed));
    w.endObject();
}
std::string hex64(std::uint64_t v){
    char buf[17];
    std::snprintf(buf,sizeof buf,"%016llx",static_cast<unsigned long long>(v));
    return buf;
}

} // namespace detail
using namespace detail;

// ---------------------------------------------------------------- requests

DialogueRequest decodeRequest(std::string_view text){
    auto root=io::parseDocument(text,"request");
    Reader r(root,"request");
    DialogueRequest q;
    if(const auto* v=r.get("world")) q.world=worldAt(*v,r.pathOf("world"));
    const auto* ch=r.get("character");
    if(!ch) io::fail(r.pathOf("character"),"is required");
    q.character=characterAt(*ch,r.pathOf("character"));
    if(const auto* v=r.get("context")) q.context=contextAt(*v,r.pathOf("context"));
    q.playerUtterance=r.str("playerUtterance");
    q.trigger=r.str("trigger");
    q.commands=listOf<CommandSpec>(r,"commands",commandSpecAt);
    q.maxCommands=r.u32("maxCommands",q.maxCommands);
    q.fallbacks=listOf<FallbackLine>(r,"fallbacks",fallbackAt);
    if(const auto* v=r.get("budget")) q.budget=budgetAt(*v,r.pathOf("budget"));
    if(const auto* v=r.get("sampling")) q.sampling=samplingAt(*v,r.pathOf("sampling"));
    q.allowCache=r.boolean("allowCache",q.allowCache);
    q.priority=r.u32("priority",0);
    r.finish();
    return q;
}

std::string encodeRequest(const DialogueRequest& q){
    Writer w;
    w.beginObject();
    w.key("world");writeWorld(w,q.world);
    w.key("character");writeCharacter(w,q.character);
    w.key("context").beginObject();
    w.key("facts").beginArray();
    for(const auto& f:q.context.facts){
        w.beginObject();
        w.key("id").string(f.id);w.key("text").string(f.text);
        w.key("knownBy").strings(f.knownBy);w.key("requiredFlags").strings(f.requiredFlags);
        w.key("tags").strings(f.tags);w.key("leakKeywords").strings(f.leakKeywords);
        w.key("salience").number(f.salience);
        w.endObject();
    }
    w.endArray();
    w.key("progressFlags").strings(q.context.progressFlags);
    w.key("location").string(q.context.location);
    w.key("objective").string(q.context.objective);
    w.key("perception").beginArray();
    for(const auto& o:q.context.perception){w.beginObject();w.key("text").string(o.text);w.key("salience").number(o.salience);w.endObject();}
    w.endArray();
    w.key("exchanges").beginArray();
    for(const auto& e:q.context.recentExchanges){w.beginObject();w.key("speaker").string(speakerToken(e.speaker));w.key("text").string(e.text);w.endObject();}
    w.endArray();
    w.key("memories").strings(q.context.memories);
    w.key("topics").strings(q.context.topicTags);
    w.endObject();
    w.key("playerUtterance").string(q.playerUtterance);
    w.key("trigger").string(q.trigger);
    w.key("commands").beginArray();
    for(const auto& c:q.commands){w.beginObject();w.key("kind").string(c.kind);w.key("description").string(c.description);w.key("targets").strings(c.allowedTargets);w.endObject();}
    w.endArray();
    w.key("maxCommands").number(q.maxCommands);
    w.key("fallbacks").beginArray();
    for(const auto& f:q.fallbacks){w.beginObject();w.key("text").string(f.text);w.key("intent").string(intentToken(f.intent));w.key("emotion").string(emotionToken(f.emotion));w.endObject();}
    w.endArray();
    w.key("budget").beginObject();
    w.key("deadlineMs").number(static_cast<double>(q.budget.deadline.count()));
    w.key("maxOutputTokens").number(q.budget.maxOutputTokens);
    w.key("maxPromptTokens").number(q.budget.maxPromptTokens);
    w.key("maxFacts").number(q.budget.maxFacts);
    w.key("maxPerception").number(q.budget.maxPerception);
    w.key("maxExchanges").number(q.budget.maxExchanges);
    w.key("maxMemories").number(q.budget.maxMemories);
    w.endObject();
    w.key("sampling");writeSampling(w,q.sampling);
    w.key("allowCache").boolean(q.allowCache);
    w.key("priority").number(q.priority);
    w.endObject();
    return w.take();
}

WorldProfile decodeWorld(std::string_view text){return worldAt(io::parseDocument(text,"world"),"world");}
CharacterProfile decodeCharacter(std::string_view text){return characterAt(io::parseDocument(text,"character"),"character");}

// ---------------------------------------------------------------- results

namespace {
void writeLine(Writer& w,const DialogueLine& l){
    w.beginObject();
    w.key("text").string(l.text);
    w.key("emotion").string(emotionToken(l.emotion));
    w.key("intent").string(intentToken(l.intent));
    w.key("commands").beginArray();
    for(const auto& c:l.commands){w.beginObject();w.key("kind").string(c.kind);w.key("target").string(c.target);w.endObject();}
    w.endArray();
    w.key("language").string(languageTag(l.language));
    w.key("voice").string(l.voiceId);
    w.key("character").string(l.characterId);
    w.endObject();
}
std::string_view sourceToken(LineSource s){return s==LineSource::Model?"model":s==LineSource::Cache?"cache":"fallback";}
} // namespace

std::string encodeLine(const DialogueLine& l){Writer w;writeLine(w,l);return w.take();}

std::string encodeResult(const DialogueResult& r){
    Writer w;
    w.beginObject();
    w.key("ticket").number(static_cast<double>(r.ticket));
    w.key("status").string(r.status==ResultStatus::Cancelled?"cancelled":"line");
    w.key("source").string(sourceToken(r.source));
    w.key("fallbackReason").string(fallbackReasonName(r.fallbackReason));
    w.key("line");writeLine(w,r.line);
    w.key("diagnostic").string(r.diagnostic);
    w.key("promptTokens").number(r.promptTokens);
    w.key("outputTokens").number(r.outputTokens);
    w.key("latencyMs").number(static_cast<double>(r.latency.count())/1000.0);
    w.key("usedFactIds").strings(r.usedFactIds);
    w.endObject();
    return w.take();
}

std::string encodeStats(const ServiceStats& s){
    Writer w;
    w.beginObject();
    w.key("submitted").number(static_cast<double>(s.submitted));
    w.key("completedModel").number(static_cast<double>(s.completedModel));
    w.key("completedCache").number(static_cast<double>(s.completedCache));
    w.key("completedFallback").number(static_cast<double>(s.completedFallback));
    w.key("cancelled").number(static_cast<double>(s.cancelled));
    w.key("timeouts").number(static_cast<double>(s.timeouts));
    w.key("rejected").number(static_cast<double>(s.rejected));
    w.key("abandoned").number(static_cast<double>(s.abandoned));
    w.endObject();
    return w.take();
}

std::string encodePreparedPrompt(const PreparedPrompt& p){
    Writer w;
    w.beginObject();
    w.key("instructions").string(p.backend.instructions);
    w.key("prompt").string(p.backend.prompt);
    w.key("schema").raw(schemaJson(p.backend.schema));
    w.key("language").string(languageTag(p.backend.language));
    w.key("maxOutputTokens").number(p.backend.maxOutputTokens);
    w.key("estimatedPromptTokens").number(estimateTokens(p.backend.instructions)+estimateTokens(p.backend.prompt));
    w.key("usedFactIds").strings(p.grounding.usedFactIds);
    w.key("withheldKeywords").strings(p.grounding.withheldKeywords);
    w.key("cacheKey").string(hex64(p.cacheKey));
    w.endObject();
    return w.take();
}

std::string encodeValidation(const Validation& v){
    Writer w;
    w.beginObject();
    w.key("ok").boolean(v.ok);
    w.key("reason").string(fallbackReasonName(v.reason));
    w.key("diagnostic").string(v.diagnostic);
    if(v.ok){w.key("line");writeLine(w,v.line);}
    w.endObject();
    return w.take();
}

// ---------------------------------------------------------------- backend wire format

std::optional<BackendStatus> parseBackendStatus(std::string_view t){
    for(int i=0;i<=static_cast<int>(BackendStatus::Error);++i)
        if(backendStatusName(static_cast<BackendStatus>(i))==t) return static_cast<BackendStatus>(i);
    return std::nullopt;
}

std::string encodeBackendRequest(const BackendRequest& b){
    Writer w;
    w.beginObject();
    w.key("instructions").string(b.instructions);
    w.key("prompt").string(b.prompt);
    w.key("schema").raw(schemaJson(b.schema));
    w.key("language").string(languageTag(b.language));
    w.key("maxOutputTokens").number(b.maxOutputTokens);
    w.key("sampling");writeSampling(w,b.sampling);
    w.endObject();
    return w.take();
}

BackendResponse decodeBackendResponse(std::string_view text){
    auto root=io::parseDocument(text,"response");
    Reader r(root,"response");
    BackendResponse b;
    const std::string s=r.str("status");
    auto st=parseBackendStatus(s);
    if(!st) io::fail(r.pathOf("status"),"unknown backend status '"+s+"'");
    b.status=*st;
    b.json=r.str("json");
    b.promptTokens=r.u32("promptTokens",0);
    b.outputTokens=r.u32("outputTokens",0);
    b.diagnostic=r.str("diagnostic");
    r.finish();
    return b;
}

std::string encodeBackendResponse(const BackendResponse& b){
    Writer w;
    w.beginObject();
    w.key("status").string(backendStatusName(b.status));
    w.key("json").string(b.json);
    w.key("promptTokens").number(b.promptTokens);
    w.key("outputTokens").number(b.outputTokens);
    w.key("diagnostic").string(b.diagnostic);
    w.endObject();
    return w.take();
}

ServiceConfig decodeServiceConfig(std::string_view text){
    ServiceConfig c;
    if(text.find_first_not_of(" \t\r\n")==std::string_view::npos) return c;
    auto root=io::parseDocument(text,"config");
    Reader r(root,"config");
    c.queueCapacity=r.u32("queueCapacity",static_cast<std::uint32_t>(c.queueCapacity));
    c.cacheCapacity=r.u32("cacheCapacity",static_cast<std::uint32_t>(c.cacheCapacity));
    c.cancelGrace=std::chrono::milliseconds(r.u32("cancelGraceMs",static_cast<std::uint32_t>(c.cancelGrace.count())));
    if(const auto* g=r.get("guardrails")){
        Reader gr(*g,r.pathOf("guardrails"));
        if(gr.get("metaPhrases")) c.guardrails.metaPhrases=gr.strings("metaPhrases");
        auto extra=gr.strings("extraMetaPhrases");
        c.guardrails.metaPhrases.insert(c.guardrails.metaPhrases.end(),extra.begin(),extra.end());
        c.guardrails.minJapaneseScriptFraction=gr.number("minJapaneseScriptFraction",c.guardrails.minJapaneseScriptFraction);
        gr.finish();
    }
    r.finish();
    if(c.queueCapacity==0) io::fail("config.queueCapacity","must be at least 1");
    return c;
}

} // namespace npc::dialogue::codec
