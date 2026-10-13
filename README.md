# NPCVoice

Local AI dialogue and speech for game characters. You write who your characters are; they react
to the player and to game events in their own words, and they speak with a voice and a lip-sync
track. Everything runs on the player's Mac, with no cloud and no per-line cost.

- **Characters with rules.** Each character has a persona, goals, relationships, mood, and the
  facts it knows (with secrets unlocked by progress flags). It also has hard limits: topics it
  won't discuss, words it must never say, and the commands it may propose. Every generated line is
  checked against those rules before your game sees it.
- **Never stalls a frame.** Requests are asynchronous and have deadlines. A line that is late,
  off-persona or leaking a secret is replaced by one of the character's hand-written fallback
  lines, and the result says why.
- **A bundled model.** Qwen3.5-2B (4-bit, MLX) runs on the GPU with grammar-constrained JSON
  output. Apple Intelligence is an alternative backend, or bring your own model.
- **Voices.** Kokoro-82M on Core ML: 4 English and 3 Japanese voices, loudness-normalised, with
  15 lip-sync visemes. Lines are streamed sentence by sentence, so playback starts early.
- **An authoring app.** Edit projects; talk to characters in a Playground with live game state;
  audition voices; batch-write and review lines, then bake them into fallbacks or voiced assets.

Status: pre-release (0.1.0). macOS 27 on Apple silicon.

## Get started

**Download.** [`NPCVoice-0.1.0.dmg`](https://github.com/theisegoria/NPCVoice/releases/latest) has the
app (models included) and the `npcvoice` command-line tool. The build is signed with a
Developer ID but not yet notarized. The first time you open it, macOS says it can't verify the
app: go to *System Settings → Privacy & Security* and click **Open Anyway**.

**Build from source.** You need Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
about 3 GB of free disk.

```bash
git clone https://github.com/theisegoria/NPCVoice.git && cd NPCVoice
tools/fetch_models.sh        # pinned, checksummed weights (~2 GB) into third_party/models
xcodegen generate
open NPCVoice.xcodeproj      # run the NPCVoice scheme
```

Then try it from the command line:

```bash
swift run npcvoice init "Harbor Town.npcproj"
swift run npcvoice say "Harbor Town.npcproj" --npc marta --player "Evening. Got a room?" --backend mlx
swift run npcvoice speak --voice af_heart --text "Three marks a night, love." --out line.wav
```

## Use it in a game

The runtime is a C ABI, so any engine can call it. It ships as `NPCVoiceKit.xcframework`
(`tools/build_xcframework.sh`) with a Swift API on top.

```c
npc_project* project = npc_project_load("Harbor Town.npcproj", &err);
npc_backend* model   = npc_backend_create_mlx(NULL, &err);        // load time: ~1-3 s
npc_service* service = npc_service_create(model, NULL, &err);

char* request = npc_project_request(project,
    "{\"character\":\"marta\",\"playerUtterance\":\"Got a room?\"}", &err);
uint64_t ticket = npc_service_submit(service, request, &err);    // returns at once
// each frame: npc_service_drain(service) -> finished lines as JSON
```

```swift
let npcs = try await NPCVoiceRuntime(project: projectURL)
let line = try await npcs.respond(character: "marta", playerSays: "Got a room?")
for try await chunk in npcs.speakStream(line) { audio.schedule(chunk.samples, at: chunk.startTime) }
```

C and C++ projects can use CMake: `find_package(NPCVoiceKit CONFIG)` and link
`NPCVoiceKit::NPCVoiceKit`. There's a header-only C++ wrapper, plus plugins for **Unreal Engine 5**,
**Godot 4** and **Unity**. See [Integrations](Integrations/), and note which of them are untested.

- [C API guide](docs/C_API.md): threading, the frame loop, streamed speech, memory, logging
- [JSON reference](docs/JSON.md) and [schemas](docs/schema/): project files, game calls, results
- Samples: [plain C](Samples/c-sample), and [Swift](Samples/swift-sample), which links only the
  binary framework

## Repository

| Path | What's there |
|---|---|
| `Sources/NPCCore` | C++23 dialogue core: prompts, grounding, validation, fallbacks, the service, `.npcproj` projects, the C ABI |
| `Sources/NPCKit`, `NPCMLX`, `NPCTokenizer` | Swift API and backends: the MLX model, Apple Intelligence, a native Qwen tokenizer |
| `Sources/NPCSpeech` | Text to speech: English and Japanese G2P, Kokoro on Core ML, loudness, lip-sync |
| `Sources/NPCVoiceSDK`, `Framework/` | The binary SDK (C exports, `NPCVoiceRuntime`) |
| `App/` | The authoring app (SwiftUI) |
| `Integrations/` | C++ wrapper; Unreal, Godot and Unity plugins |
| `third_party/` | Pinned, vendored dependencies and their [provenance](third_party/PROVENANCE.md) |
| `tools/` | Model fetch and conversion, parity checks, SDK build, notices |

Tests: `swift build && swift run NPCCoreCppTests && swift test`. The MLX tests need the
`NPCVoiceTests` Xcode scheme, which bundles MLX's Metal library.

## License

Apache-2.0: free for commercial use. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Model
licenses and voice credits, including the CC BY credit for the Japanese voices `jf_tebukuro` and
`jm_kumo`, are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
