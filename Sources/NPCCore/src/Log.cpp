// SDK log sink (npc_set_log_callback).
#include "npc_core.h"
#include "Log.hpp"

#include <atomic>
#include <mutex>

namespace {
std::mutex sinkMutex;
npc_log_fn sinkFn=nullptr;
void* sinkContext=nullptr;
std::atomic<int> sinkMin{NPC_LOG_INFO};
std::atomic<bool> sinkSet{false};
}

namespace npc::log {
bool enabled(int level){ return sinkSet.load(std::memory_order_relaxed)&&level>=sinkMin.load(std::memory_order_relaxed); }
void emit(int level,const std::string& message){
    std::lock_guard lock(sinkMutex);   // serialised: a game's logger need not be thread-safe
    if(sinkFn&&level>=sinkMin.load()) sinkFn(sinkContext,level,message.c_str());
}
}

extern "C" {
void npc_set_log_callback(npc_log_fn fn,void* context,int32_t minLevel){
    std::lock_guard lock(sinkMutex);
    sinkFn=fn;sinkContext=context;sinkMin=minLevel;sinkSet=fn!=nullptr;
}
void npc_log_message(int32_t level,const char* message){ if(message) npc::log::emit(level,message); }
}
