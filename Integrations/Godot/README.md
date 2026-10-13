# NPCVoice for Godot 4

A GDExtension that adds an `NPCVoice` node. Characters answer the player and game events, and
speech streams sentence by sentence, with lip-sync visemes. macOS on Apple silicon, Godot 4.3+.

> **Status: untested.** This was written without a Godot build at hand. The C++ layer it is built
> on (`Integrations/cpp`) is tested against the library, but this node is not. If something
> doesn't compile or behave, please open an issue.

## Build

```bash
cd Integrations/Godot
git clone -b 4.4 https://github.com/godotengine/godot-cpp     # match your Godot version
scons platform=macos arch=arm64 target=template_debug npcvoicekit=/path/to/NPCVoiceKit.xcframework
scons platform=macos arch=arm64 target=template_release npcvoicekit=/path/to/NPCVoiceKit.xcframework
cp -R /path/to/NPCVoiceKit.xcframework/macos-arm64/NPCVoiceKit.framework addons/npcvoice/bin/
```

Copy `addons/npcvoice` into your project.

## Use

1. Add an **NPCVoice** node and set its properties:
   - `project_path`: either a `.npcproj` folder (it must be a real folder, outside the exported
     `.pck`), or the one-file form from `npcvoice bundle Game.npcproj npc.json`, which works
     anywhere, including inside the `.pck`.
   - `backend`: `mlx` (the bundled model), `apple` (Apple Intelligence) or `stub` (testing).
   - `models_dir`: the folder with the model weights (see below).
2. Wait for `opened(error)`. By default the node opens itself on `_ready`, on a background
   thread.
3. Call `say("marta", "Got a room?", {"flags": [...], "location": "...", "deadline_ms": 2500})`
   or `react("marta", "The player draws a knife.")`. The line arrives in
   `line_ready(result)`; see `docs/JSON.md` for the result's fields.
4. Call `speak(text, voice)`. Audio arrives in `speech_chunk(ticket, samples, start_time, index,
   last, info)` as 24 kHz mono floats, and `info.visemes` drives lip-sync. `speech_finished` follows.
   `demo/npc_demo.gd` plays chunks through an `AudioStreamGenerator`.

| Signal | When |
|---|---|
| `opened(error)` | The session is ready (`error` is empty) or failed |
| `line_ready(result)` | A line finished (model, cache or fallback) |
| `failed(error)` | A call couldn't be submitted |
| `speech_chunk(...)`, `speech_finished(ticket, status, error)` | Streamed speech |

Also available: `cancel(ticket)`, `cancel_speech(ticket)`, `unload_model()` (frees about 2.5 GB,
e.g. during a cutscene) and `prewarm_model()`.

## Model weights

The weights (about 2 GB) aren't in the extension. Put a `Models` folder (`qwen3.5-2b-4bit`,
`kokoro-82m-coreml`, `misaki-en`, `misaki-ja`, from the NPCVoice release or
`tools/fetch_models.sh`) next to your game and point `models_dir` at it. Left empty, it falls
back to `$NPCVOICE_MODELS`, then to the app's `Contents/Resources/Models`.
