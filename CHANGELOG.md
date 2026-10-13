# Changelog

NPCVoice follows [Semantic Versioning](https://semver.org). Three contracts are versioned
separately from the release number:

- **C ABI:** `NPC_CORE_ABI_VERSION`, returned by `npc_core_abi_version()`. It goes up on any
  breaking change to `npc_core.h` or `npc_sdk.h`. Callback structs grow through their
  `struct_size` field without a bump.
- **Project format:** `"version"` in `project.json`. It goes up when a `.npcproj` written by a
  newer build can't be read by an older one.
- **JSON payloads:** `docs/schema/`. Additive changes (new optional fields) are minor; removed or
  renamed fields are major.

The version string appears in `Sources/NPCVoiceSDK/Exports.swift` (`npc_sdk_version`),
`project.yml` (`MARKETING_VERSION`, twice) and `cmake/NPCVoiceKitConfigVersion.cmake`. Keep them
equal.

## [0.1.0] — unreleased

First release: open source under Apache-2.0, for Apple-silicon Macs.

### Runtime (C ABI, NPCVoiceKit.xcframework, Swift `NPCVoiceRuntime`)
- **Dialogue service:** asynchronous, with tickets, per-request deadlines, cancellation, a queue,
  an LRU cache of validated lines, and stats.
- **Safety net:** every line is checked before it is returned: persona, forbidden terms, withheld
  secrets, fourth wall, script, length and commands. A failing line is replaced by a hand-written
  fallback, and the reason is reported.
- **Backends:**
  - Bundled Qwen3.5-2B (4-bit, MLX) with grammar-constrained JSON, warm-up, prewarm, unload and a
    cache budget.
  - Apple Intelligence (FoundationModels).
  - Custom backends through `npc_backend_callbacks`, plus a deterministic stub.
- **Speech:** Kokoro-82M on Core ML, in English and Japanese, with native G2P, −23 LUFS
  loudness, 15-viseme lip-sync and per-project pronunciations. Lines come whole or streamed by
  sentence (`npc_speech_submit`, Swift `speakStream`).
- **Logging:** `npc_set_log_callback` and Swift `setLogHandler`.
- **Docs:** JSON Schemas for every payload, plus [C_API.md](docs/C_API.md) and
  [JSON.md](docs/JSON.md).

### Engine integrations
- **C++:** a header-only wrapper (RAII, no exceptions, C++17), tested against the library.
- **Engine plugins:** Unreal Engine 5 (subsystem + speech component), Godot 4 (GDExtension node)
  and Unity (UPM package, plus a native plugin bundle). These three are untested in their engines.
- **CMake package config;** `npcvoice bundle`, which writes a one-file project for packed game
  resources.

### Authoring app (NPCVoice.app)
- **Editors:** document-based `.npcproj` editing for world, characters (with portraits), facts,
  commands and pronunciations, with live project checks.
- **Playground:** talk to characters with any backend, change game state, hear replies.
- **Voice Lab:** audition voices, inspect the waveform and lip-sync, export WAV + JSON.
- **Bake Lines:** batch-write lines, review them, and add them as fallbacks or export voiced assets.
- **Polish:** onboarding, Settings, keyboard shortcuts, VoiceOver labels, light and dark mode.

### CLI (`npcvoice`)
- `init`, `validate`, `characters`, `bundle`, `prompt`, `say`, `speak`, `bench`.
