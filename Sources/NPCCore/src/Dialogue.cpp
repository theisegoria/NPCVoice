// Dialogue vocabulary, grounding, prompt assembly, validation and fallback
// Portable C++; no Apple frameworks.
#include "Dialogue.hpp"
#include "DialogueJson.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <unordered_set>

namespace npc::dialogue {

namespace {
constexpr std::array<std::string_view,EmotionCount> EmotionTokens{
    "neutral","happy","sad","angry","fear","surprise","disgust","contempt","pain","exertion","concentration","fatigue"};
constexpr std::array<std::string_view,IntentCount> IntentTokens{
    "inform","warn","request","refuse","greet","farewell","deflect","plead","threaten"};

std::uint64_t fnv(std::uint64_t h,std::string_view s){
    for(unsigned char c:s){h^=c;h*=1099511628211ull;}
    h^=0xffu;h*=1099511628211ull;                       // field separator
    return h;
}
constexpr std::uint64_t FnvBasis=1469598103934665603ull;

std::string asciiLower(std::string_view s){
    std::string r(s);
    for(char& c:r) if(c>='A'&&c<='Z') c=static_cast<char>(c-'A'+'a');
    return r;
}
bool containsFolded(std::string_view haystackLower,std::string_view needle){
    if(needle.empty()) return false;
    return haystackLower.find(asciiLower(needle))!=std::string_view::npos;
}

// Decodes UTF-8; invalid bytes yield U+FFFD and advance one byte.
template<class F> void forEachCodePoint(std::string_view s,F&& f){
    std::size_t i=0;
    while(i<s.size()){
        const auto c=static_cast<unsigned char>(s[i]);
        std::uint32_t cp=0xFFFD;std::size_t n=1;
        if(c<0x80){cp=c;}
        else if((c>>5)==0x6&&i+1<s.size()){cp=((c&0x1Fu)<<6)|(static_cast<unsigned char>(s[i+1])&0x3Fu);n=2;}
        else if((c>>4)==0xE&&i+2<s.size()){cp=((c&0x0Fu)<<12)|((static_cast<unsigned char>(s[i+1])&0x3Fu)<<6)|(static_cast<unsigned char>(s[i+2])&0x3Fu);n=3;}
        else if((c>>3)==0x1E&&i+3<s.size()){cp=((c&0x07u)<<18)|((static_cast<unsigned char>(s[i+1])&0x3Fu)<<12)|((static_cast<unsigned char>(s[i+2])&0x3Fu)<<6)|(static_cast<unsigned char>(s[i+3])&0x3Fu);n=4;}
        f(cp,i,n);
        i+=n;
    }
}
bool isKana(std::uint32_t cp){return (cp>=0x3040&&cp<=0x30FF)||(cp>=0x31F0&&cp<=0x31FF)||(cp>=0xFF66&&cp<=0xFF9F);}
bool isKanji(std::uint32_t cp){return (cp>=0x4E00&&cp<=0x9FFF)||(cp>=0x3400&&cp<=0x4DBF);}
bool isCjkOrKana(std::uint32_t cp){return isKana(cp)||isKanji(cp)||(cp>=0xAC00&&cp<=0xD7AF);}
bool isLetter(std::uint32_t cp){return (cp>='A'&&cp<='Z')||(cp>='a'&&cp<='z')||(cp>=0xC0&&cp<=0x24F)||isCjkOrKana(cp);}
bool isTerminator(std::uint32_t cp){return cp=='.'||cp=='!'||cp=='?'||cp==0x3002||cp==0xFF01||cp==0xFF1F||cp==0x2026;}

std::uint32_t defaultMaxCodePoints(Language l){return l==Language::Japanese?90u:220u;}
std::uint32_t maxCodePointsFor(const CharacterProfile& c){return c.maxLineCodePoints?c.maxLineCodePoints:defaultMaxCodePoints(c.language);}

template<class E,std::size_t N> std::vector<E> allOr(const std::vector<E>& v){
    if(!v.empty()) return v;
    std::vector<E> r;for(std::size_t i=0;i<N;++i) r.push_back(static_cast<E>(i));
    return r;
}

std::string trimCopy(std::string_view s){
    auto b=s.find_first_not_of(" \t\r\n");
    if(b==std::string_view::npos) return {};
    auto e=s.find_last_not_of(" \t\r\n");
    return std::string(s.substr(b,e-b+1));
}
bool startsWith(std::string_view s,std::string_view p){return s.substr(0,p.size())==p;}
bool endsWith(std::string_view s,std::string_view p){return s.size()>=p.size()&&s.substr(s.size()-p.size())==p;}

// Collapses whitespace, removes *stage directions*, a leading "Name:" and
// wrapping quotes, so TTS receives only speakable text.
std::string cleanLine(std::string_view in,const CharacterProfile& who){
    std::string s;
    bool inStars=false;
    for(char c:in){
        if(c=='*'){inStars=!inStars;continue;}
        if(inStars) continue;
        if(c=='\n'||c=='\r'||c=='\t') c=' ';
        if(c==' '&&!s.empty()&&s.back()==' ') continue;
        s.push_back(c);
    }
    if(inStars) return {};                                  // unbalanced: unsafe to guess
    s=trimCopy(s);
    for(std::string_view prefix:{std::string_view(who.displayName),std::string_view(who.id)}){
        if(prefix.empty()) continue;
        for(std::string_view colon:{std::string_view(":"),std::string_view("：")}){
            std::string p=std::string(prefix)+std::string(colon);
            if(startsWith(s,p)) s=trimCopy(std::string_view(s).substr(p.size()));
        }
    }
    const std::array<std::pair<std::string_view,std::string_view>,4> quotes{{{"\"","\""},{"「","」"},{"『","』"},{"“","”"}}};
    for(auto [o,c]:quotes){
        if(s.size()>o.size()+c.size()&&startsWith(s,o)&&endsWith(s,c)){
            std::string inner=s.substr(o.size(),s.size()-o.size()-c.size());
            if(inner.find(o)==std::string::npos) s=trimCopy(inner);   // only a single wrapped quote
        }
    }
    return s;
}
} // namespace

// ---------------------------------------------------------------- vocabulary

std::string_view languageTag(Language l){return l==Language::Japanese?"ja":"en";}
std::optional<Language> parseLanguageTag(std::string_view t){
    if(t=="en"||startsWith(t,"en-")) return Language::English;
    if(t=="ja"||startsWith(t,"ja-")) return Language::Japanese;
    return std::nullopt;
}
std::string_view emotionToken(Emotion e){return EmotionTokens[static_cast<std::size_t>(e)];}
std::optional<Emotion> parseEmotionToken(std::string_view t){
    for(std::size_t i=0;i<EmotionCount;++i) if(EmotionTokens[i]==t) return static_cast<Emotion>(i);
    return std::nullopt;
}
std::string_view intentToken(Intent i){return IntentTokens[static_cast<std::size_t>(i)];}
std::optional<Intent> parseIntentToken(std::string_view t){
    for(std::size_t i=0;i<IntentCount;++i) if(IntentTokens[i]==t) return static_cast<Intent>(i);
    return std::nullopt;
}
std::string_view fallbackReasonName(FallbackReason r){
    switch(r){
    case FallbackReason::None:return "none";case FallbackReason::BackendUnavailable:return "backend_unavailable";
    case FallbackReason::UnsupportedLanguage:return "unsupported_language";case FallbackReason::Timeout:return "timeout";
    case FallbackReason::QueueFull:return "queue_full";case FallbackReason::InvalidRequest:return "invalid_request";
    case FallbackReason::SchemaInvalid:return "schema_invalid";case FallbackReason::GuardrailRejected:return "guardrail_rejected";
    case FallbackReason::Refusal:return "refusal";case FallbackReason::ModelGuardrail:return "model_guardrail";
    case FallbackReason::ContextExceeded:return "context_exceeded";case FallbackReason::RateLimited:return "rate_limited";
    case FallbackReason::BackendError:return "backend_error";}
    return "unknown";
}
std::string_view backendStatusName(BackendStatus s){
    switch(s){
    case BackendStatus::Ok:return "ok";case BackendStatus::Cancelled:return "cancelled";case BackendStatus::Unavailable:return "unavailable";
    case BackendStatus::Refusal:return "refusal";case BackendStatus::Guardrail:return "guardrail";case BackendStatus::ContextExceeded:return "context_exceeded";
    case BackendStatus::UnsupportedLanguage:return "unsupported_language";case BackendStatus::RateLimited:return "rate_limited";
    case BackendStatus::DecodingFailure:return "decoding_failure";case BackendStatus::Error:return "error";}
    return "unknown";
}
std::string_view availabilityName(Availability a){
    switch(a){
    case Availability::Available:return "available";case Availability::DeviceNotEligible:return "device_not_eligible";
    case Availability::NotEnabled:return "apple_intelligence_not_enabled";case Availability::ModelNotReady:return "model_not_ready";
    case Availability::Unsupported:return "unsupported";}
    return "unknown";
}

SpeechHandoff speechHandoff(const DialogueLine& l){
    return {l.text,std::string(languageTag(l.language)),l.voiceId,std::string(emotionToken(l.emotion)),l.characterId};
}

// ---------------------------------------------------------------- cancellation

struct CancellationToken::State {
    std::mutex mutex;
    std::atomic<bool> cancelled{false};
    std::vector<std::function<void()>> callbacks;
};
bool CancellationToken::cancelled() const{return state_&&state_->cancelled.load(std::memory_order_acquire);}
void CancellationToken::onCancel(std::function<void()> f) const{
    if(!state_||!f) return;
    {
        std::lock_guard lock(state_->mutex);
        if(!state_->cancelled.load(std::memory_order_acquire)){state_->callbacks.push_back(std::move(f));return;}
    }
    f();
}
CancellationSource::CancellationSource():state_(std::make_shared<CancellationToken::State>()){}
CancellationToken CancellationSource::token() const{CancellationToken t;t.state_=state_;return t;}
bool CancellationSource::cancelled() const{return state_->cancelled.load(std::memory_order_acquire);}
void CancellationSource::cancel(){
    std::vector<std::function<void()>> run;
    {
        std::lock_guard lock(state_->mutex);
        if(state_->cancelled.exchange(true,std::memory_order_acq_rel)) return;
        run.swap(state_->callbacks);
    }
    for(auto& f:run) f();
}

// ---------------------------------------------------------------- text metrics

std::size_t codePointCount(std::string_view s){
    std::size_t n=0;forEachCodePoint(s,[&](std::uint32_t,std::size_t,std::size_t){++n;});return n;
}
std::uint32_t estimateTokens(std::string_view s){
    std::size_t ascii=0,wide=0;
    forEachCodePoint(s,[&](std::uint32_t cp,std::size_t,std::size_t){if(cp<0x80) ++ascii;else ++wide;});
    return static_cast<std::uint32_t>((ascii+2)/3+wide);    // deliberately pessimistic
}

// ---------------------------------------------------------------- grounding

GroundedContext groundFacts(const DialogueRequest& r){
    GroundedContext g;
    const std::unordered_set<std::string> flags(r.context.progressFlags.begin(),r.context.progressFlags.end());
    const std::unordered_set<std::string> topics(r.context.topicTags.begin(),r.context.topicTags.end());
    struct Scored{const Fact* f;double score;};
    std::vector<Scored> admitted;
    for(const Fact& f:r.context.facts){
        const bool knows=f.knownBy.empty()||std::find(f.knownBy.begin(),f.knownBy.end(),r.character.id)!=f.knownBy.end();
        const bool unlocked=std::all_of(f.requiredFlags.begin(),f.requiredFlags.end(),[&](const std::string& fl){return flags.contains(fl);});
        if(!knows||!unlocked){
            g.withheldKeywords.insert(g.withheldKeywords.end(),f.leakKeywords.begin(),f.leakKeywords.end());
            continue;
        }
        double overlap=0;
        for(const auto& t:f.tags) if(topics.contains(t)) overlap+=1;
        const double score=std::clamp(static_cast<double>(f.salience),0.0,1.0)+(topics.empty()?0.0:overlap/static_cast<double>(topics.size()));
        admitted.push_back({&f,score});
    }
    std::stable_sort(admitted.begin(),admitted.end(),[](const Scored& a,const Scored& b){
        return a.score!=b.score?a.score>b.score:a.f->id<b.f->id;});
    if(admitted.size()>r.budget.maxFacts) admitted.resize(r.budget.maxFacts);
    for(const auto& s:admitted){g.facts.push_back(s.f);g.usedFactIds.push_back(s.f->id);}
    // A keyword of a withheld fact that is also part of an admitted fact's text is
    // legitimately sayable; drop it from the guard to avoid false rejections.
    std::erase_if(g.withheldKeywords,[&](const std::string& k){
        const std::string kl=asciiLower(k);
        return k.empty()||std::any_of(g.facts.begin(),g.facts.end(),[&](const Fact* f){return asciiLower(f->text).find(kl)!=std::string::npos;});});
    return g;
}

// ---------------------------------------------------------------- schema and prompt

std::string schemaJson(const OutputSchema& s){
    std::string o="{\"emotions\":[";
    for(std::size_t i=0;i<s.emotions.size();++i){if(i) o+=',';o+=json::quote(emotionToken(s.emotions[i]));}
    o+="],\"intents\":[";
    for(std::size_t i=0;i<s.intents.size();++i){if(i) o+=',';o+=json::quote(intentToken(s.intents[i]));}
    o+="],\"commands\":[";
    for(std::size_t i=0;i<s.commands.size();++i){
        if(i) o+=',';
        const auto& c=s.commands[i];
        o+="{\"kind\":"+json::quote(c.kind)+",\"description\":"+json::quote(c.description)+",\"targets\":[";
        for(std::size_t t=0;t<c.allowedTargets.size();++t){if(t) o+=',';o+=json::quote(c.allowedTargets[t]);}
        o+="]}";
    }
    o+="],\"maxCommands\":"+std::to_string(s.maxCommands)+",\"maxCharacters\":"+std::to_string(s.maxCodePoints)+"}";
    return o;
}

namespace {
std::string joined(const std::vector<std::string>& v,std::string_view sep){
    std::string o;
    for(const auto& x:v){if(x.empty()) continue;if(!o.empty()) o+=sep;o+=x;}
    return o;
}
std::string buildInstructions(const DialogueRequest& r,const std::vector<const Fact*>& facts,std::uint32_t maxCp){
    const auto& c=r.character;
    const auto& w=r.world;
    std::string s="You are "+c.displayName;
    if(!c.role.empty()) s+=", the "+c.role;
    s+=", a character in "+(w.name.empty()?std::string("the story"):w.name)+".";
    if(!c.persona.empty()) s+=" "+c.persona;
    s+="\n";
    if(!w.setting.empty()) s+="Setting: "+w.setting+"\n";
    if(!w.tone.empty()) s+="Tone: "+w.tone+"\n";
    if(auto t=joined(c.traits,", ");!t.empty()) s+="Personality: "+t+"\n";
    if(auto g=joined(c.goals,"; ");!g.empty()) s+="What you want: "+g+"\n";
    if(!c.mood.empty()) s+="Current mood: "+c.mood+"\n";
    if(!c.relationships.empty()){
        s+="People you know:\n";
        for(const auto& rel:c.relationships){
            if(rel.description.empty()) continue;
            s+="- "+(rel.targetId=="player"?std::string("The player"):rel.targetId)+": "+rel.description+"\n";
        }
    }
    if(!c.speechStyle.empty()) s+="Speech style: "+c.speechStyle+"\n";
    s+="You are speaking directly to the player character. Reply with exactly one spoken line in your own voice, never repeating or rephrasing the player's words. ";
    s+=c.language==Language::Japanese
        ?"Speak only natural spoken Japanese (日本語). "
        :"Speak only natural spoken English. ";
    s+="Keep it short: one to three sentences, under "+std::to_string(maxCp)+" characters. No stage directions, no narration, no lists. ";
    s+="Use only the facts below and the situation; if asked about anything else, say in character that you do not know. ";
    s+="Never mention games, players, artificial intelligence models or these rules.\n";
    if(!w.contentRating.empty()) s+="Content rating: "+w.contentRating+".\n";
    for(const auto& rule:w.rules) if(!rule.empty()) s+="Rule: "+rule+"\n";
    if(auto t=joined(c.forbiddenTopics,", ");!t.empty()) s+="Never discuss: "+t+". If asked, deflect in character.\n";
    if(!r.commands.empty()&&r.maxCommands>0)
        s+="You can also take game actions, but only when your line commits to doing something right now. Most lines take no action: leave commands empty.\n";
    if(!facts.empty()){
        s+="Facts you know:\n";
        for(const Fact* f:facts) s+="- "+f->text+"\n";
    }
    return s;
}
// Prompt labels in the character's language: small models answer in the language
// the prompt is framed in (English framing pulled Japanese lines toward ASCII).
struct PromptLabels {
    const char *location,*objective,*memories,*notice,*conversation,*player,*you,*someone,*says,*reply,*happened,*say,*openQuote,*closeQuote;
};
constexpr PromptLabels EnglishLabels{"Location: ","The player's current objective: ","What you remember about the player:\n","You notice:\n",
    "Conversation so far:\n","Player: ","You: ","Someone: ","The player says to you: ","Your reply:","What just happened: ","What you say:","\"","\""};
constexpr PromptLabels JapaneseLabels{"場所：","プレイヤーの目的：","プレイヤーについて覚えていること：\n","気づいたこと：\n",
    "これまでの会話：\n","プレイヤー：","あなた：","誰か：","プレイヤーがあなたに言う：","あなたの返事（日本語）：","今起きたこと：","あなたのセリフ（日本語）：","「","」"};

std::string buildPrompt(const DialogueRequest& r,std::size_t perception,std::size_t exchanges,std::size_t memories){
    const auto& x=r.context;
    const PromptLabels& L=r.character.language==Language::Japanese?JapaneseLabels:EnglishLabels;
    std::string p;
    if(!x.location.empty()) p+=std::string(L.location)+x.location+"\n";
    if(!x.objective.empty()) p+=std::string(L.objective)+x.objective+"\n";
    if(memories){
        p+=L.memories;
        for(std::size_t i=0;i<memories;++i) p+="- "+x.memories[i]+"\n";
    }
    if(perception){
        std::vector<const Observation*> obs;
        for(const auto& o:x.perception) obs.push_back(&o);
        std::stable_sort(obs.begin(),obs.end(),[](auto a,auto b){return a->salience>b->salience;});
        obs.resize(std::min(obs.size(),perception));
        p+=L.notice;
        for(auto o:obs) p+="- "+o->text+"\n";
    }
    if(exchanges){
        p+=L.conversation;
        const std::size_t first=x.recentExchanges.size()-std::min(x.recentExchanges.size(),exchanges);
        for(std::size_t i=first;i<x.recentExchanges.size();++i){
            const auto& e=x.recentExchanges[i];
            p+=std::string(e.speaker==Speaker::Player?L.player:e.speaker==Speaker::Character?L.you:L.someone)+e.text+"\n";
        }
    }
    if(!r.playerUtterance.empty()) p+=std::string(L.says)+L.openQuote+r.playerUtterance+L.closeQuote+"\n"+L.reply;
    else p+=std::string(L.happened)+r.trigger+"\n"+L.say;
    return p;
}
} // namespace

PreparedPrompt preparePrompt(const DialogueRequest& r){
    const auto& c=r.character;
    if(c.id.empty()) throw std::invalid_argument("dialogue: character id is empty");
    if(c.displayName.empty()) throw std::invalid_argument("dialogue: character display name is empty");
    if(c.voiceId.empty()) throw std::invalid_argument("dialogue: character voice id is empty");
    if(r.playerUtterance.empty()&&r.trigger.empty()) throw std::invalid_argument("dialogue: request has neither a player utterance nor a trigger");
    if(r.budget.maxOutputTokens==0||r.budget.maxOutputTokens>1024) throw std::invalid_argument("dialogue: maxOutputTokens outside [1,1024]");
    if(r.budget.deadline.count()<=0) throw std::invalid_argument("dialogue: deadline must be positive");
    if(r.maxCommands>8) throw std::invalid_argument("dialogue: maxCommands above 8");
    if(!r.sampling.greedy&&!(std::isfinite(r.sampling.temperature)&&r.sampling.temperature>=0&&r.sampling.temperature<=2))
        throw std::invalid_argument("dialogue: temperature outside [0,2]");
    for(const auto& cmd:r.commands) if(cmd.kind.empty()) throw std::invalid_argument("dialogue: command kind is empty");

    PreparedPrompt out;
    out.grounding=groundFacts(r);
    const std::uint32_t maxCp=maxCodePointsFor(c);
    std::size_t perception=std::min<std::size_t>(r.context.perception.size(),r.budget.maxPerception);
    std::size_t exchanges=std::min<std::size_t>(r.context.recentExchanges.size(),r.budget.maxExchanges);
    std::size_t memories=std::min<std::size_t>(r.context.memories.size(),r.budget.maxMemories);
    auto facts=out.grounding.facts;
    std::string instr,prompt;
    const std::string schemaText=schemaJson({allOr<Emotion,EmotionCount>(c.allowedEmotions),allOr<Intent,IntentCount>(c.allowedIntents),r.commands,r.maxCommands,maxCp});
    const std::uint32_t schemaTokens=estimateTokens(schemaText);
    for(;;){
        instr=buildInstructions(r,facts,maxCp);
        prompt=buildPrompt(r,perception,exchanges,memories);
        if(estimateTokens(instr)+estimateTokens(prompt)+schemaTokens<=r.budget.maxPromptTokens) break;
        if(!facts.empty()){facts.pop_back();continue;}          // lowest-ranked first
        if(exchanges){--exchanges;continue;}                    // oldest first
        if(memories){--memories;continue;}                      // least important first
        if(perception){--perception;continue;}
        throw std::invalid_argument("dialogue: prompt exceeds maxPromptTokens with no context left to drop");
    }
    out.grounding.usedFactIds.resize(facts.size());
    out.grounding.facts=facts;

    auto& b=out.backend;
    b.instructions=std::move(instr);
    b.prompt=std::move(prompt);
    b.schema={allOr<Emotion,EmotionCount>(c.allowedEmotions),allOr<Intent,IntentCount>(c.allowedIntents),r.commands,r.commands.empty()?0u:r.maxCommands,maxCp};
    b.language=c.language;
    b.maxOutputTokens=r.budget.maxOutputTokens;
    b.sampling=r.sampling;

    std::uint64_t h=FnvBasis;
    h=fnv(h,c.id);h=fnv(h,c.voiceId);h=fnv(h,languageTag(c.language));
    h=fnv(h,b.instructions);h=fnv(h,b.prompt);h=fnv(h,schemaText);
    h=fnv(h,r.sampling.greedy?"g":"s");
    if(!r.sampling.greedy){h=fnv(h,std::to_string(r.sampling.seed));h=fnv(h,std::to_string(r.sampling.temperature));}
    h=fnv(h,std::to_string(b.maxOutputTokens));
    out.cacheKey=h;
    return out;
}

// ---------------------------------------------------------------- validation

Validation validateResponse(std::string_view text,const DialogueRequest& r,const GroundedContext& g,const GuardrailPolicy& policy){
    Validation v;
    auto fail=[&](FallbackReason reason,std::string d){v.ok=false;v.reason=reason;v.diagnostic=std::move(d);return v;};
    auto parsed=json::parse(text);
    if(!parsed) return fail(FallbackReason::SchemaInvalid,"response is not valid JSON");
    const json::Value& root=*parsed;
    if(root.kind!=json::Kind::Object) return fail(FallbackReason::SchemaInvalid,"response root is not an object");
    const auto* lineText=root.find("text");
    const auto* emotion=root.find("emotion");
    const auto* intent=root.find("intent");
    if(!lineText||lineText->kind!=json::Kind::String) return fail(FallbackReason::SchemaInvalid,"missing string field 'text'");
    if(!emotion||emotion->kind!=json::Kind::String) return fail(FallbackReason::SchemaInvalid,"missing string field 'emotion'");
    if(!intent||intent->kind!=json::Kind::String) return fail(FallbackReason::SchemaInvalid,"missing string field 'intent'");

    const auto& c=r.character;
    auto e=parseEmotionToken(emotion->string);
    if(!e) return fail(FallbackReason::SchemaInvalid,"unknown emotion '"+emotion->string+"'");
    if(!c.allowedEmotions.empty()&&std::find(c.allowedEmotions.begin(),c.allowedEmotions.end(),*e)==c.allowedEmotions.end())
        return fail(FallbackReason::SchemaInvalid,"emotion '"+emotion->string+"' not allowed for this character");
    auto in=parseIntentToken(intent->string);
    if(!in) return fail(FallbackReason::SchemaInvalid,"unknown intent '"+intent->string+"'");
    if(!c.allowedIntents.empty()&&std::find(c.allowedIntents.begin(),c.allowedIntents.end(),*in)==c.allowedIntents.end())
        return fail(FallbackReason::SchemaInvalid,"intent '"+intent->string+"' not allowed for this character");

    std::string line=cleanLine(lineText->string,c);
    if(line.empty()) return fail(FallbackReason::GuardrailRejected,"line is empty after cleanup");
    for(char ch:line) if(ch=='<'||ch=='>'||ch=='{'||ch=='}'||ch=='['||ch==']'||ch=='#'||ch=='`'||ch=='|')
        return fail(FallbackReason::GuardrailRejected,"line contains markup characters");
    bool badCode=false;
    forEachCodePoint(line,[&](std::uint32_t cp,std::size_t,std::size_t){if(cp==0xFFFD||cp<0x20) badCode=true;});
    if(badCode) return fail(FallbackReason::GuardrailRejected,"line contains invalid UTF-8 or control characters");

    // Length: trim at the last sentence end within the limit when that keeps at
    // least half of the allowance; otherwise reject.
    const std::uint32_t maxCp=maxCodePointsFor(c);
    if(codePointCount(line)>maxCp){
        std::size_t idx=0,cutByte=std::string::npos;
        forEachCodePoint(line,[&](std::uint32_t cp,std::size_t at,std::size_t n){
            ++idx;
            if(idx<=maxCp&&isTerminator(cp)&&idx>=maxCp/2) cutByte=at+n;});
        if(cutByte==std::string::npos) return fail(FallbackReason::GuardrailRejected,"line exceeds "+std::to_string(maxCp)+" code points");
        line=trimCopy(std::string_view(line).substr(0,cutByte));
        v.diagnostic="trimmed to the last sentence within the length limit";
    }

    // Script: Japanese lines need kana/kanji (and kana when longer than a few
    // characters, to reject Chinese); English lines must not contain CJK.
    std::size_t letters=0,jp=0,kana=0,cjk=0;
    forEachCodePoint(line,[&](std::uint32_t cp,std::size_t,std::size_t){
        if(isLetter(cp)) ++letters;
        if(isKana(cp)||isKanji(cp)) ++jp;
        if(isKana(cp)) ++kana;
        if(isCjkOrKana(cp)) ++cjk;});
    if(c.language==Language::Japanese){
        if(letters==0||static_cast<double>(jp)/static_cast<double>(letters)<policy.minJapaneseScriptFraction)
            return fail(FallbackReason::GuardrailRejected,"Japanese line is not in Japanese script");
        if(kana==0&&codePointCount(line)>8) return fail(FallbackReason::GuardrailRejected,"Japanese line has no kana");
    }else if(cjk>0) return fail(FallbackReason::GuardrailRejected,"English line contains CJK characters");

    const std::string folded=asciiLower(line);
    for(const auto& p:policy.metaPhrases) if(containsFolded(folded,p)) return fail(FallbackReason::GuardrailRejected,"fourth-wall phrase '"+p+"'");
    for(const auto& t:c.forbiddenTerms) if(containsFolded(folded,t)) return fail(FallbackReason::GuardrailRejected,"forbidden term '"+t+"'");
    for(const auto& k:g.withheldKeywords) if(containsFolded(folded,k)) return fail(FallbackReason::GuardrailRejected,"reveals withheld fact keyword '"+k+"'");

    // Commands: invalid ones are dropped (the line itself is still good).
    std::vector<Command> commands;
    if(const auto* cmds=root.find("commands")){
        if(cmds->kind==json::Kind::Array){
            for(const auto& item:cmds->array){
                if(item.kind!=json::Kind::Object) continue;
                const auto* kind=item.find("kind");
                const auto* target=item.find("target");
                if(!kind||kind->kind!=json::Kind::String) continue;
                if(kind->string=="none") continue;                // backends' explicit "no action"
                auto spec=std::find_if(r.commands.begin(),r.commands.end(),[&](const CommandSpec& s){return s.kind==kind->string;});
                if(spec==r.commands.end()){v.diagnostic+=(v.diagnostic.empty()?"":"; ")+std::string("dropped unknown command '")+kind->string+"'";continue;}
                std::string t=(target&&target->kind==json::Kind::String)?target->string:std::string();
                if(t=="none") t.clear();
                if(spec->allowedTargets.empty()) t.clear();
                else if(std::find(spec->allowedTargets.begin(),spec->allowedTargets.end(),t)==spec->allowedTargets.end()){
                    v.diagnostic+=(v.diagnostic.empty()?"":"; ")+std::string("dropped command '")+spec->kind+"' with disallowed target '"+t+"'";continue;}
                Command cmd{spec->kind,t};
                if(std::any_of(commands.begin(),commands.end(),[&](const Command& x){return x.kind==cmd.kind&&x.target==cmd.target;})) continue;
                if(commands.size()>=r.maxCommands){v.diagnostic+=(v.diagnostic.empty()?"":"; ")+std::string("dropped commands beyond maxCommands");break;}
                commands.push_back(std::move(cmd));
            }
        }else if(cmds->kind!=json::Kind::Null) return fail(FallbackReason::SchemaInvalid,"'commands' is not an array");
    }

    v.ok=true;
    v.line={std::move(line),*e,*in,std::move(commands),c.language,c.voiceId,c.id};
    return v;
}

// ---------------------------------------------------------------- fallback

DialogueLine fallbackLine(const DialogueRequest& r,Intent preferred){
    const auto& c=r.character;
    std::vector<const FallbackLine*> pool;
    for(const auto& f:r.fallbacks) if(f.intent==preferred&&!f.text.empty()) pool.push_back(&f);
    if(pool.empty()) for(const auto& f:r.fallbacks) if(!f.text.empty()) pool.push_back(&f);
    if(!pool.empty()){
        std::uint64_t h=FnvBasis;
        h=fnv(h,c.id);h=fnv(h,r.playerUtterance);h=fnv(h,r.trigger);h=fnv(h,std::to_string(r.sampling.seed));
        const FallbackLine& f=*pool[h%pool.size()];
        return {f.text,f.emotion,f.intent,{},c.language,c.voiceId,c.id};
    }
    std::string text=c.language==Language::Japanese?"……今は、話せない。":"Not now. I can't talk about that.";
    return {std::move(text),Emotion::Neutral,Intent::Deflect,{},c.language,c.voiceId,c.id};
}

} // namespace npc::dialogue
