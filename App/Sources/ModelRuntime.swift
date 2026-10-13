import AVFoundation
import NPCKit
import NPCMLX
import NPCSpeech
import SwiftUI

/// The dialogue model the playground talks to.
enum DialogueBackendChoice: String, CaseIterable, Identifiable {
    case mlx, apple, stub
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mlx: "Qwen3.5 2B (bundled)"
        case .apple: "Apple Intelligence"
        case .stub: "Test stub"
        }
    }
    var symbol: String {
        switch self { case .mlx: "cpu"; case .apple: "apple.intelligence"; case .stub: "testtube.2" }
    }
}

/// App-wide model state: one engine per backend (loaded lazily, kept warm), the speech
/// synthesizer, and audio playback. Heavy work runs off the main actor.
@MainActor @Observable
final class ModelRuntime {
    enum Status: Equatable {
        case idle, loading, ready, unavailable(String)
        var label: String {
            switch self {
            case .idle: "Not loaded"
            case .loading: "Loading…"
            case .ready: "Ready"
            case .unavailable(let why): why
            }
        }
    }

    var backend: DialogueBackendChoice = DialogueBackendChoice(rawValue: UserDefaults.standard.string(forKey: Preferences.defaultBackendKey) ?? "") ?? .mlx {
        didSet { if backend != oldValue { Task { await prepare() } } }
    }
    private(set) var status: Status = .idle
    private(set) var speechStatus: Status = .idle
    private(set) var speaking: UUID?

    private var engines: [DialogueBackendChoice: DialogueEngine] = [:]
    private var synthesizer: SpeechSynthesizer?
    private var player: AVAudioPlayer?

    /// Loads the selected backend (Qwen weights load once, ~1.7 GB, then stay resident).
    func prepare() async {
        if engines[backend] != nil { status = .ready; return }
        status = .loading
        let choice = backend
        do {
            let engine: DialogueEngine = try await Task.detached(priority: .userInitiated) {
                switch choice {
                case .stub:
                    return try DialogueEngine.stub(delayMs: 250)
                case .apple:
                    let fm = FoundationModelsBackend()
                    guard fm.availability() == .available else { throw NPCError.invalid("Apple Intelligence is off or unavailable") }
                    return try DialogueEngine(backend: fm)
                case .mlx:
                    guard let dir = MLXBackend.defaultModelDirectory() else { throw NPCError.invalid("Bundled model not found") }
                    let mlx = MLXBackend(modelDirectory: dir)
                    try await mlx.warmUp()
                    return try DialogueEngine(backend: mlx)
                }
            }.value
            engines[choice] = engine
            if backend == choice { status = .ready }
        } catch {
            if backend == choice { status = .unavailable("\(error)") }
        }
    }

    func engine() async throws -> DialogueEngine {
        if engines[backend] == nil { await prepare() }
        guard let e = engines[backend] else { throw NPCError.invalid(status.label) }
        return e
    }

    /// Synthesizes and plays a line (only on an explicit user action or auto-speak).
    func speak(_ line: DialogueLine, id: UUID) async {
        do {
            if synthesizer == nil {
                speechStatus = .loading
                guard let models = SpeechSynthesizer.defaultModelsDirectory() else { throw SpeechError.missingModel("speech models") }
                synthesizer = try await Task.detached { let s = try SpeechSynthesizer(models: models); try s.warmUp(); return s }.value
                speechStatus = .ready
            }
            let synth = synthesizer!
            let voice = line.voice, text = line.text
            speaking = id
            let spoken = try await Task.detached(priority: .userInitiated) { try synth.speak(text, voice: voice) }.value
            player = try AVAudioPlayer(data: WAV.data(spoken.pcm, sampleRate: spoken.sampleRate))
            player?.play()
            try? await Task.sleep(for: .seconds(spoken.duration))
            if speaking == id { speaking = nil }
        } catch {
            speechStatus = .unavailable("\(error)")
            speaking = nil
        }
    }

    func stopSpeaking() { player?.stop(); speaking = nil; speakingKey = nil }

    private(set) var speakingKey: String?
    private var english: EnglishG2P?

    /// Speaks arbitrary text (pronunciation previews); user-initiated only.
    func speakText(_ text: String, voice: String, overrides: [String: String], id: String) async {
        do {
            if synthesizer == nil {
                guard let models = SpeechSynthesizer.defaultModelsDirectory() else { throw SpeechError.missingModel("speech models") }
                synthesizer = try await Task.detached { let s = try SpeechSynthesizer(models: models); try s.warmUp(); return s }.value
            }
            let synth = synthesizer!
            speakingKey = id
            let spoken = try await Task.detached(priority: .userInitiated) { try synth.speak(text, voice: voice, pronunciations: overrides) }.value
            player = try AVAudioPlayer(data: WAV.data(spoken.pcm, sampleRate: spoken.sampleRate))
            player?.play()
            try? await Task.sleep(for: .seconds(spoken.duration))
            if speakingKey == id { speakingKey = nil }
        } catch {
            speakingKey = nil
        }
    }

    /// Synthesizes without playing (Voice Lab); returns the line and the wall-clock time taken.
    func synthesize(_ text: String, voice: String, speed: Double, overrides: [String: String]) async throws -> VoiceLabResult {
        if synthesizer == nil {
            guard let models = SpeechSynthesizer.defaultModelsDirectory() else { throw SpeechError.missingModel("speech models") }
            synthesizer = try await Task.detached { let s = try SpeechSynthesizer(models: models); try s.warmUp(); return s }.value
        }
        let synth = synthesizer!
        return try await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            let line = try synth.speak(text, voice: voice, speed: speed, pronunciations: overrides)
            let d = ContinuousClock.now - start
            return VoiceLabResult(line: line, voice: voice, text: text,
                                  synthesisSeconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }.value
    }

    /// Plays a synthesized line (user action).
    func play(_ line: SpokenLine) {
        player = try? AVAudioPlayer(data: WAV.data(line.pcm, sampleRate: line.sampleRate))
        player?.play()
    }

    /// Words in `text` that the English lexicon doesn't know, with speech's current guess.
    func unknownEnglishWords(in text: String) async -> [(word: String, guess: String)] {
        do {
            if english == nil {
                guard let models = SpeechSynthesizer.defaultModelsDirectory() else { return [] }
                english = try await Task.detached { try EnglishG2P(directory: models.appending(path: "misaki-en")) }.value
            }
            let g2p = english!
            return await Task.detached {
                var seen = Set<String>(), out: [(String, String)] = []
                for word in g2p.phonemize(text).unknownWords where seen.insert(word.lowercased()).inserted {
                    out.append((word, g2p.phonemize(word).phonemes.trimmingCharacters(in: .whitespaces)))
                }
                return out.sorted { $0.0 < $1.0 }
            }.value
        } catch { return [] }
    }
}

/// Toolbar control: which model, and whether it's ready.
struct ModelStatusControl: View {
    @Bindable var runtime: ModelRuntime

    var body: some View {
        Menu {
            Picker("Dialogue model", selection: $runtime.backend) {
                ForEach(DialogueBackendChoice.allCases) { b in
                    Label(b.title, systemImage: b.symbol).tag(b)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                statusDot
                Text(runtime.backend.title).lineLimit(1)
            }
        }
        .help("Dialogue model: \(runtime.status.label)")
        .accessibilityLabel("Dialogue model")
        .accessibilityValue("\(runtime.backend.title), \(runtime.status.label)")
        .task { await runtime.prepare() }
    }

    @ViewBuilder private var statusDot: some View {
        switch runtime.status {
        // Not a ProgressView: an indeterminate spinner in a toolbar item risks AppKit's
        // update-constraints loop (it already crashed a grouped Form row).
        case .loading: Image(systemName: "circle.dotted").foregroundStyle(.secondary).symbolEffect(.pulse)
        case .ready: Circle().fill(.green).frame(width: 7, height: 7)
        case .unavailable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle: Circle().fill(.secondary).frame(width: 7, height: 7)
        }
    }
}
