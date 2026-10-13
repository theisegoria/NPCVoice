#ifndef NPC_SDK_H
#define NPC_SDK_H
// NPCVoice SDK: the parts of the C ABI implemented in Swift (model backends and
// speech). Use together with npc_core.h. Strings follow npc_core.h rules: returned
// char* are freed with npc_string_free; `char** error` may be NULL.
#include <stdint.h>
#include "npc_core.h"   // the neighbouring header, in the package and inside NPCVoiceKit.framework

#ifdef __cplusplus
extern "C" {
#endif

// Version of the SDK (static string, do not free).
const char* npc_sdk_version(void);

// ---------------------------------------------------------------- dialogue backends

// The bundled open-weight model (Qwen3.5-2B 4-bit, MLX, GPU). config_json may be NULL:
// {"modelDir": null (bundled copy), "cacheMB": 256, "warmUp": true}. cacheMB bounds MLX's
// buffer cache (process-wide); 256 keeps the model near 2.5 GB beside a game. With warmUp
// this blocks while the weights load and the GPU kernels compile (~1-3 s); without it, call
// npc_backend_prewarm before the first line is needed. Free memory with npc_backend_unload.
npc_backend* npc_backend_create_mlx(const char* config_json, char** error);
// Apple Intelligence's on-device model (FoundationModels). Fails if it is unavailable.
npc_backend* npc_backend_create_apple(char** error);

// ---------------------------------------------------------------- speech

typedef struct npc_speech npc_speech;

// models_dir may be NULL for the bundled models (kokoro-82m-coreml, misaki-en, misaki-ja).
npc_speech* npc_speech_create(const char* models_dir, char** error);
void npc_speech_release(npc_speech* speech);

typedef struct npc_audio {
    float* pcm;               // mono, loudness-normalised to -23 LUFS
    uint64_t sample_count;
    double sample_rate;       // 24000
    // {"phonemes","duration","sourceLUFS","gainDB","unknownWords":[...],
    //  "visemes":[{"viseme","start","end","weight"}], "phonemeTrack":[{"phoneme","start","end","stress","source"}]}
    char* info_json;
} npc_audio;

// voice: af_heart, af_bella, am_michael, am_fenrir (English), jf_alpha, jf_tebukuro, jm_kumo (Japanese).
// speed in [0.5, 2]. Thread-safe; calls are serialised internally.
npc_audio* npc_speech_speak(npc_speech* speech, const char* text, const char* voice, double speed, char** error);
void npc_audio_free(npc_audio* audio);

// Pronunciation overrides from a project (project.json "pronunciations"), used by later
// npc_speech_speak / npc_speech_submit calls. project may be NULL to clear them.
// Returns 1 on success.
int32_t npc_speech_set_project(npc_speech* speech, npc_project* project, char** error);

// ---------------------------------------------------------------- streamed speech
//
// npc_speech_submit synthesises on the speech object's worker thread, one sentence at a
// time, and returns at once. on_chunk is called for each piece in order, then on_done
// exactly once (also after a cancel or a failure). Both run on the worker thread: copy
// the samples into your audio system and return quickly. Requests run one at a time, in
// submission order. Loudness: the first chunk's gain applies to the whole line.

typedef struct npc_speech_chunk {
    const float* pcm;         // valid only during the callback
    uint64_t sample_count;
    double sample_rate;       // 24000
    double start_time;        // seconds from the start of the line
    uint32_t index;           // 0, 1, 2...
    int32_t is_last;          // non-zero on the final chunk
    // {"phonemes","gainDB","visemes":[...],"phonemeTrack":[...]}: times from the start of the
    // line. Valid only during the callback.
    const char* info_json;
} npc_speech_chunk;

enum { NPC_SPEECH_DONE = 0, NPC_SPEECH_CANCELLED = 1, NPC_SPEECH_FAILED = 2 };

typedef void (*npc_speech_chunk_fn)(void* context, uint64_t ticket, const npc_speech_chunk* chunk);
// error is NULL unless status is NPC_SPEECH_FAILED; valid only during the callback.
typedef void (*npc_speech_done_fn)(void* context, uint64_t ticket, int32_t status, const char* error);

// Returns a ticket (> 0), or 0 with *error set for invalid arguments (then no callback runs).
uint64_t npc_speech_submit(npc_speech* speech, const char* text, const char* voice, double speed,
                           npc_speech_chunk_fn on_chunk, npc_speech_done_fn on_done, void* context,
                           char** error);
// Stops a request before its next chunk (a chunk being synthesised still completes).
// Returns 1 if the ticket was pending or running. npc_speech_release does not cancel:
// requests already submitted still run and call back, so cancel them (and wait for
// on_done) before freeing their context.
int32_t npc_speech_cancel(npc_speech* speech, uint64_t ticket);

#ifdef __cplusplus
}
#endif
#endif
