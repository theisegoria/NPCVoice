// NPCVoiceKit's public Swift API. Self-contained types (library evolution); the engine
// modules are implementation details.
import Foundation
import Synchronization
internal import NPCCore
internal import NPCKit
internal import NPCMLX
internal import NPCSpeech

/// Which model writes the lines.
public enum NPCVoiceModel: Sendable {
    /// The bundled open-weight model (Qwen3.5-2B 4-bit via MLX). `nil` uses the default models folder.
    case bundled(modelsFolder: URL? = nil)
    /// Apple Intelligence's on-device model (macOS 27, when enabled).
    case appleIntelligence
}

/// Runtime game state passed with each request.
public struct NPCGameState: Sendable {
    public var flags: [String] = []
    public var location = ""
    public var objective = ""
    public var memories: [String] = []
    public var topics: [String] = []
    public var mood: String?
    public init() {}
}

/// A spoken line, already validated against the character's constraints.
public struct NPCLine: Sendable {
    public struct Command: Sendable { public let kind: String; public let target: String }
    public let character: String
    public let text: String
    public let emotion: String
    public let intent: String
    public let commands: [Command]
    public let voice: String
    public let language: String
    /// "model", "cache" or "fallback".
    public let source: String
    /// Why a fallback line was used ("none" otherwise).
    public let fallbackReason: String
    public let latency: Duration
}

public struct NPCViseme: Sendable { public let name: String; public let start: Double; public let end: Double; public let weight: Float }

public struct NPCSpeech: Sendable {
    public let samples: [Float]          // mono, -23 LUFS
    public let sampleRate: Double        // 24000
    public let visemes: [NPCViseme]
    public let phonemes: String
}

/// One piece of a streamed line (a sentence, or part of a long one). Times are seconds
/// from the start of the line, so chunks can be scheduled back to back.
public struct NPCSpeechChunk: Sendable {
    public let index: Int
    public let isLast: Bool
    public let samples: [Float]          // mono; the first chunk's loudness gain applies to the whole line
    public let sampleRate: Double        // 24000
    public let startTime: Double
    public let visemes: [NPCViseme]
    public let phonemes: String
}

public enum NPCVoiceError: Error, CustomStringConvertible {
    case setup(String)
    public var description: String { switch self { case .setup(let m): m } }
}

public enum NPCLogLevel: Int32, Sendable, Comparable {
    case debug = 0, info = 1, warning = 2, error = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public final class NPCVoiceRuntime: @unchecked Sendable {
    private let handle: ProjectHandle
    private let engine: DialogueEngine
    private let backend: any DialogueModelBackend
    private let modelsFolder: URL?
    private var speech: SpeechSynthesizer?
    private let lock = NSLock()

    /// Loads a `.npcproj` project and the dialogue model (blocks until the model is loaded).
    public init(project: URL, model: NPCVoiceModel = .bundled()) async throws {
        do {
            handle = try ProjectHandle(url: project)
            switch model {
            case .bundled(let folder):
                modelsFolder = folder
                guard let dir = folder.map({ $0.appending(path: "qwen3.5-2b-4bit") }) ?? MLXBackend.defaultModelDirectory() else {
                    throw NPCVoiceError.setup("Bundled model not found. Pass modelsFolder or set NPCVOICE_MODELS.")
                }
                let mlx = MLXBackend(modelDirectory: dir)
                try await mlx.warmUp()
                backend = mlx
                engine = try DialogueEngine(backend: mlx)
            case .appleIntelligence:
                modelsFolder = nil
                let fm = FoundationModelsBackend()
                guard fm.availability() == .available else { throw NPCVoiceError.setup("Apple Intelligence is unavailable") }
                backend = fm
                engine = try DialogueEngine(backend: fm)
            }
        } catch let e as NPCVoiceError { throw e } catch { throw NPCVoiceError.setup("\(error)") }
    }

    /// Frees the dialogue model's memory (e.g. during a cutscene); the next `respond` reloads
    /// it (~1-2 s, so call `prewarmModel()` ahead of the next conversation).
    public func unloadModel() { backend.unload() }

    /// Starts loading the dialogue model in the background.
    public func prewarmModel() { backend.prewarm(instructions: "") }

    /// Routes NPCVoice's diagnostics (model loads, fallbacks and why, timings) to your logger.
    /// The handler runs on SDK threads, one message at a time. Pass nil to silence.
    public static func setLogHandler(minimumLevel: NPCLogLevel = .info,
                                     _ handler: (@Sendable (NPCLogLevel, String) -> Void)?) {
        LogBridge.handler.withLock { $0 = handler }
        if handler == nil { npc_set_log_callback(nil, nil, minimumLevel.rawValue); return }
        npc_set_log_callback({ _, level, message in
            guard let message, let h = LogBridge.handler.withLock({ $0 }) else { return }
            h(NPCLogLevel(rawValue: level) ?? .info, String(cString: message))
        }, nil, minimumLevel.rawValue)
    }

    /// One line from `character` in reply to the player (or to `event`).
    public func respond(character: String, playerSays: String? = nil, event: String? = nil,
                        state: NPCGameState = .init(), deadline: Duration = .milliseconds(2500)) async throws -> NPCLine {
        var call: GameCall
        if let playerSays { call = GameCall(character: character, playerUtterance: playerSays) }
        else if let event { call = GameCall(character: character, trigger: event) }
        else { throw NPCVoiceError.setup("Pass playerSays or event") }
        call.flags = state.flags; call.location = state.location; call.objective = state.objective
        call.memories = state.memories; call.topics = state.topics; call.mood = state.mood
        var budget = Budget(); budget.deadlineMs = Int(deadline.components.seconds * 1000 + deadline.components.attoseconds / 1_000_000_000_000_000)
        call.budget = budget
        let r: DialogueResult
        do { r = try await engine.respond(to: try handle.request(for: call)) } catch { throw NPCVoiceError.setup("\(error)") }
        return NPCLine(character: r.line.character, text: r.line.text, emotion: r.line.emotion.rawValue, intent: r.line.intent.rawValue,
                       commands: r.line.commands.map { .init(kind: $0.kind, target: $0.target) }, voice: r.line.voice,
                       language: r.line.language.rawValue, source: r.source.rawValue, fallbackReason: r.fallbackReason,
                       latency: .milliseconds(Int(r.latencyMs)))
    }

    /// Synthesises a line in its character's voice, with a viseme track for lip-sync.
    public func speak(_ line: NPCLine, speed: Double = 1) throws -> NPCSpeech {
        try speak(line.text, voice: line.voice, speed: speed)
    }

    public func speak(_ text: String, voice: String, speed: Double = 1) throws -> NPCSpeech {
        do {
            let (synth, overrides) = try speechSetup(voice: voice)
            let s = try synth.speak(text, voice: voice, speed: speed, pronunciations: overrides)
            return NPCSpeech(samples: s.pcm, sampleRate: s.sampleRate,
                             visemes: s.visemes.map { .init(name: $0.viseme.rawValue, start: $0.start, end: $0.end, weight: $0.weight) },
                             phonemes: s.phonemes)
        } catch let e as NPCVoiceError { throw e } catch { throw NPCVoiceError.setup("\(error)") }
    }

    /// Streams a line sentence by sentence: start playback when the first chunk arrives
    /// instead of waiting for the whole line. Stopping iteration cancels the rest.
    public func speakStream(_ line: NPCLine, speed: Double = 1) -> AsyncThrowingStream<NPCSpeechChunk, Error> {
        speakStream(line.text, voice: line.voice, speed: speed)
    }

    public func speakStream(_ text: String, voice: String, speed: Double = 1) -> AsyncThrowingStream<NPCSpeechChunk, Error> {
        AsyncThrowingStream { continuation in
            let cancelled = CancelFlag()
            continuation.onTermination = { _ in cancelled.set() }
            Task.detached { [self] in
                do {
                    let (synth, overrides) = try speechSetup(voice: voice)
                    try synth.stream(text, voice: voice, speed: speed, pronunciations: overrides,
                                     isCancelled: { cancelled.isSet }) { c in
                        continuation.yield(NPCSpeechChunk(
                            index: c.index, isLast: c.isLast, samples: c.pcm, sampleRate: c.sampleRate, startTime: c.startTime,
                            visemes: c.visemes.map { .init(name: $0.viseme.rawValue, start: $0.start, end: $0.end, weight: $0.weight) },
                            phonemes: c.phonemes))
                    }
                    continuation.finish()
                } catch let e as NPCVoiceError { continuation.finish(throwing: e) }
                catch { continuation.finish(throwing: NPCVoiceError.setup("\(error)")) }
            }
        }
    }

    /// The synthesizer (created on first use) and the project's pronunciations for `voice`.
    private func speechSetup(voice: String) throws -> (SpeechSynthesizer, [String: String]) {
        let synth: SpeechSynthesizer = try lock.withLock {
            if let speech { return speech }
            guard let dir = modelsFolder ?? SpeechSynthesizer.defaultModelsDirectory() else {
                throw NPCVoiceError.setup("Speech models not found. Pass modelsFolder or set NPCVOICE_MODELS.")
            }
            let s = try SpeechSynthesizer(models: dir)
            speech = s
            return s
        }
        let language: NPCKit.Language = SpeechSynthesizer.language(ofVoice: voice) == .japanese ? .japanese : .english
        return (synth, (try? handle.project())?.pronunciationMap(language) ?? [:])
    }
}

private enum LogBridge {
    static let handler = Mutex<(@Sendable (NPCLogLevel, String) -> Void)?>(nil)
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
