// Swift mirrors of the dialogue core's JSON contract (docs/JSON.md). Key names
// match the C++ codec exactly; the core rejects unknown keys, so these types must
// not grow keys the core does not know.
import Foundation

public enum Language: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case japanese = "ja"
    public var id: String { rawValue }
    public var displayName: String { self == .english ? "English" : "Japanese" }
}

public enum Emotion: String, Codable, CaseIterable, Sendable, Identifiable {
    case neutral, happy, sad, angry, fear, surprise, disgust, contempt, pain, exertion, concentration, fatigue
    public var id: String { rawValue }
}

public enum Intent: String, Codable, CaseIterable, Sendable, Identifiable {
    case inform, warn, request, refuse, greet, farewell, deflect, plead, threaten
    public var id: String { rawValue }
}

public struct WorldProfile: Codable, Equatable, Sendable {
    public var name = ""
    public var setting = ""
    public var tone = ""
    public var contentRating = ""
    public var rules: [String] = []
    public init() {}
}

public struct Relationship: Codable, Equatable, Hashable, Sendable {
    public var target: String
    public var description: String
    public init(target: String, description: String) { self.target = target; self.description = description }
}

public struct FallbackLine: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var intent: Intent
    public var emotion: Emotion
    public init(text: String, intent: Intent = .deflect, emotion: Emotion = .neutral) {
        self.text = text; self.intent = intent; self.emotion = emotion
    }
}

/// A character as stored in a project (`characters/<id>.json`): the profile plus the
/// project-only `fallbacks` and `commands` (command kinds).
public struct CharacterProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var role = ""
    public var persona = ""
    public var traits: [String] = []
    public var goals: [String] = []
    public var mood = ""
    public var relationships: [Relationship] = []
    public var speechStyle = ""
    public var voice: String
    public var language: Language
    public var allowedEmotions: [Emotion] = []
    public var allowedIntents: [Intent] = []
    public var maxLineCharacters = 0
    public var forbiddenTopics: [String] = []
    public var forbiddenTerms: [String] = []
    public var fallbacks: [FallbackLine] = []
    public var commands: [String] = []

    public init(id: String, displayName: String, voice: String, language: Language) {
        self.id = id; self.displayName = displayName; self.voice = voice; self.language = language
    }
}

public struct Fact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var knownBy: [String] = []
    public var requiredFlags: [String] = []
    public var tags: [String] = []
    public var leakKeywords: [String] = []
    public var salience = 0.5
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct CommandSpec: Codable, Equatable, Identifiable, Sendable {
    public var kind: String
    public var description: String
    public var targets: [String] = []
    public var id: String { kind }
    public init(kind: String, description: String, targets: [String] = []) {
        self.kind = kind; self.description = description; self.targets = targets
    }
}

public struct Budget: Codable, Equatable, Sendable {
    public var deadlineMs = 2500
    public var maxOutputTokens = 160
    public var maxPromptTokens = 3000
    public var maxFacts = 12
    public var maxPerception = 6
    public var maxExchanges = 6
    public var maxMemories = 6
    public init() {}
}

public struct Sampling: Codable, Equatable, Sendable {
    public var greedy = true
    public var temperature = 0.7
    public var seed: UInt64 = 0
    public init(greedy: Bool = true, temperature: Double = 0.7, seed: UInt64 = 0) {
        self.greedy = greedy; self.temperature = temperature; self.seed = seed
    }
}

public struct ProjectDefaults: Codable, Equatable, Sendable {
    public var budget = Budget()
    public var sampling = Sampling()
    public var maxCommands = 2
    public init() {}
}

// MARK: - Game calls

public enum Speaker: String, Codable, Sendable { case player, character, other }

public struct Exchange: Codable, Equatable, Hashable, Sendable {
    public var speaker: Speaker
    public var text: String
    public init(_ speaker: Speaker, _ text: String) { self.speaker = speaker; self.text = text }
}

public struct Perception: Codable, Equatable, Sendable {
    public var text: String
    public var salience: Double
    public init(_ text: String, salience: Double = 0.5) { self.text = text; self.salience = salience }
}

/// What the game knows at the moment an NPC should speak. Authored data comes from
/// the project; the call carries only runtime state.
public struct GameCall: Codable, Equatable, Sendable {
    public var character: String
    public var playerUtterance: String?
    public var trigger: String?
    public var flags: [String] = []
    public var location = ""
    public var objective = ""
    public var perception: [Perception] = []
    public var exchanges: [Exchange] = []
    public var memories: [String] = []
    public var topics: [String] = []
    public var mood: String?
    public var sampling: Sampling?
    public var budget: Budget?
    public var priority = 0
    public var allowCache = true

    public init(character: String, playerUtterance: String) {
        self.character = character; self.playerUtterance = playerUtterance
    }
    public init(character: String, trigger: String) {
        self.character = character; self.trigger = trigger
    }
}

// MARK: - Results

public struct Command: Codable, Equatable, Hashable, Sendable {
    public var kind: String
    public var target: String
}

public struct DialogueLine: Codable, Equatable, Sendable {
    public var text: String
    public var emotion: Emotion
    public var intent: Intent
    public var commands: [Command]
    public var language: Language
    public var voice: String
    public var character: String
}

public enum LineSource: String, Codable, Sendable { case model, cache, fallback }

public struct DialogueResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case line, cancelled }
    public var ticket: UInt64
    public var status: Status
    public var source: LineSource
    /// "none" for model and cache lines; otherwise why the fallback was used.
    public var fallbackReason: String
    public var line: DialogueLine
    public var diagnostic: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var latencyMs: Double
    public var usedFactIds: [String]
}

public struct ServiceStats: Codable, Equatable, Sendable {
    public var submitted, completedModel, completedCache, completedFallback, cancelled, timeouts, rejected, abandoned: Int
}

public struct OutputSchema: Codable, Equatable, Sendable {
    public struct Command: Codable, Equatable, Sendable {
        public var kind: String
        public var description: String
        public var targets: [String]
    }
    public var emotions: [Emotion]
    public var intents: [Intent]
    public var commands: [Command]
    public var maxCommands: Int
    public var maxCharacters: Int
    public init(emotions: [Emotion], intents: [Intent], commands: [Command] = [], maxCommands: Int = 0, maxCharacters: Int = 220) {
        self.emotions = emotions; self.intents = intents; self.commands = commands
        self.maxCommands = maxCommands; self.maxCharacters = maxCharacters
    }
}

/// Prompt inspection (what the model will see, and why).
public struct PreparedPrompt: Codable, Equatable, Sendable {
    public var instructions: String
    public var prompt: String
    public var schema: OutputSchema
    public var language: Language
    public var maxOutputTokens: Int
    public var estimatedPromptTokens: Int
    public var usedFactIds: [String]
    public var withheldKeywords: [String]
    public var cacheKey: String
}

public struct ProjectDiagnostic: Codable, Equatable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var severity: Severity
    public var path: String
    public var message: String
}

// MARK: - Backend wire format

/// What a model backend receives: fully assembled instructions and prompt plus the
/// output schema to constrain decoding to.
public struct BackendRequest: Codable, Equatable, Sendable {
    public var instructions: String
    public var prompt: String
    public var schema: OutputSchema
    public var language: Language
    public var maxOutputTokens: Int
    public var sampling: Sampling
    public init(instructions: String, prompt: String, schema: OutputSchema, language: Language, maxOutputTokens: Int, sampling: Sampling = .init()) {
        self.instructions = instructions; self.prompt = prompt; self.schema = schema
        self.language = language; self.maxOutputTokens = maxOutputTokens; self.sampling = sampling
    }
}

public struct BackendResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok, cancelled, unavailable, refusal, guardrail
        case contextExceeded = "context_exceeded"
        case unsupportedLanguage = "unsupported_language"
        case rateLimited = "rate_limited"
        case decodingFailure = "decoding_failure"
        case error
    }
    public var status: Status
    public var json: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var diagnostic: String
    public init(status: Status, json: String = "", promptTokens: Int = 0, outputTokens: Int = 0, diagnostic: String = "") {
        self.status = status; self.json = json; self.promptTokens = promptTokens
        self.outputTokens = outputTokens; self.diagnostic = diagnostic
    }
}

public enum BackendAvailability: Int32, Sendable {
    case available = 0, deviceNotEligible, notEnabled, modelNotReady, unsupported
}

/// Author-supplied pronunciation for TTS, in the misaki phoneme alphabet Kokoro reads.
public struct Pronunciation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var word: String
    public var phonemes: String
    public var language: Language
    public var id: String { language.rawValue + ":" + word }
    public init(word: String, phonemes: String, language: Language = .english) {
        self.word = word; self.phonemes = phonemes; self.language = language
    }
}
