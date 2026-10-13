#pragma once
// NPCVoice dialogue core (docs/C_API.md, docs/JSON.md). A local language model turns a
// world profile, a character profile and grounded, game-filtered context into
// one structured spoken line: text, an emotion, an intent and optional gameplay
// commands that the game validates and executes itself. The core owns the
// service (grounding filter, prompt assembly, schema, validation, guardrails,
// deterministic fallback, cache, worker thread, budgets, cancellation); the game
// owns the rules (who knows what, which commands exist, fallback line pools).
//
// Backends are pluggable: an MLX open-weight model (default), Apple
// FoundationModels on macOS 27, and a deterministic stub for tests. Native
// backends plug in through the C ABI in npc_core.h. This header is portable C++
// with no Apple frameworks.
//
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace npc::dialogue {

// ---------------------------------------------------------------- vocabulary

enum class Language : std::uint8_t {English, Japanese};
std::string_view languageTag(Language);          // BCP-47: "en", "ja"
std::optional<Language> parseLanguageTag(std::string_view);

// Stable token order (part of the JSON contract).
enum class Emotion : std::uint8_t {Neutral,Happy,Sad,Angry,Fear,Surprise,Disgust,Contempt,Pain,Exertion,Concentration,Fatigue,Count};
inline constexpr std::size_t EmotionCount=static_cast<std::size_t>(Emotion::Count);
std::string_view emotionToken(Emotion);           // schema token, e.g. "fear"
std::optional<Emotion> parseEmotionToken(std::string_view);

// What the line does conversationally. Engine vocabulary; the game maps it.
enum class Intent : std::uint8_t {Inform,Warn,Request,Refuse,Greet,Farewell,Deflect,Plead,Threaten,Count};
inline constexpr std::size_t IntentCount=static_cast<std::size_t>(Intent::Count);
std::string_view intentToken(Intent);
std::optional<Intent> parseIntentToken(std::string_view);

// ---------------------------------------------------------------- inputs

// The game's world, shared by every character in a project.
struct WorldProfile {
    std::string name;                       // e.g. "Harbor Town"; empty = "the story"
    std::string setting;                    // where and when, in one or two sentences
    std::string tone;                       // e.g. "wry, low fantasy"
    std::string contentRating;              // e.g. "Teen: no profanity, no graphic violence"
    std::vector<std::string> rules;         // rules every character follows
};

struct Relationship {
    std::string targetId;                   // a character id, or "player"
    std::string description;                // how this character sees them
};

struct CharacterProfile {
    std::string id;                    // stable game id, part of the cache key
    std::string displayName;
    std::string role;                  // e.g. "innkeeper"; optional
    std::string persona;               // who they are, in one or two sentences
    std::vector<std::string> traits;   // personality, e.g. "gruff", "loyal"
    std::vector<std::string> goals;    // what they want right now
    std::string mood;                  // current mood, set by the game; optional
    std::vector<Relationship> relationships;
    std::string speechStyle;           // register, verbal tics, politeness level
    std::string voiceId;               // TTS voice, passed through untouched
    Language language{Language::English};
    std::vector<Emotion> allowedEmotions;   // empty = all
    std::vector<Intent> allowedIntents;     // empty = all
    std::uint32_t maxLineCodePoints{0};     // 0 = language default (EN 220, JA 90)
    std::vector<std::string> forbiddenTopics; // the model is told to deflect these
    std::vector<std::string> forbiddenTerms; // never spoken (case-insensitive); enforced by the validator
};

// One piece of world knowledge. The game authors facts; the engine filters them.
struct Fact {
    std::string id;
    std::string text;                           // in the character's language
    std::vector<std::string> knownBy;           // character ids; empty = common knowledge
    std::vector<std::string> requiredFlags;     // progress flags; all must be set or the fact is gated (spoiler)
    std::vector<std::string> tags;              // topic tags for relevance ranking
    std::vector<std::string> leakKeywords;      // distinctive words that reveal the fact if it is withheld
    float salience{0.5f};                       // [0,1] authored importance
};

struct Observation {std::string text; float salience{0.5f};}; // current perception from the completed snapshot
enum class Speaker : std::uint8_t {Player,Character,Other};
struct Exchange {Speaker speaker{Speaker::Player}; std::string text;};

struct GroundingContext {
    std::vector<Fact> facts;
    std::vector<std::string> progressFlags;     // set flags from the completed game state
    std::string location;
    std::string objective;                      // current quest/objective summary, already gated by the game
    std::vector<Observation> perception;
    std::vector<Exchange> recentExchanges;      // oldest first
    std::vector<std::string> memories;          // game-owned long-term notes about the player, most important first
    std::vector<std::string> topicTags;         // what the player is asking about, for ranking
};

// A gameplay command the game allows the model to propose for this request.
struct CommandSpec {
    std::string kind;                           // e.g. "unlock_door"
    std::string description;                    // shown to the model
    std::vector<std::string> allowedTargets;    // empty = command takes no target
};
struct Command {std::string kind; std::string target;};

// Deterministic lines the game supplies for when the model cannot be used.
struct FallbackLine {
    std::string text;
    Intent intent{Intent::Deflect};
    Emotion emotion{Emotion::Neutral};
};

struct Budget {
    std::chrono::milliseconds deadline{2500};  // submit -> result, including queueing
    std::uint32_t maxOutputTokens{160};
    std::uint32_t maxPromptTokens{3000};       // estimated; facts are dropped to fit
    std::uint32_t maxFacts{12};
    std::uint32_t maxPerception{6};
    std::uint32_t maxExchanges{6};
    std::uint32_t maxMemories{6};
};

struct Sampling {
    bool greedy{true};                          // greedy lines are cacheable and reproducible
    double temperature{0.7};
    std::uint64_t seed{0};
};

struct DialogueRequest {
    WorldProfile world;
    CharacterProfile character;
    GroundingContext context;
    std::string playerUtterance;                // empty when triggered by an event
    std::string trigger;                        // event description when no utterance
    std::vector<CommandSpec> commands;
    std::uint32_t maxCommands{2};
    std::vector<FallbackLine> fallbacks;
    Budget budget{};
    Sampling sampling{};
    bool allowCache{true};
    std::uint32_t priority{0};                  // higher first
};

// ---------------------------------------------------------------- outputs

enum class LineSource : std::uint8_t {Model,Cache,Fallback};
enum class FallbackReason : std::uint8_t {
    None, BackendUnavailable, UnsupportedLanguage, Timeout, QueueFull, InvalidRequest,
    SchemaInvalid, GuardrailRejected, Refusal, ModelGuardrail, ContextExceeded, RateLimited, BackendError};
std::string_view fallbackReasonName(FallbackReason);

struct DialogueLine {
    std::string text;
    Emotion emotion{Emotion::Neutral};
    Intent intent{Intent::Inform};
    std::vector<Command> commands;              // validated against the request's CommandSpecs
    Language language{Language::English};
    std::string voiceId;
    std::string characterId;
};

// The hand-off to text-to-speech (NPCSpeech). TTS then yields audio plus a
// phoneme/viseme timeline.
struct SpeechHandoff {
    std::string text;
    std::string languageTag;                    // "en" / "ja"
    std::string voiceId;
    std::string emotionToken;                   // style hint for expressive voices
    std::string characterId;
};
SpeechHandoff speechHandoff(const DialogueLine&);

using Ticket=std::uint64_t;
enum class ResultStatus : std::uint8_t {Line,Cancelled};
struct DialogueResult {
    Ticket ticket{};
    ResultStatus status{ResultStatus::Line};
    LineSource source{LineSource::Fallback};
    FallbackReason fallbackReason{FallbackReason::None};
    DialogueLine line;
    std::string diagnostic;                     // why validation/backend failed (never shown to players)
    std::uint32_t promptTokens{0}, outputTokens{0};
    std::chrono::microseconds latency{0};
    std::vector<std::string> usedFactIds;
};

// ---------------------------------------------------------------- cancellation

class CancellationSource;
class CancellationToken {
public:
    CancellationToken()=default;
    bool cancelled() const;
    // Runs immediately if already cancelled; otherwise once, on cancel().
    void onCancel(std::function<void()>) const;
private:
    friend class CancellationSource;
    struct State;
    std::shared_ptr<State> state_;
};
class CancellationSource {
public:
    CancellationSource();
    CancellationToken token() const;
    void cancel();
    bool cancelled() const;
private:
    std::shared_ptr<CancellationToken::State> state_;
};

// ---------------------------------------------------------------- backend interface

// Schema the backend constrains output to. Every backend must produce JSON:
// {"text": string, "emotion": <emotion token>, "intent": <intent token>,
//  "commands": [{"kind": <kind>, "target": <target or "">}]}   (commands optional)
struct OutputSchema {
    std::vector<Emotion> emotions;
    std::vector<Intent> intents;
    std::vector<CommandSpec> commands;
    std::uint32_t maxCommands{0};
    std::uint32_t maxCodePoints{220};
};
std::string schemaJson(const OutputSchema&);   // the bridge format to native backends

struct BackendRequest {
    std::string instructions;
    std::string prompt;
    OutputSchema schema;
    Language language{Language::English};
    std::uint32_t maxOutputTokens{160};
    Sampling sampling{};
};

enum class BackendStatus : std::uint8_t {
    Ok, Cancelled, Unavailable, Refusal, Guardrail, ContextExceeded, UnsupportedLanguage, RateLimited, DecodingFailure, Error};
std::string_view backendStatusName(BackendStatus);
struct BackendResponse {
    BackendStatus status{BackendStatus::Error};
    std::string json;
    std::uint32_t promptTokens{0}, outputTokens{0};
    std::string diagnostic;
};

enum class Availability : std::uint8_t {Available, DeviceNotEligible, NotEnabled, ModelNotReady, Unsupported};
std::string_view availabilityName(Availability);

struct BackendInfo {
    std::string name;
    std::uint32_t contextTokens{0};
    bool guidedGeneration{false};
};

class DialogueBackend {
public:
    virtual ~DialogueBackend()=default;
    virtual BackendInfo info() const=0;
    virtual Availability availability() const=0;
    virtual bool supportsLanguage(Language) const=0;
    // Asynchronous: `done` is called exactly once, from any thread, possibly
    // after cancellation (then with Cancelled). Must not block the caller.
    virtual void generate(BackendRequest, CancellationToken, std::function<void(BackendResponse)> done)=0;
    // Optional: warm caches for a character's instructions.
    virtual void prewarm(std::string_view /*instructions*/) {}
    virtual void unload() {}
};

// ---------------------------------------------------------------- pure stages (testable)

// Grounding: facts the character knows and the player's progress unlocks, ranked
// (salience + topic overlap, ties by id) and capped. Withheld facts contribute
// their leak keywords to the guard list.
struct GroundedContext {
    std::vector<const Fact*> facts;
    std::vector<std::string> withheldKeywords;
    std::vector<std::string> usedFactIds;
};
GroundedContext groundFacts(const DialogueRequest&);

// Conservative token estimate (EN ~4 bytes/token, CJK 1 code point/token).
std::uint32_t estimateTokens(std::string_view utf8);
std::size_t codePointCount(std::string_view utf8);

struct PreparedPrompt {
    BackendRequest backend;
    GroundedContext grounding;
    std::uint64_t cacheKey{0};
};
// Throws std::invalid_argument for an inadmissible request (empty ids, voice, no utterance and no trigger...).
PreparedPrompt preparePrompt(const DialogueRequest&);

struct GuardrailPolicy {
    // Fourth-wall breaks. Kept narrow: a setting may have in-world AIs, so "AI" alone is legal.
    std::vector<std::string> metaPhrases{"as an ai","language model","i'm an ai","i am an ai","ai assistant","openai","chatgpt","apple intelligence","my instructions","video game",
        "言語モデル","AIアシスタント","私はAI","プロンプト","ゲームの中"};
    double minJapaneseScriptFraction{0.3};       // kana/kanji share of letters for JA
};

struct Validation {
    bool ok{false};
    FallbackReason reason{FallbackReason::None};
    std::string diagnostic;
    DialogueLine line;
};
Validation validateResponse(std::string_view json,const DialogueRequest&,const GroundedContext&,const GuardrailPolicy& = {});

// Deterministic: same request -> same line. Chooses among game fallbacks with a
// matching language-agnostic intent preference, else the engine's per-language default.
DialogueLine fallbackLine(const DialogueRequest&,Intent preferred=Intent::Deflect);

// ---------------------------------------------------------------- service

struct ServiceConfig {
    std::size_t queueCapacity{16};
    std::size_t cacheCapacity{256};
    std::chrono::milliseconds cancelGrace{300};  // wait for an abandoned backend job before the next
    GuardrailPolicy guardrails{};
};

struct ServiceStats {
    std::uint64_t submitted{0}, completedModel{0}, completedCache{0}, completedFallback{0}, cancelled{0}, timeouts{0}, rejected{0}, abandoned{0};
};

// Off-simulation-thread dialogue: submit() and drainCompleted() are called from
// the simulation/game thread; one worker thread prepares, generates (one backend
// job in flight), validates and publishes completed results.
class DialogueService {
public:
    DialogueService(std::shared_ptr<DialogueBackend>,ServiceConfig={});
    ~DialogueService();
    DialogueService(const DialogueService&)=delete;
    DialogueService& operator=(const DialogueService&)=delete;

    // Always yields a ticket; a full queue or invalid request completes
    // immediately with a fallback line.
    Ticket submit(DialogueRequest);
    bool cancel(Ticket);                         // false if already completed
    std::vector<DialogueResult> drainCompleted();
    // Blocks until the ticket completes or the timeout passes (tests, tools).
    std::optional<DialogueResult> waitFor(Ticket,std::chrono::milliseconds);
    ServiceStats stats() const;
    void clearCache();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// ---------------------------------------------------------------- stub backend

// Deterministic backend for tests and headless builds. The default responder
// speaks the first grounded fact line from the prompt; a custom responder may
// return any JSON (malformed, leaking, overlong) to exercise validation.
class StubBackend final : public DialogueBackend {
public:
    struct Config {
        std::function<BackendResponse(const BackendRequest&)> responder;
        std::chrono::milliseconds delay{0};
        Availability availability{Availability::Available};
        std::vector<Language> languages{Language::English,Language::Japanese};
    };
    StubBackend();
    explicit StubBackend(Config);
    ~StubBackend() override;
    BackendInfo info() const override;
    Availability availability() const override;
    bool supportsLanguage(Language) const override;
    void generate(BackendRequest,CancellationToken,std::function<void(BackendResponse)>) override;
    std::uint64_t calls() const;
    static BackendResponse defaultResponse(const BackendRequest&);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace npc::dialogue
