// NPCVoice for C++: RAII handles over the C ABI (npc_core.h, npc_sdk.h).
//
// Header-only, C++17, and free of exceptions, because Unreal and Godot build without them.
// Fallible calls return an empty handle, an empty optional, or ticket 0, and fill an
// optional `std::string* error`. Link NPCVoiceKit (the xcframework, or CMake's
// NPCVoiceKit::NPCVoiceKit).
//
//   auto npcs = npcvoice::Session::open({"Harbor Town.npcproj"}, &error);   // load time
//   uint64_t t = npcs->say(npcvoice::Call("marta").player("Got a room?"));    // returns at once
//   std::string finished = npcs->service().drain();                           // every frame
#pragma once

#if __has_include(<NPCVoiceKit/npc_core.h>)
#include <NPCVoiceKit/npc_core.h>
#include <NPCVoiceKit/npc_sdk.h>
#else
#include "npc_core.h"
#include "npc_sdk.h"
#endif

#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace npcvoice {

namespace detail {
// Takes ownership of a string returned by the library.
inline std::string take(char* s) {
    std::string out = s ? s : "";
    if (s) npc_string_free(s);
    return out;
}
inline void report(char* err, std::string* error) {
    if (error) *error = err ? err : "unknown error";
    if (err) npc_string_free(err);
}
inline const char* cstr(const std::string& s) { return s.empty() ? nullptr : s.c_str(); }
}  // namespace detail

// ---------------------------------------------------------------- JSON helpers

namespace json {
// A JSON string literal (quotes included) for UTF-8 text.
inline std::string quote(std::string_view s) {
    std::string out;
    out.reserve(s.size() + 2);
    out += '"';
    for (unsigned char c : s) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    out += '"';
    return out;
}
inline std::string array(const std::vector<std::string>& items) {
    std::string out = "[";
    for (size_t i = 0; i < items.size(); ++i) out += (i ? "," : "") + quote(items[i]);
    return out + "]";
}
}  // namespace json

// One game call (docs/schema/call.schema.json), built without a JSON library.
class Call {
public:
    explicit Call(std::string character) : character_(std::move(character)) {}
    Call& player(std::string_view line) { player_ = std::string(line); return *this; }
    Call& event(std::string_view what) { event_ = std::string(what); return *this; }
    Call& flags(std::vector<std::string> v) { flags_ = std::move(v); return *this; }
    Call& location(std::string_view v) { location_ = std::string(v); return *this; }
    Call& objective(std::string_view v) { objective_ = std::string(v); return *this; }
    Call& mood(std::string_view v) { mood_ = std::string(v); return *this; }
    Call& memories(std::vector<std::string> v) { memories_ = std::move(v); return *this; }
    Call& topics(std::vector<std::string> v) { topics_ = std::move(v); return *this; }
    Call& deadlineMs(uint32_t ms) { deadline_ = ms; return *this; }
    Call& priority(uint32_t p) { priority_ = p; return *this; }
    Call& allowCache(bool on) { allowCache_ = on; return *this; }

    std::string json() const {
        std::string j = "{\"character\":" + json::quote(character_);
        if (!player_.empty()) j += ",\"playerUtterance\":" + json::quote(player_);
        if (!event_.empty()) j += ",\"trigger\":" + json::quote(event_);
        if (!flags_.empty()) j += ",\"flags\":" + json::array(flags_);
        if (!location_.empty()) j += ",\"location\":" + json::quote(location_);
        if (!objective_.empty()) j += ",\"objective\":" + json::quote(objective_);
        if (!mood_.empty()) j += ",\"mood\":" + json::quote(mood_);
        if (!memories_.empty()) j += ",\"memories\":" + json::array(memories_);
        if (!topics_.empty()) j += ",\"topics\":" + json::array(topics_);
        if (deadline_) j += ",\"budget\":{\"deadlineMs\":" + std::to_string(*deadline_) + "}";
        if (priority_) j += ",\"priority\":" + std::to_string(*priority_);
        if (allowCache_) j += std::string(",\"allowCache\":") + (*allowCache_ ? "true" : "false");
        return j + "}";
    }

private:
    std::string character_, player_, event_, location_, objective_, mood_;
    std::vector<std::string> flags_, memories_, topics_;
    std::optional<uint32_t> deadline_, priority_;
    std::optional<bool> allowCache_;
};

// ---------------------------------------------------------------- logging

// Routes the SDK's diagnostics to `handler` (nullptr silences). Calls arrive on SDK threads,
// one at a time.
inline void setLogHandler(std::function<void(int level, std::string_view message)> handler,
                          int minLevel = NPC_LOG_INFO) {
    static std::mutex mutex;
    static std::function<void(int, std::string_view)> current;
    {
        std::lock_guard<std::mutex> lock(mutex);
        current = std::move(handler);
    }
    if (!current) { npc_set_log_callback(nullptr, nullptr, minLevel); return; }
    npc_set_log_callback([](void*, int32_t level, const char* message) {
        std::function<void(int, std::string_view)> h;
        { std::lock_guard<std::mutex> lock(mutex); h = current; }
        if (h && message) h(level, message);
    }, nullptr, minLevel);
}

// ---------------------------------------------------------------- handles

class Project {
public:
    Project() = default;
    static Project load(const std::string& path, std::string* error = nullptr) {
        char* err = nullptr;
        Project p(npc_project_load(path.c_str(), &err));
        if (!p) detail::report(err, error);
        return p;
    }
    static Project fromJson(const std::string& projectJson, std::string* error = nullptr) {
        char* err = nullptr;
        Project p(npc_project_load_json(projectJson.c_str(), &err));
        if (!p) detail::report(err, error);
        return p;
    }
    explicit operator bool() const { return p_ != nullptr; }
    npc_project* get() const { return p_.get(); }

    std::string json() const { return detail::take(npc_project_json(p_.get())); }
    std::string diagnostics() const { return detail::take(npc_project_diagnostics(p_.get())); }
    // A dialogue request for one game call.
    std::optional<std::string> request(const std::string& callJson, std::string* error = nullptr) const {
        char* err = nullptr;
        char* r = npc_project_request(p_.get(), callJson.c_str(), &err);
        if (!r) { detail::report(err, error); return std::nullopt; }
        return detail::take(r);
    }

private:
    struct Release { void operator()(npc_project* p) const { npc_project_release(p); } };
    explicit Project(npc_project* p) : p_(p) {}
    std::unique_ptr<npc_project, Release> p_;
};

class Backend {
public:
    Backend() = default;
    // The bundled model. configJson: {"modelDir","cacheMB","warmUp"} or empty. Blocks while
    // loading (with warmUp): call at load time, off the game thread.
    static Backend mlx(const std::string& configJson = "", std::string* error = nullptr) {
        char* err = nullptr;
        Backend b(npc_backend_create_mlx(detail::cstr(configJson), &err));
        if (!b) detail::report(err, error);
        return b;
    }
    static Backend apple(std::string* error = nullptr) {
        char* err = nullptr;
        Backend b(npc_backend_create_apple(&err));
        if (!b) detail::report(err, error);
        return b;
    }
    // Deterministic test backend: {"delayMs","available","languages","fixedResponse"}.
    static Backend stub(const std::string& configJson = "", std::string* error = nullptr) {
        char* err = nullptr;
        Backend b(npc_backend_create_stub(detail::cstr(configJson), &err));
        if (!b) detail::report(err, error);
        return b;
    }
    explicit operator bool() const { return b_ != nullptr; }
    npc_backend* get() const { return b_.get(); }

    std::string info() const { return detail::take(npc_backend_info(b_.get())); }
    void prewarm() const { npc_backend_prewarm(b_.get()); }
    void unload() const { npc_backend_unload(b_.get()); }

private:
    struct Release { void operator()(npc_backend* b) const { npc_backend_release(b); } };
    explicit Backend(npc_backend* b) : b_(b) {}
    std::unique_ptr<npc_backend, Release> b_;
};

class Service {
public:
    Service() = default;
    // configJson: {"queueCapacity","cacheCapacity","cancelGraceMs","guardrails"} or empty.
    static Service create(const Backend& backend, const std::string& configJson = "", std::string* error = nullptr) {
        char* err = nullptr;
        Service s(npc_service_create(backend.get(), detail::cstr(configJson), &err));
        if (!s) detail::report(err, error);
        return s;
    }
    explicit operator bool() const { return s_ != nullptr; }
    npc_service* get() const { return s_.get(); }

    // Returns a ticket, or 0 (with error) for unparsable JSON.
    uint64_t submit(const std::string& requestJson, std::string* error = nullptr) const {
        char* err = nullptr;
        uint64_t t = npc_service_submit(s_.get(), requestJson.c_str(), &err);
        if (!t) detail::report(err, error);
        return t;
    }
    bool cancel(uint64_t ticket) const { return npc_service_cancel(s_.get(), ticket) != 0; }
    // Finished results as a JSON array, in ticket order. Non-blocking: call every frame.
    std::string drain() const { return detail::take(npc_service_drain(s_.get())); }
    // Blocks up to timeoutMs (tools and tests; not the game thread).
    std::optional<std::string> wait(uint64_t ticket, uint32_t timeoutMs) const {
        char* r = npc_service_wait(s_.get(), ticket, timeoutMs);
        if (!r) return std::nullopt;
        return detail::take(r);
    }
    std::string stats() const { return detail::take(npc_service_stats(s_.get())); }
    void clearCache() const { npc_service_clear_cache(s_.get()); }

private:
    struct Destroy { void operator()(npc_service* s) const { npc_service_destroy(s); } };
    explicit Service(npc_service* s) : s_(s) {}
    std::unique_ptr<npc_service, Destroy> s_;
};

// A whole line of speech.
struct Audio {
    std::vector<float> samples;   // mono, -23 LUFS
    double sampleRate = 24000;
    std::string infoJson;         // docs/schema/speech-info.schema.json
};

// One streamed piece. `samples` and `infoJson` are valid only during the callback.
struct SpeechChunk {
    const float* samples = nullptr;
    size_t sampleCount = 0;
    double sampleRate = 24000;
    double startTime = 0;         // seconds from the start of the line
    uint32_t index = 0;
    bool last = false;
    std::string_view infoJson;    // docs/schema/speech-chunk-info.schema.json
};

class Speech {
public:
    using ChunkHandler = std::function<void(uint64_t ticket, const SpeechChunk& chunk)>;
    // status: NPC_SPEECH_DONE, NPC_SPEECH_CANCELLED or NPC_SPEECH_FAILED.
    using DoneHandler = std::function<void(uint64_t ticket, int status, std::string_view error)>;

    Speech() = default;
    // modelsDir empty: $NPCVOICE_MODELS, then <app>/Contents/Resources/Models. Load time.
    static Speech create(const std::string& modelsDir = "", std::string* error = nullptr) {
        char* err = nullptr;
        Speech s(npc_speech_create(detail::cstr(modelsDir), &err));
        if (!s) detail::report(err, error);
        return s;
    }
    explicit operator bool() const { return s_ != nullptr; }
    npc_speech* get() const { return s_.get(); }

    // Uses the project's pronunciations from now on.
    bool setProject(const Project& project, std::string* error = nullptr) const {
        char* err = nullptr;
        if (npc_speech_set_project(s_.get(), project.get(), &err)) return true;
        detail::report(err, error);
        return false;
    }
    // Whole line, blocking (baking assets; not the game thread).
    std::optional<Audio> speak(const std::string& text, const std::string& voice, double speed = 1,
                               std::string* error = nullptr) const {
        char* err = nullptr;
        npc_audio* a = npc_speech_speak(s_.get(), text.c_str(), voice.c_str(), speed, &err);
        if (!a) { detail::report(err, error); return std::nullopt; }
        Audio out;
        out.samples.assign(a->pcm, a->pcm + a->sample_count);
        out.sampleRate = a->sample_rate;
        out.infoJson = a->info_json ? a->info_json : "";
        npc_audio_free(a);
        return out;
    }
    // Streamed by sentence on the SDK's worker thread; returns a ticket, or 0 with error.
    // onChunk runs once per piece, then onDone exactly once. Copy the samples and return fast.
    uint64_t submit(const std::string& text, const std::string& voice, double speed,
                    ChunkHandler onChunk, DoneHandler onDone, std::string* error = nullptr) const {
        auto* handlers = new Handlers{std::move(onChunk), std::move(onDone)};
        char* err = nullptr;
        uint64_t t = npc_speech_submit(s_.get(), text.c_str(), voice.c_str(), speed, &Speech::chunkThunk,
                                       &Speech::doneThunk, handlers, &err);
        if (!t) { delete handlers; detail::report(err, error); }
        return t;
    }
    bool cancel(uint64_t ticket) const { return npc_speech_cancel(s_.get(), ticket) != 0; }

private:
    struct Handlers { ChunkHandler chunk; DoneHandler done; };
    static void chunkThunk(void* ctx, uint64_t ticket, const npc_speech_chunk* c) {
        auto* h = static_cast<Handlers*>(ctx);
        if (!h->chunk || !c) return;
        SpeechChunk chunk;
        chunk.samples = c->pcm;
        chunk.sampleCount = static_cast<size_t>(c->sample_count);
        chunk.sampleRate = c->sample_rate;
        chunk.startTime = c->start_time;
        chunk.index = c->index;
        chunk.last = c->is_last != 0;
        chunk.infoJson = c->info_json ? std::string_view(c->info_json) : std::string_view();
        h->chunk(ticket, chunk);
    }
    static void doneThunk(void* ctx, uint64_t ticket, int32_t status, const char* error) {
        std::unique_ptr<Handlers> h(static_cast<Handlers*>(ctx));   // last call for this ticket
        if (h->done) h->done(ticket, status, error ? std::string_view(error) : std::string_view());
    }

    struct Release { void operator()(npc_speech* s) const { npc_speech_release(s); } };
    explicit Speech(npc_speech* s) : s_(s) {}
    std::unique_ptr<npc_speech, Release> s_;
};

// ---------------------------------------------------------------- session

// Everything a game needs, opened together at load time (blocking; call off the game thread).
class Session {
public:
    struct Options {
        Options() = default;
        Options(std::string path) : projectPath(std::move(path)) {}   // open({"Game.npcproj"})
        std::string projectPath;           // a .npcproj folder...
        std::string projectJson;           // ...or its one-file form (`npcvoice bundle`), e.g. read from a pack
        std::string backend = "mlx";       // "mlx", "apple" or "stub"
        std::string backendConfigJson;     // per backend (mlx: {"cacheMB",...}; stub: {"fixedResponse",...})
        std::string serviceConfigJson;
        bool speech = true;
        std::string modelsDir;             // folder with qwen3.5-2b-4bit/, kokoro-82m-coreml/, misaki-*; empty: the default search
    };

    static std::unique_ptr<Session> open(const Options& options, std::string* error = nullptr) {
        std::unique_ptr<Session> s(new Session());
        s->project_ = options.projectJson.empty() ? Project::load(options.projectPath, error)
                                                  : Project::fromJson(options.projectJson, error);
        if (!s->project_) return nullptr;
        if (options.backend == "mlx") {
            std::string config = options.backendConfigJson;
            if (config.empty() && !options.modelsDir.empty())
                config = "{\"modelDir\":" + json::quote(options.modelsDir + "/qwen3.5-2b-4bit") + "}";
            s->backend_ = Backend::mlx(config, error);
        }
        else if (options.backend == "apple") s->backend_ = Backend::apple(error);
        else if (options.backend == "stub") s->backend_ = Backend::stub(options.backendConfigJson, error);
        else { if (error) *error = "unknown backend '" + options.backend + "'"; return nullptr; }
        if (!s->backend_) return nullptr;
        s->service_ = Service::create(s->backend_, options.serviceConfigJson, error);
        if (!s->service_) return nullptr;
        if (options.speech) {
            s->speech_ = Speech::create(options.modelsDir, error);
            if (!s->speech_ || !s->speech_.setProject(s->project_, error)) return nullptr;
        }
        return s;
    }

    // Submits one game call; returns its ticket, or 0 with error (unknown character, bad call).
    uint64_t say(const Call& call, std::string* error = nullptr) const {
        auto request = project_.request(call.json(), error);
        return request ? service_.submit(*request, error) : 0;
    }

    const Project& project() const { return project_; }
    const Backend& backend() const { return backend_; }
    const Service& service() const { return service_; }
    const Speech* speech() const { return speech_ ? &speech_ : nullptr; }

private:
    Session() = default;
    Project project_;
    Backend backend_;
    Service service_;
    Speech speech_;
};

}  // namespace npcvoice
