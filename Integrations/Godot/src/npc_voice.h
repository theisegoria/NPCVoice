// NPCVoice node for Godot 4 (GDExtension). Thin layer over the C++ wrapper
// (Integrations/cpp/include/npcvoice/npcvoice.hpp); all model work happens off the main thread.
#pragma once

#include "npcvoice/npcvoice.hpp"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <deque>
#include <memory>
#include <mutex>
#include <thread>

namespace godot {

class NPCVoice : public Node {
    GDCLASS(NPCVoice, Node)

public:
    NPCVoice();
    ~NPCVoice() override;

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    // Opens the project, model and speech on a background thread; emits `opened(error)`.
    void open();
    bool is_open() const;

    // Each returns a ticket (0 on failure, with `failed` emitted); the line arrives in `line_ready`.
    int64_t say(const String &character, const String &player_line, const Dictionary &state = Dictionary());
    int64_t react(const String &character, const String &event, const Dictionary &state = Dictionary());
    bool cancel(int64_t ticket);

    // Streams speech by sentence: `speech_chunk` per piece, then `speech_finished`.
    int64_t speak(const String &text, const String &voice, double speed = 1.0);
    bool cancel_speech(int64_t ticket);

    void unload_model();
    void prewarm_model();

    void set_project_path(const String &p) { project_path = p; }
    String get_project_path() const { return project_path; }
    void set_backend(const String &b) { backend = b; }
    String get_backend() const { return backend; }
    void set_backend_config(const String &c) { backend_config = c; }
    String get_backend_config() const { return backend_config; }
    void set_speech_enabled(bool on) { speech_enabled = on; }
    bool get_speech_enabled() const { return speech_enabled; }
    void set_models_dir(const String &d) { models_dir = d; }
    String get_models_dir() const { return models_dir; }
    void set_open_on_ready(bool on) { open_on_ready = on; }
    bool get_open_on_ready() const { return open_on_ready; }

protected:
    static void _bind_methods();

private:
    // Shared with worker threads and SDK callbacks, so it outlives the node if needed.
    struct Inbox {
        std::mutex mutex;
        std::unique_ptr<npcvoice::Session> session;   // set once by the opening thread
        bool opened = false;
        std::string open_error;
        struct Chunk { uint64_t ticket; std::vector<float> samples; double start; uint32_t index; bool last; std::string info; };
        struct Done { uint64_t ticket; int status; std::string error; };
        std::deque<Chunk> chunks;
        std::deque<Done> dones;
    };

    int64_t submit(npcvoice::Call call, const Dictionary &state);
    const npcvoice::Session *session() const;

    String project_path = "res://npc/Game.npcproj";
    String backend = "mlx";
    String backend_config;
    String models_dir;
    bool speech_enabled = true;
    bool open_on_ready = true;
    bool reported_open = false;
    std::shared_ptr<Inbox> inbox = std::make_shared<Inbox>();
    std::thread opener;
};

} // namespace godot
