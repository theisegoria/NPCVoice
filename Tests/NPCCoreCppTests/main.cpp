// NPCCore dialogue tests with the
// deterministic stub backend:
// schema validation, grounding/spoiler filter, guardrails, fallback, cache,
// budgets (deadline, queue, prompt) and cancellation.
#include "Codec.hpp"
#include "Dialogue.hpp"
#include "Project.hpp"
#include "npc_core.h"
#include <algorithm>
#include <cstring>
#include <mutex>
#include <vector>
#include <cstdlib>
#include <filesystem>
#include <unistd.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
using namespace npc::dialogue;
using namespace std::chrono_literals;
namespace {
void check(bool v,const std::string& message){if(!v) throw std::runtime_error(message);}
template<class F> void rejects(F f,const char* message){bool failed=false;try{f();}catch(const std::invalid_argument&){failed=true;}check(failed,message);}

DialogueRequest baseRequest(Language lang=Language::English){
    DialogueRequest r;
    r.character.id="okafor";
    r.character.displayName="Chief Engineer Okafor";
    r.character.persona="A tired, protective engineer who stayed behind to keep the reactor alive.";
    r.character.speechStyle="Short, clipped sentences.";
    r.character.voiceId=lang==Language::Japanese?"ja_male_02":"en_male_03";
    r.character.language=lang;
    r.playerUtterance=lang==Language::Japanese?"エンジニアリングへはどう行けばいい？":"How do I reach Engineering?";
    const bool ja=lang==Language::Japanese;
    r.context.facts={
        {"lift_dead",ja?"リフトは停電している。":"The lift to Engineering has no power.",{},{},{"route","engineering"},{},0.6f},
        {"vent_route",ja?"第三デッキの換気ダクトが機関部へ通じている。":"The deck three vent shaft leads to Engineering.",{"okafor"},{},{"route"},{},0.5f},
        {"captain_dead",ja?"船長はすでに死んでいる。":"The captain is already dead.",{"okafor"},{"found_bridge_log"},{"captain"},{"captain is dead","dead captain","船長は死"},0.9f},
        {"mara_secret",ja?"マーラは感染している。":"Mara is infected.",{"mara"},{},{"crew"},{"infected","感染"},0.9f},
    };
    r.context.progressFlags={"woke_up"};
    r.context.topicTags={"route"};
    r.context.location="Reactor control, deck 2";
    r.context.objective="Reach Engineering on deck 3";
    r.fallbacks={{ja?"今は無理だ。":"Not now.",Intent::Deflect,Emotion::Fatigue},{ja?"やめろ。":"Don't.",Intent::Refuse,Emotion::Angry}};
    return r;
}
std::string line(std::string_view text,std::string_view emotion="neutral",std::string_view intent="inform",std::string_view commands="[]"){
    return std::string("{\"text\":\"")+std::string(text)+"\",\"emotion\":\""+std::string(emotion)+"\",\"intent\":\""+std::string(intent)+"\",\"commands\":"+std::string(commands)+"}";
}

void vocabulary(){
    for(std::size_t i=0;i<EmotionCount;++i) check(parseEmotionToken(emotionToken(Emotion(i)))==Emotion(i),"emotion token round trip");
    for(std::size_t i=0;i<IntentCount;++i) check(parseIntentToken(intentToken(Intent(i)))==Intent(i),"intent token round trip");
    check(parseLanguageTag("ja-JP")==Language::Japanese&&parseLanguageTag("en")==Language::English&&!parseLanguageTag("fr"),"language tags");
    check(codePointCount("日本語abc")==6,"code points");
    check(estimateTokens("日本語")==3,"CJK token estimate");
}

void grounding(){
    auto r=baseRequest();
    auto g=groundFacts(r);
    check(g.facts.size()==2,"only known and unlocked facts are admitted");
    check(g.facts[0]->id=="lift_dead"&&g.facts[1]->id=="vent_route","ranked by salience plus topic overlap, ties by id");
    // captain_dead gated by a flag, mara_secret not known by okafor: both withheld, keywords guarded.
    check(g.withheldKeywords.size()==5,"withheld keywords collected");
    r.context.progressFlags.push_back("found_bridge_log");
    g=groundFacts(r);
    check(g.facts.size()==3&&g.facts[2]->id=="captain_dead","flag unlocks the spoiler fact (ranked below topic matches)");
    check(g.withheldKeywords.size()==2,"unlocked fact no longer guarded");
    r.budget.maxFacts=1;
    check(groundFacts(r).facts.size()==1,"fact cap");
}

void prompts(){
    auto r=baseRequest();
    auto p=preparePrompt(r);
    check(p.backend.instructions.find("The deck three vent shaft")!=std::string::npos,"known fact in instructions");
    check(p.backend.instructions.find("captain")==std::string::npos,"gated fact absent from the prompt");
    check(p.backend.instructions.find("Mara")==std::string::npos,"unknown fact absent from the prompt");
    check(p.backend.prompt.find("How do I reach Engineering?")!=std::string::npos,"utterance in prompt");
    check(p.backend.schema.emotions.size()==EmotionCount&&p.backend.schema.maxCommands==0,"default schema");
    check(preparePrompt(r).cacheKey==p.cacheKey,"cache key is deterministic");
    auto r2=r;r2.playerUtterance="Where is the captain?";
    check(preparePrompt(r2).cacheKey!=p.cacheKey,"cache key covers the utterance");
    auto s=schemaJson(p.backend.schema);
    check(s.find("\"emotions\":[\"neutral\"")==0+1&&s.find("\"maxCharacters\":220")!=std::string::npos,"schema json");
    // Budget: a tight prompt budget drops facts before failing.
    auto tight=r;tight.budget.maxPromptTokens=estimateTokens(p.backend.instructions)+estimateTokens(p.backend.prompt)+estimateTokens(s)-5;
    auto pt=preparePrompt(tight);
    check(pt.grounding.facts.size()==1&&pt.grounding.usedFactIds.size()==1,"prompt budget drops the lowest-ranked fact");
    auto none=r;none.budget.maxPromptTokens=10;
    rejects([&]{preparePrompt(none);},"impossible prompt budget rejected");
    auto bad=r;bad.character.voiceId.clear();
    rejects([&]{preparePrompt(bad);},"missing voice rejected");
    bad=r;bad.playerUtterance.clear();
    rejects([&]{preparePrompt(bad);},"no utterance and no trigger rejected");
}

void validation(){
    auto r=baseRequest();
    auto g=groundFacts(r);
    auto ok=validateResponse(line("Use the vent shaft on deck three.","fatigue","inform"),r,g);
    check(ok.ok&&ok.line.emotion==Emotion::Fatigue&&ok.line.voiceId=="en_male_03","valid line");
    check(!validateResponse("not json",r,g).ok,"malformed JSON");
    check(validateResponse("{\"text\":\"Hi\"}",r,g).reason==FallbackReason::SchemaInvalid,"missing fields");
    check(!validateResponse(line("Hi.","smug"),r,g).ok,"unknown emotion");
    check(!validateResponse(line("Hi.","neutral","sing"),r,g).ok,"unknown intent");
    check(!validateResponse("{\"text\":\"Hi\",\"emotion\":\"neutral\",\"intent\":\"inform\"} x",r,g).ok,"trailing garbage");
    auto rs=r;rs.character.allowedEmotions={Emotion::Neutral};
    check(!validateResponse(line("Hi.","angry"),rs,groundFacts(rs)).ok,"emotion outside the character's set");
    // Cleanup: stage directions, speaker prefix and quotes removed.
    auto c=validateResponse(line("Chief Engineer Okafor: *sighs* \\\"Take the vent.\\\""),r,g);
    check(c.ok&&c.line.text=="Take the vent.","cleanup: "+c.line.text);
    check(!validateResponse(line("<b>Go</b>"),r,g).ok,"markup rejected");
    // Spoilers and fourth wall.
    auto leak=validateResponse(line("The captain is dead, you know."),r,g);
    check(!leak.ok&&leak.reason==FallbackReason::GuardrailRejected,"gated fact keyword rejected");
    check(!validateResponse(line("Mara looks infected."),r,g).ok,"unknown fact keyword rejected");
    check(!validateResponse(line("As an AI language model, I cannot."),r,g).ok,"fourth-wall break rejected");
    check(validateResponse(line("The ship AI is lying to us."),r,g).ok,"in-world AI is legal");
    auto rf=r;rf.character.forbiddenTerms={"Durandal"};
    check(!validateResponse(line("durandal knows."),rf,groundFacts(rf)).ok,"forbidden term (case-insensitive)");
    // Length: trim at a sentence end when possible, else reject.
    auto rl=r;rl.character.maxLineCodePoints=40;
    auto t=validateResponse(line("Take the vent on deck three. Then follow the pipes down to the reactor."),rl,g);
    check(t.ok&&t.line.text=="Take the vent on deck three.","length trim");
    check(!validateResponse(line("Takeventdeckthreethenfollowthepipesdowntothereactorquickly"),rl,g).ok,"overlong without sentence end");
    // Script checks.
    check(!validateResponse(line("リフトは死んでいる。"),r,g).ok,"Japanese text in an English line");
    auto j=baseRequest(Language::Japanese);auto gj=groundFacts(j);
    check(validateResponse(line("第三デッキのダクトを使え。"),j,gj).ok,"Japanese line");
    check(!validateResponse(line("Use the vent."),j,gj).ok,"English text in a Japanese line");
    check(!validateResponse(line("船長は死んだ。"),j,gj).ok,"Japanese spoiler keyword");
    check(validateResponse(line("「ダクトを使え。」"),j,gj).line.text=="ダクトを使え。","Japanese quotes stripped");
    // Commands: validated against the game's specs; invalid ones dropped.
    auto rc=r;rc.commands={{"unlock_door","Unlock a door you control",{"door_reactor"}},{"follow_player","Follow the player",{}}};rc.maxCommands=2;
    auto gc=groundFacts(rc);
    auto cm=validateResponse(line("Follow me.","neutral","request",
        "[{\"kind\":\"unlock_door\",\"target\":\"door_reactor\"},{\"kind\":\"unlock_door\",\"target\":\"door_armory\"},{\"kind\":\"self_destruct\",\"target\":\"\"},{\"kind\":\"follow_player\",\"target\":\"none\"},{\"kind\":\"unlock_door\",\"target\":\"door_reactor\"}]"),rc,gc);
    check(cm.ok&&cm.line.commands.size()==2,"commands filtered: "+std::to_string(cm.line.commands.size()));
    check(cm.line.commands[0].target=="door_reactor"&&cm.line.commands[1].kind=="follow_player"&&cm.line.commands[1].target.empty(),"command contents");
    check(cm.diagnostic.find("door_armory")!=std::string::npos&&cm.diagnostic.find("self_destruct")!=std::string::npos,"dropped commands reported");
    check(validateResponse(line("Go.","neutral","inform","[{\"kind\":\"unlock_door\",\"target\":\"door_reactor\"}]"),r,g).line.commands.empty(),"no commands without specs");
    auto none=validateResponse(line("Go.","neutral","inform","[{\"kind\":\"none\",\"target\":\"none\"}]"),rc,gc);
    check(none.ok&&none.line.commands.empty()&&none.diagnostic.empty(),"explicit none action dropped silently");
}

void fallbacks(){
    auto r=baseRequest();
    auto a=fallbackLine(r,Intent::Refuse);
    check(a.text=="Don't."&&a.emotion==Emotion::Angry,"intent-matched fallback");
    check(fallbackLine(r).text==fallbackLine(r).text,"fallback deterministic");
    r.fallbacks.clear();
    check(fallbackLine(r).text=="Not now. I can't talk about that.","engine default EN");
    auto j=baseRequest(Language::Japanese);j.fallbacks.clear();
    check(fallbackLine(j).text=="……今は、話せない。"&&fallbackLine(j).language==Language::Japanese,"engine default JA");
    auto h=speechHandoff(fallbackLine(j));
    check(h.languageTag=="ja"&&h.voiceId=="ja_male_02"&&h.emotionToken=="neutral","speech handoff");
}

void serviceModelAndCache(){
    auto stub=std::make_shared<StubBackend>();
    DialogueService s(stub);
    auto t=s.submit(baseRequest());
    auto r=s.waitFor(t,2s);
    check(r&&r->source==LineSource::Model&&r->line.text=="The lift to Engineering has no power.","stub model line: "+(r?r->line.text+" "+r->diagnostic:"none"));
    check(r->usedFactIds.size()==2,"used fact ids reported");
    auto t2=s.submit(baseRequest());
    auto r2=s.waitFor(t2,2s);
    check(r2&&r2->source==LineSource::Cache&&r2->line.text==r->line.text,"second identical request served from cache");
    check(stub->calls()==1,"cache avoided a backend call");
    auto nc=baseRequest();nc.allowCache=false;
    check(s.waitFor(s.submit(nc),2s)->source==LineSource::Model&&stub->calls()==2,"allowCache=false bypasses the cache");
    auto j=s.waitFor(s.submit(baseRequest(Language::Japanese)),2s);
    check(j&&j->source==LineSource::Model&&j->line.text=="リフトは停電している。"&&j->line.language==Language::Japanese,"Japanese stub line");
    auto st=s.stats();
    check(st.submitted==4&&st.completedModel==3&&st.completedCache==1,"stats");
}

void serviceFallbacks(){
    {
        StubBackend::Config cfg;cfg.responder=[](const BackendRequest&){return BackendResponse{BackendStatus::Ok,line("As an AI, I can't help."),10,5,{}};};
        DialogueService s(std::make_shared<StubBackend>(cfg));
        auto r=s.waitFor(s.submit(baseRequest()),2s);
        check(r&&r->source==LineSource::Fallback&&r->fallbackReason==FallbackReason::GuardrailRejected&&r->line.text=="Not now.","guardrail -> deterministic fallback");
        check(r->outputTokens==5,"tokens reported on fallback");
        auto r2=s.waitFor(s.submit(baseRequest()),2s);
        check(r2->source==LineSource::Fallback,"rejected lines are never cached");
    }
    {
        StubBackend::Config cfg;cfg.responder=[](const BackendRequest&){return BackendResponse{BackendStatus::Refusal,{},0,0,"refused"};};
        DialogueService s(std::make_shared<StubBackend>(cfg));
        auto r=s.waitFor(s.submit(baseRequest()),2s);
        check(r&&r->fallbackReason==FallbackReason::Refusal&&r->line.intent==Intent::Refuse,"model refusal -> refuse fallback");
    }
    {
        StubBackend::Config cfg;cfg.availability=Availability::NotEnabled;
        DialogueService s(std::make_shared<StubBackend>(cfg));
        auto r=s.waitFor(s.submit(baseRequest()),2s);
        check(r&&r->fallbackReason==FallbackReason::BackendUnavailable,"unavailable backend");
    }
    {
        StubBackend::Config cfg;cfg.languages={Language::English};
        DialogueService s(std::make_shared<StubBackend>(cfg));
        auto r=s.waitFor(s.submit(baseRequest(Language::Japanese)),2s);
        check(r&&r->fallbackReason==FallbackReason::UnsupportedLanguage&&r->line.text=="今は無理だ。","unsupported language");
    }
    {
        DialogueService s(std::make_shared<StubBackend>());
        auto bad=baseRequest();bad.character.id.clear();
        auto r=s.waitFor(s.submit(bad),2s);
        check(r&&r->fallbackReason==FallbackReason::InvalidRequest,"invalid request completes with a fallback");
    }
}

void serviceBudgetsAndCancellation(){
    {   // Deadline: a slow backend times out and is cancelled.
        StubBackend::Config cfg;cfg.delay=2000ms;
        auto stub=std::make_shared<StubBackend>(cfg);
        DialogueService s(stub);
        auto req=baseRequest();req.budget.deadline=60ms;
        const auto t0=std::chrono::steady_clock::now();
        auto r=s.waitFor(s.submit(req),3s);
        const auto took=std::chrono::steady_clock::now()-t0;
        check(r&&r->fallbackReason==FallbackReason::Timeout&&r->line.text=="Not now.","deadline -> timeout fallback");
        check(took<1500ms,"timeout does not wait for the backend");
        check(s.stats().timeouts==1&&s.stats().abandoned==0,"backend honoured cancellation within the grace period");
    }
    {   // Cancel a running request.
        StubBackend::Config cfg;cfg.delay=2000ms;
        DialogueService s(std::make_shared<StubBackend>(cfg));
        auto t=s.submit(baseRequest());
        std::this_thread::sleep_for(30ms);
        check(s.cancel(t),"cancel running");
        auto r=s.waitFor(t,2s);
        check(r&&r->status==ResultStatus::Cancelled,"running request cancelled");
        check(!s.cancel(t),"cancel after completion is false");
    }
    {   // Cancel a queued request; queue capacity; priority order.
        StubBackend::Config cfg;cfg.delay=150ms;
        DialogueService s(std::make_shared<StubBackend>(cfg),ServiceConfig{2,16});
        auto busy=s.submit(baseRequest());
        std::this_thread::sleep_for(30ms);                 // worker is now inside `busy`
        auto low=baseRequest();low.allowCache=false;low.playerUtterance="low";
        auto high=baseRequest();high.allowCache=false;high.playerUtterance="high";high.priority=5;
        auto tLow=s.submit(low);
        auto tHigh=s.submit(high);
        auto tFull=s.submit(baseRequest());
        auto full=s.waitFor(tFull,1s);
        check(full&&full->fallbackReason==FallbackReason::QueueFull,"queue capacity");
        auto queued=baseRequest();
        check(s.cancel(tLow),"cancel queued");
        auto rl=s.waitFor(tLow,1s);
        check(rl&&rl->status==ResultStatus::Cancelled,"queued request cancelled");
        check(s.waitFor(busy,2s)&&s.waitFor(tHigh,2s)->source==LineSource::Model,"remaining requests complete");
        (void)queued;
    }
    {   // drainCompleted publishes in ticket order on the caller's thread.
        DialogueService s(std::make_shared<StubBackend>());
        auto a=s.submit(baseRequest());
        auto b=s.submit(baseRequest(Language::Japanese));
        std::vector<DialogueResult> got;
        for(int i=0;i<200&&got.size()<2;++i){auto d=s.drainCompleted();got.insert(got.end(),d.begin(),d.end());std::this_thread::sleep_for(5ms);}
        check(got.size()==2&&got[0].ticket==a&&got[1].ticket==b,"drain order");
    }
    {   // Destruction with a request in flight is clean.
        StubBackend::Config cfg;cfg.delay=5000ms;
        auto s=std::make_unique<DialogueService>(std::make_shared<StubBackend>(cfg));
        s->submit(baseRequest());
        std::this_thread::sleep_for(20ms);
        const auto t0=std::chrono::steady_clock::now();
        s.reset();
        check(std::chrono::steady_clock::now()-t0<1s,"destructor cancels the in-flight request");
    }
    {   // Cancellation tokens.
        CancellationSource src;int calls=0;
        src.token().onCancel([&]{++calls;});
        src.cancel();src.cancel();
        src.token().onCancel([&]{++calls;});
        check(calls==2&&src.token().cancelled(),"cancellation callbacks run once each");
    }
}

void personaPrompt(){
    auto r=baseRequest();
    r.world={"Harbor Town","A rainy port.","Wry low fantasy","Teen: no profanity",{"Coin is silver marks."}};
    r.character.role="chief engineer";
    r.character.traits={"tired","protective"};
    r.character.goals={"keep the reactor alive"};
    r.character.mood="irritable";
    r.character.relationships={{"player","a stranger"},{"mara","a friend"}};
    r.character.forbiddenTopics={"her past"};
    r.context.memories={"The player lied about the cargo.","The player paid on time."};
    auto p=preparePrompt(r);
    const auto& in=p.backend.instructions;
    check(in.find("Chief Engineer Okafor, the chief engineer, a character in Harbor Town.")==std::string::npos?
          in.find("a character in Harbor Town.")!=std::string::npos:true,"world name in instructions");
    check(in.find("science-fiction")==std::string::npos,"no hard-coded genre");
    check(in.find("Personality: tired, protective")!=std::string::npos,"traits");
    check(in.find("What you want: keep the reactor alive")!=std::string::npos,"goals");
    check(in.find("Current mood: irritable")!=std::string::npos,"mood");
    check(in.find("- The player: a stranger")!=std::string::npos&&in.find("- mara: a friend")!=std::string::npos,"relationships");
    check(in.find("Never discuss: her past.")!=std::string::npos,"forbidden topics");
    check(in.find("Content rating: Teen: no profanity.")!=std::string::npos&&in.find("Rule: Coin is silver marks.")!=std::string::npos,"world rules");
    check(in.rfind("Facts you know:\n- ")!=std::string::npos,"facts block last (stub contract)");
    check(p.backend.prompt.find("- The player lied about the cargo.")!=std::string::npos,"memories in prompt");
    auto tight=r;tight.context.facts.clear();
    auto pt=preparePrompt(tight);
    tight.budget.maxPromptTokens=estimateTokens(pt.backend.instructions)+estimateTokens(pt.backend.prompt)+estimateTokens(schemaJson(pt.backend.schema))-3;
    check(preparePrompt(tight).backend.prompt.find("paid on time")==std::string::npos,"memories dropped under budget pressure");
}

void codecRoundTrip(){
    auto r=baseRequest(Language::Japanese);
    r.world.name="W";r.character.traits={"a"};r.commands={{"open","Open it",{"x"}}};r.budget.deadline=1234ms;
    r.context.recentExchanges={{Speaker::Character,"やあ"}};r.sampling={false,0.5,42};
    const auto once=npc::dialogue::codec::encodeRequest(r);
    const auto back=npc::dialogue::codec::decodeRequest(once);
    check(npc::dialogue::codec::encodeRequest(back)==once,"request round trip");
    check(back.budget.deadline==1234ms&&back.character.language==Language::Japanese&&back.sampling.seed==42,"round trip fields");
    bool threw=false;
    try{npc::dialogue::codec::decodeRequest(R"({"character":{"id":"a","traitz":[]}})");}
    catch(const npc::dialogue::codec::DecodeError& e){threw=std::string(e.what()).find("request.character.traitz: unknown key")==0;}
    check(threw,"unknown keys rejected with a path");
    threw=false;
    try{npc::dialogue::codec::decodeRequest(R"({"character":{"id":"a","allowedEmotions":["glee"]}})");}
    catch(const npc::dialogue::codec::DecodeError& e){threw=std::string(e.what()).find("allowedEmotions[0]")!=std::string::npos;}
    check(threw,"bad enum token rejected with index path");
}

void projects(){
    namespace fs=std::filesystem;
    char tmpl[]="/tmp/npccore-test-XXXXXX";
    const fs::path root=mkdtemp(tmpl);
    const auto dir=root/"Harbor.npcproj";
    writeSampleProject(dir);
    auto p=loadProject(dir);
    check(p.name=="Harbor Town"&&p.characters.size()==4&&p.facts.size()==7&&p.commands.size()==4,"sample project loads");
    check(p.pronunciations.size()==2&&p.pronunciations[0].word=="Saltwren","sample pronunciations load");
    {
        const auto once=encodeProject(p);
        check(encodeProject(decodeProject(once))==once,"project JSON round trip");
    }
    auto diags=diagnose(p);
    for(const auto& d:diags) check(d.severity!=ProjectDiagnostic::Severity::Error,"sample has no errors: "+d.path+" "+d.message);
    auto q=buildRequest(p,R"({"character":"tamsin","playerUtterance":"Where is the cargo?","flags":["earned_tamsin_trust"],"topics":["cargo"]})");
    auto g=groundFacts(q);
    check(!g.facts.empty()&&g.facts[0]->id=="smuggler_cave","trust flag unlocks the secret");
    auto q2=buildRequest(p,R"({"character":"tamsin","playerUtterance":"Where is the cargo?"})");
    auto v=validateResponse(R"({"text":"Check the sea cave, sailor.","emotion":"happy","intent":"inform"})",q2,groundFacts(q2));
    check(!v.ok,"locked secret guarded in the project flow");
    check(q.commands.size()==1&&q.commands[0].kind=="follow_player","character commands resolved");
    check(preparePrompt(q).backend.instructions.find("- Captain Rhys Hallow: a useful fool")!=std::string::npos,"relationship ids resolved to names");
    // Diagnostics catch authoring errors.
    auto marta=std::find_if(p.characters.begin(),p.characters.end(),[](const ProjectCharacter& c){return c.profile.id=="marta";});
    marta->profile.voiceId="jf_alpha";
    marta->commandKinds.push_back("fly");
    auto bad=diagnose(p);
    check(std::count_if(bad.begin(),bad.end(),[](const ProjectDiagnostic& d){return d.severity==ProjectDiagnostic::Severity::Error;})==2,"voice/language and unknown command errors");
    // C ABI end to end on the sample.
    char* err=nullptr;
    npc_project* cp=npc_project_load(dir.c_str(),&err);
    check(cp&&!err,"C project load");
    char* req=npc_project_request(cp,R"({"character":"marta","playerUtterance":"A room, please."})",&err);
    check(req&&!err,"C project request");
    npc_backend* stub=npc_backend_create_stub(R"({"fixedResponse":"{\"text\":\"Three marks, love.\",\"emotion\":\"happy\",\"intent\":\"inform\",\"commands\":[{\"kind\":\"give_item\",\"target\":\"room_key\"}]}"})",&err);
    check(stub&&!err,"C stub backend");
    npc_service* svc=npc_service_create(stub,nullptr,&err);
    const uint64_t t=npc_service_submit(svc,req,&err);
    char* res=npc_service_wait(svc,t,2000);
    check(res&&std::string(res).find("\"source\":\"model\"")!=std::string::npos&&std::string(res).find("room_key")!=std::string::npos,std::string("C service result: ")+(res?res:"null"));
    check(npc_service_submit(svc,"{nope",&err)==0&&err,"C submit rejects bad JSON");
    npc_string_free(err);err=nullptr;
    char* prompt=npc_prepare_prompt(req,&err);
    check(prompt&&std::string(prompt).find("Marta Venn")!=std::string::npos,"C prompt inspection");
    npc_string_free(prompt);npc_string_free(res);npc_string_free(req);
    npc_service_destroy(svc);npc_backend_release(stub);npc_project_release(cp);
    fs::remove_all(root);
}
// Log sink: fallbacks reach the game's logger with their reason; levels filter; and a
// callbacks struct from an older caller (struct_size 0, no unload field) is accepted.
void loggingAndCallbacks(){
    struct Sink{std::mutex m;std::vector<std::pair<int,std::string>> lines;} sink;
    npc_set_log_callback([](void* ctx,int32_t level,const char* msg){
        auto* s=static_cast<Sink*>(ctx);std::lock_guard lock(s->m);s->lines.emplace_back(level,msg);
    },&sink,NPC_LOG_INFO);
    char* err=nullptr;
    npc_backend* down=npc_backend_create_stub(R"({"available":false})",&err);
    npc_service* svc=npc_service_create(down,nullptr,&err);
    const std::string req=codec::encodeRequest(baseRequest());
    char* res=npc_service_wait(svc,npc_service_submit(svc,req.c_str(),&err),2000);
    check(res&&std::string(res).find("\"source\":\"fallback\"")!=std::string::npos,"unavailable backend falls back");
    npc_string_free(res);
    {
        std::lock_guard lock(sink.m);
        const bool warned=std::any_of(sink.lines.begin(),sink.lines.end(),[](const auto& l){
            return l.first==NPC_LOG_WARNING&&l.second.find("fallback line for 'okafor'")!=std::string::npos;});
        check(warned,"fallback logged as a warning with the character and reason");
        check(std::none_of(sink.lines.begin(),sink.lines.end(),[](const auto& l){return l.first<NPC_LOG_INFO;}),"debug filtered at info");
    }
    npc_set_log_callback(nullptr,nullptr,NPC_LOG_DEBUG);
    npc_log_message(NPC_LOG_ERROR,"after silencing");
    {std::lock_guard lock(sink.m);check(sink.lines.back().second!="after silencing","silenced sink drops messages");}
    npc_service_destroy(svc);npc_backend_release(down);

    // Older caller: zeroed struct_size and garbage where the newer `unload` field would be.
    npc_backend_callbacks cb{};
    std::memset(&cb.unload,0xAB,sizeof cb.unload);
    cb.struct_size=0;
    cb.name="legacy";
    npc_backend* legacy=npc_backend_create(&cb);
    check(legacy!=nullptr,"legacy callbacks accepted");
    npc_backend_prewarm(legacy);
    npc_backend_unload(legacy);           // must not call the garbage pointer
    npc_backend_release(legacy);
}
} // namespace

int main(){
    try{
        vocabulary();grounding();prompts();validation();fallbacks();
        serviceModelAndCache();serviceFallbacks();serviceBudgetsAndCancellation();
        personaPrompt();codecRoundTrip();projects();loggingAndCallbacks();
    }catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
    std::cout<<"NPCCore tests passed\n";
    return 0;
}
