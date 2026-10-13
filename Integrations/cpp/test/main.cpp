// Tests the C++ wrapper (Integrations/cpp/include/npcvoice/npcvoice.hpp) against the real
// library with the stub dialogue backend and the bundled speech models (no LLM on the GPU).
// Run: swift run npcvoice-cpp-tests <project.npcproj>
#include "npcvoice/npcvoice.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>

static int failures = 0;
static void check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) ++failures;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <project.npcproj>\n", argv[0]); return 64; }
    std::string error;

    // JSON helpers.
    check(npcvoice::json::quote("say \"hi\"\n\t\\ ok") == R"("say \"hi\"\n\t\\ ok")", "quote escapes quotes, backslashes and controls");
    check(npcvoice::json::quote(std::string("\x01", 1)) == R"("\u0001")", "quote escapes other control characters");
    check(npcvoice::json::quote("アイコ") == "\"アイコ\"", "quote keeps UTF-8");
    const std::string call = npcvoice::Call("marta").player("A \"room\"?").flags({"a", "b"}).deadlineMs(1500).allowCache(false).json();
    check(call == R"({"character":"marta","playerUtterance":"A \"room\"?","flags":["a","b"],"budget":{"deadlineMs":1500},"allowCache":false})",
          "Call builds compact JSON");

    // Logging.
    std::mutex logMutex;
    std::vector<std::pair<int, std::string>> logs;
    npcvoice::setLogHandler([&](int level, std::string_view m) {
        std::lock_guard<std::mutex> lock(logMutex);
        logs.emplace_back(level, std::string(m));
    }, NPC_LOG_INFO);

    // Session with a fixed stub reply.
    npcvoice::Session::Options options;
    options.projectPath = argv[1];
    options.backend = "stub";
    options.backendConfigJson =
        R"({"fixedResponse":"{\"text\":\"Three marks, love.\",\"emotion\":\"happy\",\"intent\":\"inform\",\"commands\":[{\"kind\":\"give_item\",\"target\":\"room_key\"}]}"})";
    auto session = npcvoice::Session::open(options, &error);
    check(session != nullptr, ("session opens" + (error.empty() ? "" : ": " + error)).c_str());
    if (!session) return 1;

    const uint64_t ticket = session->say(npcvoice::Call("marta").player("Got a room?"), &error);
    check(ticket > 0, "say returns a ticket");
    std::string done;
    for (int i = 0; i < 200 && done.size() <= 2; ++i) {      // drain like a frame loop
        done = session->service().drain();
        if (done.size() <= 2) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    check(done.find("\"source\":\"model\"") != std::string::npos && done.find("room_key") != std::string::npos, "drain returns the line");

    std::string sayError;
    check(session->say(npcvoice::Call("nobody").player("Hi"), &sayError) == 0 && !sayError.empty(), "unknown character fails with an error");

    // A fallback is logged with its reason.
    auto down = npcvoice::Backend::stub(R"({"available":false})");
    auto downService = npcvoice::Service::create(down);
    auto request = session->project().request(npcvoice::Call("marta").player("Hello").json());
    auto fallback = downService.wait(downService.submit(*request), 2000);
    check(fallback && fallback->find("\"source\":\"fallback\"") != std::string::npos, "unavailable backend falls back");
    {
        std::lock_guard<std::mutex> lock(logMutex);
        bool warned = false;
        for (auto& l : logs) warned |= l.first == NPC_LOG_WARNING && l.second.find("fallback line for 'marta'") != std::string::npos;
        check(warned, "the fallback reaches the log handler");
    }

    // Streamed speech.
    std::mutex m;
    std::condition_variable cv;
    bool finished = false;
    int status = -1, chunks = 0;
    size_t samples = 0;
    bool ordered = true;
    double lastStart = -1;
    const uint64_t speechTicket = session->speech()->submit(
        "Evening, love. A room costs three silver marks a night.", "af_heart", 1.0,
        [&](uint64_t, const npcvoice::SpeechChunk& c) {
            std::lock_guard<std::mutex> lock(m);
            ordered &= c.index == static_cast<uint32_t>(chunks) && c.startTime > lastStart && c.sampleCount > 0 &&
                       c.infoJson.find("\"visemes\"") != std::string_view::npos;
            lastStart = c.startTime;
            ++chunks;
            samples += c.sampleCount;
        },
        [&](uint64_t, int s, std::string_view) {
            std::lock_guard<std::mutex> lock(m);
            status = s;
            finished = true;
            cv.notify_all();
        }, &error);
    check(speechTicket > 0, "speech submit returns a ticket");
    {
        std::unique_lock<std::mutex> lock(m);
        cv.wait_for(lock, std::chrono::seconds(60), [&] { return finished; });
    }
    check(finished && status == NPC_SPEECH_DONE, "speech finishes");
    check(chunks == 2 && ordered && samples > 24000, "two ordered sentence chunks with audio and visemes");

    std::string speechError;
    check(session->speech()->submit("Hi", "af_heart", 9.0, nullptr, nullptr, &speechError) == 0 && !speechError.empty(),
          "out-of-range speed is rejected without callbacks");

    auto whole = session->speech()->speak("Three marks a night.", "af_heart");
    check(whole && whole->samples.size() > 12000 && whole->infoJson.find("\"phonemes\"") != std::string::npos, "whole-line speak");

    // The one-file project form (npcvoice bundle), as engines load it from their packs.
    npcvoice::Session::Options fromJson;
    fromJson.projectJson = session->project().json();
    fromJson.backend = "stub";
    fromJson.backendConfigJson = options.backendConfigJson;
    fromJson.speech = false;
    auto bundled = npcvoice::Session::open(fromJson, &error);
    check(bundled && bundled->speech() == nullptr, "session opens from the bundled JSON without speech");
    if (bundled) {
        auto r = bundled->service().wait(bundled->say(npcvoice::Call("aiko").event("A bell rings.")), 2000);
        check(r && r->find("\"character\":\"aiko\"") != std::string::npos, "bundled project answers");
    }

    npcvoice::setLogHandler(nullptr);
    std::printf("%s\n", failures ? "C++ wrapper tests FAILED" : "C++ wrapper tests passed");
    return failures ? 1 : 0;
}
