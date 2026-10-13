# NPCVoice C API

NPCVoice's runtime is a C ABI, so any engine or language that can call C can use it.
There are two headers:

| Header | What it covers |
|---|---|
| `npc_core.h` | The dialogue core: projects, the dialogue service, custom backends, logging |
| `npc_sdk.h` | The bundled models: Qwen via MLX, Apple Intelligence, and speech (Kokoro on Core ML) |

Ship `NPCVoiceKit.xcframework` and include `<NPCVoiceKit/NPCVoiceKit.h>`. Swift code can use
`NPCVoiceRuntime` instead (see the framework's Swift interface). Every payload is UTF-8 JSON; the
shapes are in [JSON.md](JSON.md) and [schema/](schema/).

Platforms: macOS on Apple silicon.

## Model files

The SDK binary doesn't contain the weights (about 2 GB). Ship them with your game in a `Models`
folder holding `qwen3.5-2b-4bit/`, `kokoro-82m-coreml/`, `misaki-en/` and `misaki-ja/`. During
development, `tools/fetch_models.sh` downloads them. Passing NULL for a models folder (or
omitting `modelDir`) searches, in order:

1. `$NPCVOICE_MODELS`;
2. `<your app>.app/Contents/Resources/Models`;
3. a `Models` folder next to the executable;
4. `/Applications/NPCVoice.app/Contents/Resources/Models`, the installed NPCVoice app.

Pass an explicit folder to load from anywhere else.

## Conventions

- **Strings.** Every `char*` the library returns is heap-allocated by the library. Free it with
  `npc_string_free`. `const char*` returns (`npc_sdk_version`) are static.
- **Errors.** Functions that can fail take `char** error`, which may be NULL. On failure they
  return NULL or 0 and store a message, which the caller frees with `npc_string_free`.
- **Handles.** Handles are opaque (`npc_project`, `npc_backend`, `npc_service`, `npc_speech`).
  Release each one with its matching `*_release` or `*_destroy` call. A service keeps its backend
  alive.
- **Threads.** Everything is safe to call from any thread. Callbacks (custom backends, streamed
  speech, logging) run on SDK threads: hand the data to your own systems and return quickly.
- **Strict JSON.** Unknown fields and wrong types are errors, and the error names the path
  (e.g. `call.exchanges[0].speaker`). A typo fails loudly instead of being ignored.
- **ABI version.** `npc_core_abi_version()` returns `NPC_CORE_ABI_VERSION`. Check it once at
  startup. Callback structs carry a `struct_size` field, so they can grow without breaking older
  callers.

## Keep the game thread free

Model work never belongs on the game thread. Four calls block, so run them at load time or on a
worker thread:

- `npc_backend_create_mlx` with `warmUp`: loads the weights and compiles the GPU kernels, about 1–3 s.
- `npc_service_wait`.
- `npc_speech_create`.
- `npc_speech_speak`.

The per-frame pattern:

```c
// When an NPC should talk:
char* request = npc_project_request(project, call_json, &err);   // fast, no model work
uint64_t ticket = npc_service_submit(service, request, &err);   // returns at once
npc_string_free(request);

// Every frame (non-blocking):
char* done = npc_service_drain(service);   // JSON array of finished results, in ticket order
// ...parse; for each line, show the text, run its validated commands, and stream its speech...
npc_string_free(done);
```

Each request carries a **deadline** (default 2.5 s, `budget.deadlineMs`). A line that is late,
off-persona, leaking a secret, or breaking the fourth wall is replaced by one of the character's
hand-written fallback lines. The result always arrives, and `source` / `fallbackReason` say why.

## Speech

```c
npc_speech* speech = npc_speech_create(NULL, &err);       // bundled models; load-time call
npc_speech_set_project(speech, project, &err);            // the project's pronunciations

// Streamed: playback can start after the first sentence.
uint64_t t = npc_speech_submit(speech, text, voice, 1.0, on_chunk, on_done, my_context, &err);
```

`on_chunk` receives mono float32 PCM at 24 kHz, the chunk's start time within the line, and
lip-sync JSON (visemes and phonemes on the line's timeline). Copy the samples into your audio
system: the pointers are valid only during the callback. `on_done` then runs exactly once, with
`NPC_SPEECH_DONE`, `NPC_SPEECH_CANCELLED` or `NPC_SPEECH_FAILED`. Requests run one at a time, in
submission order. `npc_speech_cancel` stops a request before its next chunk.

`npc_speech_speak` returns a whole line at once (for baking assets). Free it with `npc_audio_free`.

The engine owns playback. NPCVoice never opens an audio device.

## Memory and the GPU

The bundled dialogue model needs about 2.5 GB of unified memory while loaded.

- `{"cacheMB": 256}` in `npc_backend_create_mlx` bounds MLX's buffer cache. This is process-wide.
- `npc_backend_unload` frees the model, e.g. for a cutscene or a heavy scene. The next request
  reloads it, which is slow enough to miss a deadline.
- `npc_backend_prewarm` reloads it in the background ahead of time.
- Speech (Kokoro, about 315 MB on disk) runs on Core ML.

## Logging

```c
static void log_line(void* ctx, int32_t level, const char* message) { /* your logger */ }
npc_set_log_callback(log_line, NULL, NPC_LOG_INFO);
```

The SDK logs fallbacks with the character and the reason (warnings), model and speech load times
(info), and per-request timings (debug). It is silent until a callback is installed. Messages
arrive one at a time.

## Custom backends

To bring your own model, fill an `npc_backend_callbacks` struct, set its `struct_size`, and pass it to
`npc_backend_create`.

- `generate` receives a [backend request](schema/backend-request.schema.json) and must call
  `done` exactly once, from any thread, with a [response](schema/backend-response.schema.json).
- The core still assembles the prompt, validates the output and falls back, so a backend only
  turns a prompt into schema-shaped JSON.
- `npc_backend_create_stub` is a deterministic backend for tests.

## Reference

| Function | Notes |
|---|---|
| `npc_core_abi_version`, `npc_sdk_version` | Versions |
| `npc_string_free` | Frees any returned `char*` |
| `npc_set_log_callback`, `npc_log_message` | Logging |
| `npc_project_load`, `npc_project_load_json`, `npc_project_release` | `.npcproj` folders, or their combined JSON |
| `npc_project_json`, `npc_project_diagnostics` | Whole project as JSON; static checks |
| `npc_project_request` | [Game call](schema/call.schema.json) → dialogue request |
| `npc_project_write_sample` | Writes the "Harbor Town" example project |
| `npc_backend_create_mlx`, `npc_backend_create_apple`, `npc_backend_create_stub`, `npc_backend_create` | Backends |
| `npc_backend_info`, `npc_backend_prewarm`, `npc_backend_unload`, `npc_backend_release` | Backend control |
| `npc_service_create`, `npc_service_destroy` | [Service config](schema/service-config.schema.json) |
| `npc_service_submit`, `npc_service_cancel` | Async requests by ticket |
| `npc_service_drain`, `npc_service_wait` | [Results](schema/result.schema.json) |
| `npc_service_stats`, `npc_service_clear_cache` | Counters; the cache of validated lines |
| `npc_speech_create`, `npc_speech_release`, `npc_speech_set_project` | Speech models and pronunciations |
| `npc_speech_submit`, `npc_speech_cancel` | Streamed speech |
| `npc_speech_speak`, `npc_audio_free` | Whole-line speech |
| `npc_prepare_prompt`, `npc_validate_response`, `npc_canonical_request` | Inspecting prompts and validation (tools, debugging) |

Working examples: `Samples/c-sample` (plain C) and `Samples/swift-sample` (Swift, linking only the
binary framework).
