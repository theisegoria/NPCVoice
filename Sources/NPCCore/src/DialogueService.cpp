// Dialogue worker service and the deterministic stub backend.
#include "Log.hpp"
#include "Dialogue.hpp"
#include "DialogueJson.hpp"

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <list>
#include <stdexcept>
#include <thread>
#include <unordered_map>

namespace npc::dialogue {

namespace {
using Clock=std::chrono::steady_clock;

FallbackReason reasonFor(BackendStatus s){
    switch(s){
    case BackendStatus::Unavailable:return FallbackReason::BackendUnavailable;
    case BackendStatus::Refusal:return FallbackReason::Refusal;
    case BackendStatus::Guardrail:return FallbackReason::ModelGuardrail;
    case BackendStatus::ContextExceeded:return FallbackReason::ContextExceeded;
    case BackendStatus::UnsupportedLanguage:return FallbackReason::UnsupportedLanguage;
    case BackendStatus::RateLimited:return FallbackReason::RateLimited;
    case BackendStatus::DecodingFailure:return FallbackReason::SchemaInvalid;
    default:return FallbackReason::BackendError;
    }
}
} // namespace

struct DialogueService::Impl {
    struct Pending {
        Ticket ticket{};
        DialogueRequest request;
        Clock::time_point submitted;
    };
    struct Slot {
        std::mutex mutex;
        std::condition_variable cv;
        std::optional<BackendResponse> response;
    };

    std::shared_ptr<DialogueBackend> backend;
    ServiceConfig config;
    mutable std::mutex mutex;
    std::condition_variable workCv,doneCv;
    std::deque<Pending> queue;
    std::vector<DialogueResult> ready;
    Ticket next{0};
    Ticket running{0};
    std::optional<CancellationSource> runningCancel;
    bool stop{false};
    ServiceStats stats;
    // LRU cache of validated model lines.
    std::list<std::pair<std::uint64_t,DialogueLine>> lru;
    std::unordered_map<std::uint64_t,decltype(lru)::iterator> cacheIndex;
    std::thread worker;

    void publish(DialogueResult r){
        std::lock_guard lock(mutex);
        switch(r.status==ResultStatus::Cancelled?LineSource::Fallback:r.source){
        case LineSource::Model:++stats.completedModel;break;
        case LineSource::Cache:++stats.completedCache;break;
        case LineSource::Fallback:
            if(r.status==ResultStatus::Cancelled) ++stats.cancelled;
            else{++stats.completedFallback;if(r.fallbackReason==FallbackReason::Timeout) ++stats.timeouts;}
            break;
        }
        if(r.ticket==running){running=0;runningCancel.reset();}   // completed: no longer cancellable
        if(r.status==ResultStatus::Line&&r.source==LineSource::Fallback&&log::enabled(log::Warning)){
            log::emit(log::Warning,"fallback line for '"+r.line.characterId+"' ("+std::string(fallbackReasonName(r.fallbackReason))+
                      (r.diagnostic.empty()?"":": "+r.diagnostic)+")");
        } else if(log::enabled(log::Debug)){
            log::emit(log::Debug,"ticket "+std::to_string(r.ticket)+" "+(r.source==LineSource::Model?"model":r.source==LineSource::Cache?"cache":"cancelled")+
                      " in "+std::to_string(r.latency.count()/1000)+" ms");
        }
        ready.push_back(std::move(r));
        doneCv.notify_all();
    }
    static DialogueResult fallbackResult(Ticket t,const DialogueRequest& req,FallbackReason why,std::string diag,Clock::time_point submitted,Intent preferred=Intent::Deflect){
        DialogueResult r;
        r.ticket=t;r.status=ResultStatus::Line;r.source=LineSource::Fallback;r.fallbackReason=why;
        r.line=fallbackLine(req,preferred);r.diagnostic=std::move(diag);
        r.latency=std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-submitted);
        return r;
    }
    static DialogueResult cancelledResult(Ticket t,Clock::time_point submitted){
        DialogueResult r;r.ticket=t;r.status=ResultStatus::Cancelled;r.source=LineSource::Fallback;
        r.latency=std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-submitted);
        return r;
    }

    std::optional<DialogueLine> cacheGet(std::uint64_t key){
        std::lock_guard lock(mutex);
        auto it=cacheIndex.find(key);
        if(it==cacheIndex.end()) return std::nullopt;
        lru.splice(lru.begin(),lru,it->second);
        return it->second->second;
    }
    void cachePut(std::uint64_t key,const DialogueLine& line){
        std::lock_guard lock(mutex);
        if(config.cacheCapacity==0) return;
        if(auto it=cacheIndex.find(key);it!=cacheIndex.end()){it->second->second=line;lru.splice(lru.begin(),lru,it->second);return;}
        lru.emplace_front(key,line);
        cacheIndex[key]=lru.begin();
        while(lru.size()>config.cacheCapacity){cacheIndex.erase(lru.back().first);lru.pop_back();}
    }

    void process(Pending p,CancellationSource cancel){
        const auto& req=p.request;
        const auto deadline=p.submitted+req.budget.deadline;
        if(cancel.cancelled()){publish(cancelledResult(p.ticket,p.submitted));return;}
        if(Clock::now()>=deadline){publish(fallbackResult(p.ticket,req,FallbackReason::Timeout,"deadline passed while queued",p.submitted));return;}
        PreparedPrompt prepared;
        try{prepared=preparePrompt(req);}
        catch(const std::exception& e){publish(fallbackResult(p.ticket,req,FallbackReason::InvalidRequest,e.what(),p.submitted));return;}
        const bool cacheable=req.allowCache;
        if(cacheable){
            if(auto hit=cacheGet(prepared.cacheKey)){
                DialogueResult r;r.ticket=p.ticket;r.source=LineSource::Cache;r.line=*hit;r.usedFactIds=prepared.grounding.usedFactIds;
                r.latency=std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-p.submitted);
                publish(std::move(r));return;
            }
        }
        if(const auto a=backend->availability();a!=Availability::Available){
            publish(fallbackResult(p.ticket,req,FallbackReason::BackendUnavailable,std::string("backend ")+std::string(availabilityName(a)),p.submitted));return;}
        if(!backend->supportsLanguage(req.character.language)){
            publish(fallbackResult(p.ticket,req,FallbackReason::UnsupportedLanguage,"backend does not support the character's language",p.submitted));return;}

        auto slot=std::make_shared<Slot>();
        auto token=cancel.token();
        token.onCancel([slot]{std::lock_guard l(slot->mutex);slot->cv.notify_all();});
        backend->generate(prepared.backend,token,[slot](BackendResponse r){
            std::lock_guard l(slot->mutex);
            if(!slot->response) slot->response=std::move(r);
            slot->cv.notify_all();});

        std::unique_lock l(slot->mutex);
        slot->cv.wait_until(l,deadline,[&]{return slot->response.has_value()||cancel.cancelled();});
        if(!slot->response){
            const bool timedOut=!cancel.cancelled();
            l.unlock();
            cancel.cancel();
            l.lock();
            const bool finished=slot->cv.wait_for(l,config.cancelGrace,[&]{return slot->response.has_value();});
            l.unlock();                                  // never hold the slot lock while taking the service lock
            if(!finished){std::lock_guard g(mutex);++stats.abandoned;}
            if(timedOut) publish(fallbackResult(p.ticket,req,FallbackReason::Timeout,"backend exceeded the deadline",p.submitted));
            else publish(cancelledResult(p.ticket,p.submitted));
            return;
        }
        BackendResponse resp=std::move(*slot->response);
        l.unlock();
        if(cancel.cancelled()||resp.status==BackendStatus::Cancelled){publish(cancelledResult(p.ticket,p.submitted));return;}
        if(resp.status!=BackendStatus::Ok){
            auto r=fallbackResult(p.ticket,req,reasonFor(resp.status),std::string(backendStatusName(resp.status))+(resp.diagnostic.empty()?"":": "+resp.diagnostic),p.submitted,
                resp.status==BackendStatus::Refusal||resp.status==BackendStatus::Guardrail?Intent::Refuse:Intent::Deflect);
            r.promptTokens=resp.promptTokens;r.outputTokens=resp.outputTokens;
            publish(std::move(r));return;
        }
        auto v=validateResponse(resp.json,req,prepared.grounding,config.guardrails);
        if(!v.ok){
            auto r=fallbackResult(p.ticket,req,v.reason,v.diagnostic,p.submitted);
            r.promptTokens=resp.promptTokens;r.outputTokens=resp.outputTokens;
            publish(std::move(r));return;
        }
        if(cacheable) cachePut(prepared.cacheKey,v.line);
        DialogueResult r;
        r.ticket=p.ticket;r.source=LineSource::Model;r.line=std::move(v.line);r.diagnostic=std::move(v.diagnostic);
        r.promptTokens=resp.promptTokens;r.outputTokens=resp.outputTokens;r.usedFactIds=prepared.grounding.usedFactIds;
        r.latency=std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-p.submitted);
        publish(std::move(r));
    }

    void run(){
        for(;;){
            Pending p;
            CancellationSource cancel;
            {
                std::unique_lock lock(mutex);
                workCv.wait(lock,[&]{return stop||!queue.empty();});
                if(stop) return;
                auto best=std::max_element(queue.begin(),queue.end(),[](const Pending& a,const Pending& b){
                    return a.request.priority!=b.request.priority?a.request.priority<b.request.priority:a.ticket>b.ticket;});
                p=std::move(*best);
                queue.erase(best);
                running=p.ticket;
                runningCancel=cancel;
            }
            process(std::move(p),cancel);
            std::lock_guard lock(mutex);
            running=0;runningCancel.reset();
        }
    }
};

DialogueService::DialogueService(std::shared_ptr<DialogueBackend> backend,ServiceConfig config):impl_(std::make_unique<Impl>()){
    if(!backend) throw std::invalid_argument("dialogue: service needs a backend");
    impl_->backend=std::move(backend);
    impl_->config=std::move(config);
    impl_->worker=std::thread([this]{impl_->run();});
}
DialogueService::~DialogueService(){
    std::optional<CancellationSource> running;
    {
        std::lock_guard lock(impl_->mutex);
        impl_->stop=true;
        running=impl_->runningCancel;
    }
    if(running) running->cancel();                     // outside the service lock (callbacks take slot locks)
    impl_->workCv.notify_all();
    if(impl_->worker.joinable()) impl_->worker.join();
}
Ticket DialogueService::submit(DialogueRequest request){
    std::unique_lock lock(impl_->mutex);
    const Ticket t=++impl_->next;
    ++impl_->stats.submitted;
    const auto now=Clock::now();
    if(impl_->queue.size()>=impl_->config.queueCapacity){
        ++impl_->stats.rejected;
        lock.unlock();
        impl_->publish(Impl::fallbackResult(t,request,FallbackReason::QueueFull,"dialogue queue is full",now));
        return t;
    }
    impl_->queue.push_back({t,std::move(request),now});
    lock.unlock();
    impl_->workCv.notify_one();
    return t;
}
bool DialogueService::cancel(Ticket t){
    std::unique_lock lock(impl_->mutex);
    auto it=std::find_if(impl_->queue.begin(),impl_->queue.end(),[&](const Impl::Pending& p){return p.ticket==t;});
    if(it!=impl_->queue.end()){
        const auto submitted=it->submitted;
        impl_->queue.erase(it);
        lock.unlock();
        impl_->publish(Impl::cancelledResult(t,submitted));
        return true;
    }
    if(impl_->running==t&&impl_->runningCancel){
        auto src=*impl_->runningCancel;
        lock.unlock();
        src.cancel();
        return true;
    }
    return false;
}
std::vector<DialogueResult> DialogueService::drainCompleted(){
    std::lock_guard lock(impl_->mutex);
    std::vector<DialogueResult> out;
    out.swap(impl_->ready);
    std::sort(out.begin(),out.end(),[](const DialogueResult& a,const DialogueResult& b){return a.ticket<b.ticket;});
    return out;
}
std::optional<DialogueResult> DialogueService::waitFor(Ticket t,std::chrono::milliseconds timeout){
    std::unique_lock lock(impl_->mutex);
    std::optional<DialogueResult> found;
    impl_->doneCv.wait_for(lock,timeout,[&]{
        auto it=std::find_if(impl_->ready.begin(),impl_->ready.end(),[&](const DialogueResult& r){return r.ticket==t;});
        if(it==impl_->ready.end()) return false;
        found=std::move(*it);impl_->ready.erase(it);return true;});
    return found;
}
ServiceStats DialogueService::stats() const{std::lock_guard lock(impl_->mutex);return impl_->stats;}
void DialogueService::clearCache(){std::lock_guard lock(impl_->mutex);impl_->lru.clear();impl_->cacheIndex.clear();}

// ---------------------------------------------------------------- stub backend

struct StubBackend::Impl {
    Config config;
    std::mutex mutex;
    std::vector<std::thread> threads;
    std::atomic<std::uint64_t> calls{0};
};
StubBackend::StubBackend():StubBackend(Config{}){}
StubBackend::StubBackend(Config c):impl_(std::make_unique<Impl>()){impl_->config=std::move(c);}
StubBackend::~StubBackend(){
    std::vector<std::thread> ts;
    {std::lock_guard l(impl_->mutex);ts.swap(impl_->threads);}
    for(auto& t:ts) if(t.joinable()) t.join();
}
BackendInfo StubBackend::info() const{return {"stub",8192,true};}
Availability StubBackend::availability() const{return impl_->config.availability;}
bool StubBackend::supportsLanguage(Language l) const{
    return std::find(impl_->config.languages.begin(),impl_->config.languages.end(),l)!=impl_->config.languages.end();
}
std::uint64_t StubBackend::calls() const{return impl_->calls.load();}

BackendResponse StubBackend::defaultResponse(const BackendRequest& r){
    // Speaks the first grounded fact, which the instructions list after "Facts you know:".
    std::string fact;
    if(auto at=r.instructions.find("Facts you know:\n- ");at!=std::string::npos){
        at+=std::string_view("Facts you know:\n- ").size();
        fact=r.instructions.substr(at,r.instructions.find('\n',at)-at);
    }
    const bool ja=r.language==Language::Japanese;
    std::string text=fact.empty()?(ja?"それについては何も知らない。":"I don't know anything about that."):fact;
    const Emotion e=r.schema.emotions.empty()?Emotion::Neutral:r.schema.emotions.front();
    const Intent in=r.schema.intents.empty()?Intent::Inform:(std::find(r.schema.intents.begin(),r.schema.intents.end(),Intent::Inform)!=r.schema.intents.end()?Intent::Inform:r.schema.intents.front());
    BackendResponse out;
    out.status=BackendStatus::Ok;
    out.json="{\"text\":"+json::quote(text)+",\"emotion\":"+json::quote(emotionToken(e))+",\"intent\":"+json::quote(intentToken(in))+",\"commands\":[]}";
    out.promptTokens=estimateTokens(r.instructions)+estimateTokens(r.prompt);
    out.outputTokens=estimateTokens(out.json);
    return out;
}

void StubBackend::generate(BackendRequest request,CancellationToken token,std::function<void(BackendResponse)> done){
    ++impl_->calls;
    auto respond=[cfg=&impl_->config,request=std::move(request),token,done=std::move(done)]{
        const auto until=Clock::now()+cfg->delay;
        while(Clock::now()<until){
            if(token.cancelled()){done(BackendResponse{BackendStatus::Cancelled,{},0,0,"cancelled"});return;}
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if(token.cancelled()){done(BackendResponse{BackendStatus::Cancelled,{},0,0,"cancelled"});return;}
        done(cfg->responder?cfg->responder(request):defaultResponse(request));
    };
    if(impl_->config.delay.count()==0){respond();return;}
    std::lock_guard l(impl_->mutex);
    impl_->threads.emplace_back(std::move(respond));
}

} // namespace npc::dialogue
