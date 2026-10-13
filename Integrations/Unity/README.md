# NPCVoice for Unity

A UPM package (`com.npcvoice.runtime`) for Unity 2022.3+ on Apple-silicon Macs, with three parts:

| Component | What it does |
|---|---|
| `NPCVoiceManager` | Opens NPCVoice on a background thread, submits game calls, and raises `onLine` with each finished line |
| `NPCVoiceSpeaker` | Streams a character's speech through its AudioSource and reports the current lip-sync viseme |
| `NPCVoiceClient` | The same features without MonoBehaviours |

> **Status: untested.** This was written without Unity at hand, and the C# hasn't been compiled.
> The native plugin bundle and the C ABI underneath are tested; the C# bindings are not. If
> something doesn't compile or behave, please open an issue.

## Install

1. Build the plugin bundle (or take it from the release):
   `tools/package_unity_plugin.sh /path/to/NPCVoiceKit.xcframework`
   This writes `Plugins/macOS/NPCVoiceKit.bundle` into the package.
2. In Unity: *Package Manager → + → Add package from disk…*, then pick
   `Integrations/Unity/com.npcvoice.runtime/package.json`.
3. Select `NPCVoiceKit.bundle` and check that its plugin settings are **macOS, Apple silicon**,
   with the Editor included.

## Use

1. Put your project in `Assets/StreamingAssets/NPCVoice/`, either as the `.npcproj` folder or as
   the one-file JSON from `npcvoice bundle`. Put the model weights in
   `Assets/StreamingAssets/NPCVoice/Models`: `qwen3.5-2b-4bit`, `kokoro-82m-coreml`,
   `misaki-en` and `misaki-ja`, from the release or `tools/fetch_models.sh`.
2. Add an **NPCVoice Manager** to the scene. On the character, add an AudioSource and an
   **NPCVoice Speaker**.
3. After `onOpened` (an empty string means success), call
   `manager.Say("marta", "Got a room?", state)` or `manager.React("marta", "The player draws a knife.")`.
4. In `onLine`, show `result.line.text`, run the validated `result.line.commands`, and call
   `speaker.SpeakLine(result)`. While speaking, `speaker.CurrentViseme(out weight)` drives blend
   shapes.

The **Talk** sample (in Package Manager → Samples) puts these steps together.

`manager.UnloadModel()` frees about 2.5 GB, e.g. during a cutscene, and `PrewarmModel()` reloads
it. `NPCVoiceClient.SetLogHandler` forwards NPCVoice's diagnostics, including why a fallback line
was used.
