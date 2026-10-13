// NPCVoice from plain C: load a project, generate a line with the bundled model, speak it
// whole, then stream it sentence by sentence (what a game does to start playback early).
// Build: swift build --product npc-c-sample
// Run:   .build/debug/npc-c-sample <project.npcproj> <out.f32> [--speech-only]
// Writes out.f32 (the whole line, mono float32), out.f32.json (its lip-sync info) and
// out.f32.chunk0.json (the first streamed chunk's info).
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "npc_core.h"
#include "npc_sdk.h"

static int fail(const char* what, char* err) { fprintf(stderr, "%s: %s\n", what, err ? err : "?"); npc_string_free(err); return 1; }

// Streamed speech: callbacks arrive on the SDK's worker thread. A game copies the samples
// into its audio system; here we count them and wait for on_done.
typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t done;
    int finished, status, chunks;
    uint64_t samples;
    const char* chunk0_path;
} stream_state;

static void write_text(const char* path, const char* text) {
    FILE* f = fopen(path, "w");
    if (f) { fputs(text, f); fclose(f); }
}

static void on_chunk(void* context, uint64_t ticket, const npc_speech_chunk* chunk) {
    stream_state* s = context;
    pthread_mutex_lock(&s->lock);
    s->chunks++; s->samples += chunk->sample_count;
    pthread_mutex_unlock(&s->lock);
    if (chunk->index == 0 && s->chunk0_path) write_text(s->chunk0_path, chunk->info_json);   // copy: valid only now
    printf("  chunk %u%s: %.2f s at t=%.2f s\n", chunk->index, chunk->is_last ? " (last)" : "",
           chunk->sample_count / chunk->sample_rate, chunk->start_time);
    (void)ticket;
}

static void on_done(void* context, uint64_t ticket, int32_t status, const char* error) {
    stream_state* s = context;
    if (error) fprintf(stderr, "  stream failed: %s\n", error);
    pthread_mutex_lock(&s->lock);
    s->finished = 1; s->status = status;
    pthread_cond_signal(&s->done);
    pthread_mutex_unlock(&s->lock);
    (void)ticket;
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <project.npcproj> <out.f32> [--speech-only]\n", argv[0]); return 64; }
    int speech_only = argc > 3 && strcmp(argv[3], "--speech-only") == 0;
    char* err = NULL;
    printf("NPCVoice SDK %s (core ABI %d)\n", npc_sdk_version(), npc_core_abi_version());

    npc_project* project = npc_project_load(argv[1], &err);
    if (!project) return fail("project", err);
    if (!speech_only) {
        npc_backend* backend = npc_backend_create_mlx(NULL, &err);
        if (!backend) return fail("backend", err);
        npc_service* service = npc_service_create(backend, NULL, &err);
        if (!service) return fail("service", err);
        char* request = npc_project_request(project,
            "{\"character\":\"marta\",\"playerUtterance\":\"Evening. Got a room for the night?\",\"budget\":{\"deadlineMs\":10000}}", &err);
        if (!request) return fail("request", err);
        uint64_t ticket = npc_service_submit(service, request, &err);
        char* result = npc_service_wait(service, ticket, 15000);
        if (!result) return fail("wait", NULL);
        printf("result: %s\n", result);
        npc_string_free(result); npc_string_free(request);
        npc_service_destroy(service); npc_backend_release(backend);
    }

    // The game would parse the result JSON; here we speak a fixed line to keep the sample short.
    const char* line = "Evening, love. A room at the Saltwren end costs three silver marks a night. Breakfast is extra.";
    npc_speech* speech = npc_speech_create(NULL, &err);
    if (!speech) return fail("speech", err);
    if (!npc_speech_set_project(speech, project, &err)) return fail("pronunciations", err);
    npc_audio* audio = npc_speech_speak(speech, line, "af_heart", 1.0, &err);
    if (!audio) return fail("speak", err);
    printf("audio: %llu samples at %.0f Hz\n", (unsigned long long)audio->sample_count, audio->sample_rate);
    FILE* f = fopen(argv[2], "wb");
    if (f) { fwrite(audio->pcm, sizeof(float), audio->sample_count, f); fclose(f); }
    printf("lip-sync: %.160s...\n", audio->info_json);
    char path[4096];
    snprintf(path, sizeof path, "%s.json", argv[2]);
    write_text(path, audio->info_json);

    char chunk0[4096];
    snprintf(chunk0, sizeof chunk0, "%s.chunk0.json", argv[2]);
    stream_state s = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0, 0, 0, chunk0 };
    printf("streaming:\n");
    if (!npc_speech_submit(speech, line, "af_heart", 1.0, on_chunk, on_done, &s, &err)) return fail("submit", err);
    pthread_mutex_lock(&s.lock);
    while (!s.finished) pthread_cond_wait(&s.done, &s.lock);
    pthread_mutex_unlock(&s.lock);
    printf("stream: status %d, %d chunks, %llu samples (whole line: %llu)\n", s.status, s.chunks,
           (unsigned long long)s.samples, (unsigned long long)audio->sample_count);

    npc_audio_free(audio); npc_speech_release(speech); npc_project_release(project);
    return s.status == NPC_SPEECH_DONE && s.chunks > 1 ? 0 : 1;
}
