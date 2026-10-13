NPCVoice 0.1.0: local AI dialogue and speech for game characters, on Apple-silicon Macs.

Write who your characters are, and they answer the player and react to game events in their own
words, with a voice and lip-sync. Everything runs on the player's Mac: no cloud, no per-line cost.

**Downloads**

| File | What it is |
|---|---|
| `NPCVoice-0.1.0.dmg` | The authoring app (models included) and the `npcvoice` command-line tool |
| `npcvoice-cli-0.1.0-macos-arm64.zip` | The CLI on its own; it uses the installed app's models, or a `Models` folder beside it |
| `NPCVoiceKit-0.1.0-sdk.zip` | The runtime SDK for C, C++ and Swift: `NPCVoiceKit.xcframework` + CMake package config |
| `NPCVoiceKit-0.1.0.xcframework.zip` | The same framework for SwiftPM (`binaryTarget`) |
| `NPCVoiceKit-0.1.0-unity-plugin.zip` | `NPCVoiceKit.bundle` for the Unity package |
| `qwen3.5-2b-4bit.tar`, `kokoro-82m-coreml.tar`, `misaki-en.tar`, `misaki-ja.tar` | Model weights, downloaded and verified by `tools/fetch_models.sh` |

Requires macOS 27 on Apple silicon.

The app and CLI are signed with a Developer ID but not notarized yet. On first open, macOS says it
can't verify the app: go to *System Settings → Privacy & Security* and click **Open Anyway**.

**What's in it**
- **Characters with rules:** persona, goals, relationships, mood and secrets, plus topics they
  won't discuss and words they must never say. Every line is checked before your game sees it.
- **Never stalls a frame:** asynchronous requests with deadlines. A late or off-persona line
  becomes one of the character's hand-written fallbacks, with the reason.
- **Models:** a bundled Qwen3.5-2B (MLX, grammar-constrained JSON), Apple Intelligence, or your
  own model.
- **Voices:** Kokoro-82M on Core ML (English and Japanese), streamed sentence by sentence, with 15
  lip-sync visemes.
- **Authoring app:** project editors and character portraits, a Playground with live game state,
  a Voice Lab, and Bake Lines for authored fallbacks and voiced assets.
- **Engines:** a C ABI, Swift, a header-only C++ wrapper, CMake, and plugins for Unreal Engine 5,
  Godot 4 and Unity. The three engine plugins are new and untested in their engines; please
  report issues.

Apache-2.0. Model licenses and voice credits are in `THIRD_PARTY_NOTICES.md`.
