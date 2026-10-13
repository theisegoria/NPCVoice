#include "npc_voice.h"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cstring>

using namespace godot;

namespace {
std::string utf8(const String &s) { return std::string(s.utf8().get_data()); }
String from_utf8(const std::string &s) { return String::utf8(s.c_str()); }

std::vector<std::string> strings(const Variant &v) {
    std::vector<std::string> out;
    if (v.get_type() == Variant::ARRAY || v.get_type() == Variant::PACKED_STRING_ARRAY) {
        Array a = v;
        for (int i = 0; i < a.size(); ++i) out.push_back(utf8(String(a[i])));
    }
    return out;
}
} // namespace

NPCVoice::NPCVoice() {}

NPCVoice::~NPCVoice() {
    if (opener.joinable()) opener.join();
}

void NPCVoice::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open"), &NPCVoice::open);
    ClassDB::bind_method(D_METHOD("is_open"), &NPCVoice::is_open);
    ClassDB::bind_method(D_METHOD("say", "character", "player_line", "state"), &NPCVoice::say, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("react", "character", "event", "state"), &NPCVoice::react, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("cancel", "ticket"), &NPCVoice::cancel);
    ClassDB::bind_method(D_METHOD("speak", "text", "voice", "speed"), &NPCVoice::speak, DEFVAL(1.0));
    ClassDB::bind_method(D_METHOD("cancel_speech", "ticket"), &NPCVoice::cancel_speech);
    ClassDB::bind_method(D_METHOD("unload_model"), &NPCVoice::unload_model);
    ClassDB::bind_method(D_METHOD("prewarm_model"), &NPCVoice::prewarm_model);

    ClassDB::bind_method(D_METHOD("set_project_path", "path"), &NPCVoice::set_project_path);
    ClassDB::bind_method(D_METHOD("get_project_path"), &NPCVoice::get_project_path);
    ClassDB::bind_method(D_METHOD("set_backend", "backend"), &NPCVoice::set_backend);
    ClassDB::bind_method(D_METHOD("get_backend"), &NPCVoice::get_backend);
    ClassDB::bind_method(D_METHOD("set_backend_config", "json"), &NPCVoice::set_backend_config);
    ClassDB::bind_method(D_METHOD("get_backend_config"), &NPCVoice::get_backend_config);
    ClassDB::bind_method(D_METHOD("set_speech_enabled", "enabled"), &NPCVoice::set_speech_enabled);
    ClassDB::bind_method(D_METHOD("get_speech_enabled"), &NPCVoice::get_speech_enabled);
    ClassDB::bind_method(D_METHOD("set_models_dir", "path"), &NPCVoice::set_models_dir);
    ClassDB::bind_method(D_METHOD("get_models_dir"), &NPCVoice::get_models_dir);
    ClassDB::bind_method(D_METHOD("set_open_on_ready", "enabled"), &NPCVoice::set_open_on_ready);
    ClassDB::bind_method(D_METHOD("get_open_on_ready"), &NPCVoice::get_open_on_ready);

    // A .npcproj folder, or its one-file form from `npcvoice bundle` (works inside an exported .pck).
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "project_path"), "set_project_path", "get_project_path");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "backend", PROPERTY_HINT_ENUM, "mlx,apple,stub"), "set_backend", "get_backend");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "backend_config", PROPERTY_HINT_MULTILINE_TEXT), "set_backend_config", "get_backend_config");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "speech_enabled"), "set_speech_enabled", "get_speech_enabled");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "models_dir", PROPERTY_HINT_GLOBAL_DIR), "set_models_dir", "get_models_dir");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "open_on_ready"), "set_open_on_ready", "get_open_on_ready");

    ADD_SIGNAL(MethodInfo("opened", PropertyInfo(Variant::STRING, "error")));
    ADD_SIGNAL(MethodInfo("line_ready", PropertyInfo(Variant::DICTIONARY, "result")));
    ADD_SIGNAL(MethodInfo("failed", PropertyInfo(Variant::STRING, "error")));
    ADD_SIGNAL(MethodInfo("speech_chunk", PropertyInfo(Variant::INT, "ticket"), PropertyInfo(Variant::PACKED_FLOAT32_ARRAY, "samples"),
                          PropertyInfo(Variant::FLOAT, "start_time"), PropertyInfo(Variant::INT, "index"),
                          PropertyInfo(Variant::BOOL, "last"), PropertyInfo(Variant::DICTIONARY, "info")));
    ADD_SIGNAL(MethodInfo("speech_finished", PropertyInfo(Variant::INT, "ticket"), PropertyInfo(Variant::INT, "status"),
                          PropertyInfo(Variant::STRING, "error")));
}

void NPCVoice::_ready() {
    set_process(true);
    if (open_on_ready) open();
}

void NPCVoice::_exit_tree() {
    if (opener.joinable()) opener.join();
}

void NPCVoice::open() {
    if (opener.joinable() || is_open()) return;
    npcvoice::Session::Options options;
    // A bundled one-file project is read through Godot's file system (works inside a .pck);
    // a .npcproj folder must be a real folder (outside the .pck).
    if (project_path.ends_with(".json")) options.projectJson = utf8(FileAccess::get_file_as_string(project_path));
    else options.projectPath = utf8(ProjectSettings::get_singleton()->globalize_path(project_path));
    options.backend = utf8(backend);
    options.backendConfigJson = utf8(backend_config);
    options.speech = speech_enabled;
    options.modelsDir = models_dir.is_empty() ? "" : utf8(ProjectSettings::get_singleton()->globalize_path(models_dir));
    std::shared_ptr<Inbox> box = inbox;
    opener = std::thread([box, options] {
        std::string error;
        auto session = npcvoice::Session::open(options, &error);
        std::lock_guard<std::mutex> lock(box->mutex);
        box->session = std::move(session);
        box->open_error = box->session ? "" : (error.empty() ? "could not open NPCVoice" : error);
        box->opened = true;
    });
}

bool NPCVoice::is_open() const {
    std::lock_guard<std::mutex> lock(inbox->mutex);
    return inbox->session != nullptr;
}

const npcvoice::Session *NPCVoice::session() const {
    std::lock_guard<std::mutex> lock(inbox->mutex);
    return inbox->session.get();
}

int64_t NPCVoice::submit(npcvoice::Call call, const Dictionary &state) {
    const npcvoice::Session *s = session();
    if (!s) { emit_signal("failed", String("NPCVoice is not open yet (wait for `opened`)")); return 0; }
    if (state.has("flags")) call.flags(strings(state["flags"]));
    if (state.has("memories")) call.memories(strings(state["memories"]));
    if (state.has("topics")) call.topics(strings(state["topics"]));
    if (state.has("location")) call.location(utf8(String(state["location"])));
    if (state.has("objective")) call.objective(utf8(String(state["objective"])));
    if (state.has("mood")) call.mood(utf8(String(state["mood"])));
    if (state.has("deadline_ms")) call.deadlineMs(static_cast<uint32_t>(int64_t(state["deadline_ms"])));
    std::string error;
    const uint64_t ticket = s->say(call, &error);
    if (!ticket) emit_signal("failed", from_utf8(error));
    return static_cast<int64_t>(ticket);
}

int64_t NPCVoice::say(const String &character, const String &player_line, const Dictionary &state) {
    return submit(npcvoice::Call(utf8(character)).player(utf8(player_line)), state);
}

int64_t NPCVoice::react(const String &character, const String &event, const Dictionary &state) {
    return submit(npcvoice::Call(utf8(character)).event(utf8(event)), state);
}

bool NPCVoice::cancel(int64_t ticket) {
    const npcvoice::Session *s = session();
    return s && s->service().cancel(static_cast<uint64_t>(ticket));
}

int64_t NPCVoice::speak(const String &text, const String &voice, double speed) {
    const npcvoice::Session *s = session();
    if (!s || !s->speech()) { emit_signal("failed", String("speech is not available (open first, with speech_enabled)")); return 0; }
    std::shared_ptr<Inbox> box = inbox;
    std::string error;
    const uint64_t ticket = s->speech()->submit(utf8(text), utf8(voice), speed,
        [box](uint64_t t, const npcvoice::SpeechChunk &c) {
            Inbox::Chunk chunk{t, std::vector<float>(c.samples, c.samples + c.sampleCount), c.startTime, c.index, c.last,
                               std::string(c.infoJson)};
            std::lock_guard<std::mutex> lock(box->mutex);
            box->chunks.push_back(std::move(chunk));
        },
        [box](uint64_t t, int status, std::string_view err) {
            std::lock_guard<std::mutex> lock(box->mutex);
            box->dones.push_back({t, status, std::string(err)});
        }, &error);
    if (!ticket) emit_signal("failed", from_utf8(error));
    return static_cast<int64_t>(ticket);
}

bool NPCVoice::cancel_speech(int64_t ticket) {
    const npcvoice::Session *s = session();
    return s && s->speech() && s->speech()->cancel(static_cast<uint64_t>(ticket));
}

void NPCVoice::unload_model() {
    if (const npcvoice::Session *s = session()) s->backend().unload();
}

void NPCVoice::prewarm_model() {
    if (const npcvoice::Session *s = session()) s->backend().prewarm();
}

void NPCVoice::_process(double) {
    std::deque<Inbox::Chunk> chunks;
    std::deque<Inbox::Done> dones;
    bool report = false;
    std::string open_error;
    const npcvoice::Session *s = nullptr;
    {
        std::lock_guard<std::mutex> lock(inbox->mutex);
        chunks.swap(inbox->chunks);
        dones.swap(inbox->dones);
        if (inbox->opened && !reported_open) { report = true; open_error = inbox->open_error; }
        s = inbox->session.get();
    }
    if (report) {
        reported_open = true;
        if (opener.joinable()) opener.join();
        emit_signal("opened", from_utf8(open_error));
    }
    if (s) {
        const std::string done = s->service().drain();
        if (done.size() > 2) {
            Variant parsed = JSON::parse_string(from_utf8(done));
            if (parsed.get_type() == Variant::ARRAY) {
                Array results = parsed;
                for (int i = 0; i < results.size(); ++i) emit_signal("line_ready", results[i]);
            }
        }
    }
    for (auto &c : chunks) {
        PackedFloat32Array samples;
        samples.resize(static_cast<int64_t>(c.samples.size()));
        if (!c.samples.empty()) std::memcpy(samples.ptrw(), c.samples.data(), c.samples.size() * sizeof(float));
        Variant parsed_info = JSON::parse_string(from_utf8(c.info));
        Dictionary info;
        if (parsed_info.get_type() == Variant::DICTIONARY) info = parsed_info;
        emit_signal("speech_chunk", static_cast<int64_t>(c.ticket), samples, c.start, static_cast<int64_t>(c.index), c.last, info);
    }
    for (auto &d : dones) emit_signal("speech_finished", static_cast<int64_t>(d.ticket), d.status, from_utf8(d.error));
}
