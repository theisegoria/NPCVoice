// npc_core.h implementation: JSON in, JSON out over the C++ dialogue core.
#include "npc_core.h"
#include "Codec.hpp"
#include "CodecInternal.hpp"
#include "Dialogue.hpp"
#include "Project.hpp"
#include "Log.hpp"

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

using namespace npc::dialogue;

namespace {

char* dup(std::string_view s){
    char* out=static_cast<char*>(std::malloc(s.size()+1));
    if(!out) return nullptr;
    std::memcpy(out,s.data(),s.size());
    out[s.size()]='\0';
    return out;
}
void setError(char** error,std::string_view message){if(error) *error=dup(message);}
void clearError(char** error){if(error) *error=nullptr;}
std::string_view view(const char* s){return s?std::string_view(s):std::string_view();}

// A backend implemented outside C++ (Swift MLX, FoundationModels, engine code).
class CallbackBackend final : public DialogueBackend {
public:
    explicit CallbackBackend(const npc_backend_callbacks& cb):cb_(cb),name_(cb.name?cb.name:"native"){cb_.name=nullptr;}
    ~CallbackBackend() override{if(cb_.destroy) cb_.destroy(cb_.context);}
    BackendInfo info() const override{return {name_,cb_.context_tokens,cb_.guided_generation!=0};}
    Availability availability() const override{
        if(!cb_.availability) return Availability::Available;
        const int a=cb_.availability(cb_.context);
        return a>=0&&a<=4?static_cast<Availability>(a):Availability::Unsupported;
    }
    bool supportsLanguage(Language l) const override{
        if(!cb_.supports_language) return true;
        return cb_.supports_language(cb_.context,std::string(languageTag(l)).c_str())!=0;
    }
    void generate(BackendRequest r,CancellationToken token,std::function<void(BackendResponse)> done) override{
        if(!cb_.generate){done({BackendStatus::Unavailable,{},0,0,"backend has no generate callback"});return;}
        const std::uint64_t job=nextJob_.fetch_add(1)+1;
        auto* box=new std::function<void(BackendResponse)>(std::move(done));
        const std::string payload=codec::encodeBackendRequest(r);
        if(cb_.cancel){
            auto cancel=cb_.cancel;auto ctx=cb_.context;
            token.onCancel([cancel,ctx,job]{cancel(ctx,job);});
        }
        cb_.generate(cb_.context,payload.c_str(),job,&CallbackBackend::complete,box);
    }
    void prewarm(std::string_view instructions) override{
        if(cb_.prewarm) cb_.prewarm(cb_.context,std::string(instructions).c_str());
    }
    void unload() override{
        if(cb_.unload) cb_.unload(cb_.context);
    }
private:
    static void complete(void* ctx,const char* responseJson){
        std::unique_ptr<std::function<void(BackendResponse)>> done(static_cast<std::function<void(BackendResponse)>*>(ctx));
        BackendResponse r;
        try{r=codec::decodeBackendResponse(view(responseJson));}
        catch(const std::exception& e){r={BackendStatus::Error,{},0,0,std::string("malformed backend response: ")+e.what()};}
        (*done)(std::move(r));
    }
    npc_backend_callbacks cb_;
    std::string name_;
    std::atomic<std::uint64_t> nextJob_{0};
};

} // namespace

struct npc_backend {std::shared_ptr<DialogueBackend> backend;};
struct npc_service {std::unique_ptr<DialogueService> service;};
struct npc_project {Project project;};

extern "C" {

int32_t npc_core_abi_version(void){return NPC_CORE_ABI_VERSION;}
void npc_string_free(char* s){std::free(s);}

npc_backend* npc_backend_create(const npc_backend_callbacks* cb){
    if(!cb) return nullptr;
    // Copy only the fields the caller's struct has (struct_size); newer fields stay NULL.
    npc_backend_callbacks full{};
    const std::size_t n=cb->struct_size==0?offsetof(npc_backend_callbacks,unload):std::min<std::size_t>(cb->struct_size,sizeof full);
    std::memcpy(&full,cb,n);
    full.struct_size=sizeof full;
    return new npc_backend{std::make_shared<CallbackBackend>(full)};
}

void npc_backend_prewarm(npc_backend* b){ if(b) b->backend->prewarm(""); }
void npc_backend_unload(npc_backend* b){ if(b) b->backend->unload(); }



npc_backend* npc_backend_create_stub(const char* configJson,char** error){
    clearError(error);
    try{
        StubBackend::Config cfg;
        if(configJson&&*configJson){
            auto root=io::parseDocument(configJson,"stub");
            io::Reader r(root,"stub");
            cfg.delay=std::chrono::milliseconds(r.u32("delayMs",0));
            if(!r.boolean("available",true)) cfg.availability=Availability::NotEnabled;
            if(r.get("languages")){
                cfg.languages.clear();
                for(const auto& t:r.strings("languages")){
                    auto l=parseLanguageTag(t);
                    if(!l) io::fail(r.pathOf("languages"),"unsupported language '"+t+"'");
                    cfg.languages.push_back(*l);
                }
            }
            if(auto fixed=r.str("fixedResponse");!fixed.empty())
                cfg.responder=[fixed](const BackendRequest&){return BackendResponse{BackendStatus::Ok,fixed,0,0,{}};};
            r.finish();
        }
        return new npc_backend{std::make_shared<StubBackend>(std::move(cfg))};
    }catch(const std::exception& e){setError(error,e.what());return nullptr;}
}

void npc_backend_release(npc_backend* b){delete b;}

char* npc_backend_info(npc_backend* b){
    if(!b) return nullptr;
    const auto info=b->backend->info();
    io::Writer w;
    w.beginObject();
    w.key("name").string(info.name);
    w.key("contextTokens").number(info.contextTokens);
    w.key("guidedGeneration").boolean(info.guidedGeneration);
    w.key("availability").string(availabilityName(b->backend->availability()));
    w.endObject();
    return dup(w.take());
}

npc_service* npc_service_create(npc_backend* b,const char* configJson,char** error){
    clearError(error);
    if(!b){setError(error,"backend is null");return nullptr;}
    try{
        auto cfg=codec::decodeServiceConfig(view(configJson));
        return new npc_service{std::make_unique<DialogueService>(b->backend,std::move(cfg))};
    }catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
void npc_service_destroy(npc_service* s){delete s;}

uint64_t npc_service_submit(npc_service* s,const char* requestJson,char** error){
    clearError(error);
    if(!s){setError(error,"service is null");return 0;}
    try{return s->service->submit(codec::decodeRequest(view(requestJson)));}
    catch(const std::exception& e){setError(error,e.what());return 0;}
}
int32_t npc_service_cancel(npc_service* s,uint64_t t){return s&&s->service->cancel(t)?1:0;}
char* npc_service_wait(npc_service* s,uint64_t t,uint32_t timeoutMs){
    if(!s) return nullptr;
    auto r=s->service->waitFor(t,std::chrono::milliseconds(timeoutMs));
    return r?dup(codec::encodeResult(*r)):nullptr;
}
char* npc_service_drain(npc_service* s){
    if(!s) return nullptr;
    std::string out="[";
    bool first=true;
    for(const auto& r:s->service->drainCompleted()){if(!first) out+=',';first=false;out+=codec::encodeResult(r);}
    out+="]";
    return dup(out);
}
char* npc_service_stats(npc_service* s){return s?dup(codec::encodeStats(s->service->stats())):nullptr;}
void npc_service_clear_cache(npc_service* s){if(s) s->service->clearCache();}

char* npc_prepare_prompt(const char* requestJson,char** error){
    clearError(error);
    try{return dup(codec::encodePreparedPrompt(preparePrompt(codec::decodeRequest(view(requestJson)))));}
    catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
char* npc_validate_response(const char* requestJson,const char* modelJson,char** error){
    clearError(error);
    try{
        auto q=codec::decodeRequest(view(requestJson));
        auto g=groundFacts(q);
        return dup(codec::encodeValidation(validateResponse(view(modelJson),q,g)));
    }catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
char* npc_canonical_request(const char* requestJson,char** error){
    clearError(error);
    try{return dup(codec::encodeRequest(codec::decodeRequest(view(requestJson))));}
    catch(const std::exception& e){setError(error,e.what());return nullptr;}
}

npc_project* npc_project_load(const char* path,char** error){
    clearError(error);
    if(!path){setError(error,"path is null");return nullptr;}
    try{return new npc_project{loadProject(path)};}
    catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
npc_project* npc_project_load_json(const char* json,char** error){
    clearError(error);
    try{return new npc_project{decodeProject(view(json))};}
    catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
void npc_project_release(npc_project* p){delete p;}
char* npc_project_json(npc_project* p){return p?dup(encodeProject(p->project)):nullptr;}
char* npc_project_diagnostics(npc_project* p){return p?dup(encodeDiagnostics(diagnose(p->project))):nullptr;}
char* npc_project_request(npc_project* p,const char* callJson,char** error){
    clearError(error);
    if(!p){setError(error,"project is null");return nullptr;}
    try{return dup(codec::encodeRequest(buildRequest(p->project,view(callJson))));}
    catch(const std::exception& e){setError(error,e.what());return nullptr;}
}
int32_t npc_project_write_sample(const char* path,char** error){
    clearError(error);
    if(!path){setError(error,"path is null");return 0;}
    try{writeSampleProject(path);return 1;}
    catch(const std::exception& e){setError(error,e.what());return 0;}
}

} // extern "C"
