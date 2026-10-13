#ifndef NPC_CORE_H
#define NPC_CORE_H
// NPCVoice dialogue core: stable C ABI (docs/C_API.md).
//
// All payloads are UTF-8 JSON in the shapes documented in docs/JSON.md. Every
// returned char* is heap-allocated by the library and must be freed with
// npc_string_free. Functions that can fail take `char** error` (may be NULL);
// on failure they return NULL/0 and store a message the caller frees.
//
// Threading: a service may be used from any thread. Native backend callbacks
// may be invoked from the service's worker thread.
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NPC_CORE_ABI_VERSION 1

typedef struct npc_backend npc_backend;
typedef struct npc_service npc_service;
typedef struct npc_project npc_project;

int32_t npc_core_abi_version(void);
void npc_string_free(char* s);

// ---------------------------------------------------------------- logging

enum { NPC_LOG_DEBUG = 0, NPC_LOG_INFO = 1, NPC_LOG_WARNING = 2, NPC_LOG_ERROR = 3 };
// Called from any thread (often a worker): forward to your logger and return quickly.
// message is valid only during the call.
typedef void (*npc_log_fn)(void* context, int32_t level, const char* message);
// Routes the SDK's diagnostics (model loads, fallbacks and why, timings) to the game.
// Nothing is logged until this is called; pass fn = NULL to silence again.
void npc_set_log_callback(npc_log_fn fn, void* context, int32_t min_level);
// Sends a message through the same sink (used by the SDK's own layers and custom backends).
void npc_log_message(int32_t level, const char* message);

// ---------------------------------------------------------------- backends

// Availability codes (match docs/JSON.md "availability").
enum {
    NPC_AVAILABLE = 0, NPC_DEVICE_NOT_ELIGIBLE = 1, NPC_NOT_ENABLED = 2,
    NPC_MODEL_NOT_READY = 3, NPC_UNSUPPORTED = 4
};

// Completion for a native generate call: response_json is
// {"status":"ok|cancelled|unavailable|refusal|guardrail|context_exceeded|unsupported_language|rate_limited|decoding_failure|error",
//  "json":"<model output>","promptTokens":n,"outputTokens":n,"diagnostic":"..."}.
// Must be called exactly once per generate, from any thread.
typedef void (*npc_backend_done_fn)(void* done_context, const char* response_json);

typedef struct npc_backend_callbacks {
    uint32_t struct_size;             // sizeof(npc_backend_callbacks): lets the struct grow compatibly
    void* context;
    const char* name;                 // copied at creation
    uint32_t context_tokens;
    int32_t guided_generation;        // non-zero if output is constrained to the schema
    int32_t (*availability)(void* context);
    int32_t (*supports_language)(void* context, const char* bcp47);
    // request_json: {"instructions","prompt","schema":{...},"language","maxOutputTokens","sampling":{...}}.
    // job_id identifies the request for cancel. Must not block.
    void (*generate)(void* context, const char* request_json, uint64_t job_id,
                     npc_backend_done_fn done, void* done_context);
    void (*cancel)(void* context, uint64_t job_id);            // may be NULL
    void (*prewarm)(void* context, const char* instructions);   // may be NULL
    void (*destroy)(void* context);                            // may be NULL; called once on last release
    void (*unload)(void* context);                             // may be NULL; free model memory until next use
} npc_backend_callbacks;

npc_backend* npc_backend_create(const npc_backend_callbacks* callbacks);
// Deterministic test backend. config_json may be NULL or
// {"delayMs":0,"available":true,"languages":["en","ja"],"fixedResponse":"<json>"}.
npc_backend* npc_backend_create_stub(const char* config_json, char** error);
void npc_backend_release(npc_backend* backend);
// Starts loading the model in the background so the first line is fast (e.g. on a level load).
void npc_backend_prewarm(npc_backend* backend);
// Frees the model's memory (GPU/unified) until the next request reloads it, e.g. while a
// cutscene or a heavy scene runs. Requests in flight finish first.
void npc_backend_unload(npc_backend* backend);
// {"name","contextTokens","guidedGeneration","availability"}
char* npc_backend_info(npc_backend* backend);

// ---------------------------------------------------------------- service

// config_json may be NULL: {"queueCapacity":16,"cacheCapacity":256,"cancelGraceMs":300,"guardrails":{...}}.
npc_service* npc_service_create(npc_backend* backend, const char* config_json, char** error);
void npc_service_destroy(npc_service* service);
// Returns a ticket (>0). A request that is valid JSON but inadmissible still gets a
// ticket and completes with a fallback line; unparsable JSON returns 0 + error.
uint64_t npc_service_submit(npc_service* service, const char* request_json, char** error);
int32_t npc_service_cancel(npc_service* service, uint64_t ticket);
// Result JSON, or NULL if the ticket did not complete within timeout_ms.
char* npc_service_wait(npc_service* service, uint64_t ticket, uint32_t timeout_ms);
// JSON array of completed results, in ticket order (non-blocking).
char* npc_service_drain(npc_service* service);
char* npc_service_stats(npc_service* service);
void npc_service_clear_cache(npc_service* service);

// ---------------------------------------------------------------- pure stages (tools, debugging)

// Prompt inspection: {"instructions","prompt","schema","usedFactIds","withheldKeywords","cacheKey",...}
char* npc_prepare_prompt(const char* request_json, char** error);
// Validates a raw model response against a request: {"ok","reason","diagnostic","line"}
char* npc_validate_response(const char* request_json, const char* model_json, char** error);
// Encodes a request with every default filled in (round-trip canonical form).
char* npc_canonical_request(const char* request_json, char** error);

// ---------------------------------------------------------------- projects (.npcproj)

npc_project* npc_project_load(const char* path, char** error);
// Loads the combined JSON form returned by npc_project_json (e.g. unsaved edits).
npc_project* npc_project_load_json(const char* project_json, char** error);
void npc_project_release(npc_project* project);
// The whole project as one JSON document (world, characters, facts, commands).
char* npc_project_json(npc_project* project);
// Problems found by static checks: JSON array of {"severity":"error|warning","path","message"}.
char* npc_project_diagnostics(npc_project* project);
// Builds a dialogue request for one character from a game call:
// {"character":"innkeeper","playerUtterance"|"trigger", "flags":[], "location", "objective",
//  "perception":[...], "exchanges":[...], "memories":[...], "topics":[...], "mood",
//  "sampling":{...}, "budget":{...}, "priority", "allowCache"}
char* npc_project_request(npc_project* project, const char* call_json, char** error);
// Writes a new example project ("Harbor Town") to path, which must not exist.
int32_t npc_project_write_sample(const char* path, char** error);

#ifdef __cplusplus
}
#endif
#endif
