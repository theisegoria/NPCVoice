// Text -> speech for NPC lines: G2P, Kokoro on Core ML, loudness normalisation and a
// lip-sync track. One synthesizer per process; calls are serialised.
import Foundation

public struct SpokenLine: Sendable {
    public var pcm: [Float]                 // mono, loudness-normalised
    public var sampleRate: Double
    public var phonemes: String
    public var phonemeTrack: [PhonemeSegment]
    public var visemes: [VisemeSegment]
    public var loudness: Loudness.Measurement   // before normalisation
    public var gainDB: Double
    public var unknownWords: [String]
    public var duration: Double { Double(pcm.count) / sampleRate }
}

/// One piece of a streamed line (a sentence, or part of a long one).
public struct SpokenChunk: Sendable {
    public var index: Int
    public var isLast: Bool
    public var pcm: [Float]                     // mono, gain applied
    public var sampleRate: Double
    public var startTime: Double                // seconds from the start of the line
    public var phonemes: String
    public var phonemeTrack: [PhonemeSegment]   // times from the start of the line
    public var visemes: [VisemeSegment]         // times from the start of the line
    public var gainDB: Double
    public var duration: Double { Double(pcm.count) / sampleRate }
}

public final class SpeechSynthesizer: @unchecked Sendable {
    public let kokoro: KokoroSynthesizer
    private let english: EnglishG2P
    private let japanese: JapaneseG2P
    private let lock = NSLock()

    /// `models`: folder holding kokoro-82m-coreml/, misaki-en/ and misaki-ja/.
    public init(models: URL) throws {
        kokoro = try KokoroSynthesizer(directory: models.appending(path: "kokoro-82m-coreml"))
        english = try EnglishG2P(directory: models.appending(path: "misaki-en"))
        japanese = try JapaneseG2P(directory: models.appending(path: "misaki-ja"))
    }

    /// Bundled models: app resources, `$NPCVOICE_MODELS`, or the repository's third_party/models.
    public static func defaultModelsDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NPCVOICE_MODELS"] { candidates.append(URL(filePath: env)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appending(path: "Models")) }
        // The CLI: a Models folder beside the executable, then the installed app's models.
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appending(path: "Models")) }
        candidates.append(URL(filePath: "/Applications/NPCVoice.app/Contents/Resources/Models"))
        #if DEBUG
        // Development checkouts only; release binaries must not embed source paths.
        var dir = URL(filePath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }   // Sources/NPCSpeech/SpeechSynthesizer.swift -> repo
        candidates.append(dir.appending(path: "third_party/models"))
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "kokoro-82m-coreml/manifest.json").path) }
    }

    /// Compiles both Core ML stages on first use, ahead of the first real line.
    public func warmUp() throws { _ = try kokoro.synthesize(phonemes: "hˈA.", voice: "af_heart") }

    public static func language(ofVoice voice: String) -> SpeechLanguage {
        voice.hasPrefix("j") ? .japanese : .english
    }

    /// `pronunciations`: author overrides for this voice's language (word -> misaki phonemes).
    public func speak(_ text: String, voice: String, speed: Double = 1.0, pronunciations: [String: String] = [:],
                      normalize: Loudness.Policy? = .init()) throws -> SpokenLine {
        let language = Self.language(ofVoice: voice)
        let phonemes: String, unknown: [String]
        switch language {
        case .english:
            let r = english.phonemize(text, overrides: pronunciations); phonemes = r.phonemes; unknown = r.unknownWords
        case .japanese:
            phonemes = japanese.phonemize(text, overrides: pronunciations); unknown = []
        }
        lock.lock(); defer { lock.unlock() }
        // Kokoro's context is 510 phonemes; long lines are synthesised per sentence and joined.
        var pcm: [Float] = [], tokens: [TimedToken] = []
        for chunk in Self.chunks(phonemes, limit: KokoroSynthesizer.maxPhonemes) {
            let r = try kokoro.synthesize(phonemes: chunk, voice: voice, speed: speed)
            let offset = pcm.count
            tokens += r.tokens.map { TimedToken(kind: $0.kind, startSample: $0.startSample + offset, endSample: $0.endSample + offset) }
            pcm += r.pcm
        }
        var measured = Loudness.Measurement(), gain = 0.0
        if let normalize { (measured, gain) = Loudness.normalize(&pcm, sampleRate: KokoroSynthesizer.sampleRate, policy: normalize) }
        var missing: [Character] = []
        let track = LipSync.phonemes(from: tokens, language: language, sampleRate: KokoroSynthesizer.sampleRate, unknown: &missing)
        return SpokenLine(pcm: pcm, sampleRate: KokoroSynthesizer.sampleRate, phonemes: phonemes, phonemeTrack: track,
                          visemes: LipSync.visemes(from: track), loudness: measured, gainDB: gain, unknownWords: unknown)
    }

    /// Streams a line sentence by sentence, so the first audio is ready after one sentence
    /// instead of the whole line. Loudness: the first chunk's normalisation gain is used for
    /// the whole line (per-sentence gains would make the level jump), capped per chunk by the
    /// peak ceiling. Stops early when `isCancelled` returns true. Returns the unknown words.
    @discardableResult
    public func stream(_ text: String, voice: String, speed: Double = 1.0, pronunciations: [String: String] = [:],
                       normalize: Loudness.Policy? = .init(), isCancelled: () -> Bool = { false },
                       onChunk: (SpokenChunk) throws -> Void) throws -> [String] {
        let language = Self.language(ofVoice: voice)
        let phonemes: String, unknown: [String]
        switch language {
        case .english:
            let r = english.phonemize(text, overrides: pronunciations); phonemes = r.phonemes; unknown = r.unknownWords
        case .japanese:
            phonemes = japanese.phonemize(text, overrides: pronunciations); unknown = []
        }
        lock.lock(); defer { lock.unlock() }
        let pieces = Self.sentences(phonemes, limit: KokoroSynthesizer.maxPhonemes)
        let rate = KokoroSynthesizer.sampleRate
        var lineGainDB: Double?, elapsed = 0.0
        for (i, piece) in pieces.enumerated() {
            if isCancelled() { break }
            let r = try kokoro.synthesize(phonemes: piece, voice: voice, speed: speed)
            // Kokoro pads every utterance with silence (its begin/end tokens). Between
            // sentences keep only a little of it: the sentence's own punctuation already
            // carries the pause, so the streamed line times like the whole-line synthesis.
            let keep = Int(0.03 * rate)
            var from = 0, to = r.pcm.count
            if i > 0, let begin = r.tokens.first(where: { $0.kind == .begin }) { from = max(0, begin.endSample - keep) }
            if i < pieces.count - 1, let end = r.tokens.last(where: { $0.kind == .end }) { to = min(r.pcm.count, end.startSample + keep) }
            if to <= from { from = 0; to = r.pcm.count }
            let tokens = r.tokens.map {
                TimedToken(kind: $0.kind, startSample: min(max($0.startSample - from, 0), to - from),
                           endSample: min(max($0.endSample - from, 0), to - from))
            }
            var pcm = Array(r.pcm[from..<to]), gainDB = 0.0
            if let normalize {
                let m = Loudness.measure(pcm, sampleRate: rate)
                if lineGainDB == nil, m.method != .silent { lineGainDB = Loudness.normalizationGainDB(m, normalize) }
                gainDB = lineGainDB ?? 0
                if m.samplePeakDBFS > -1e8 { gainDB = min(gainDB, normalize.peakCeilingDBFS - m.samplePeakDBFS) }
                let g = Float(pow(10, gainDB / 20))
                if gainDB != 0 { for j in pcm.indices { pcm[j] *= g } }
            }
            var missing: [Character] = []
            let track = LipSync.phonemes(from: tokens, language: language, sampleRate: rate, unknown: &missing)
                .map { var s = $0; s.start += elapsed; s.end += elapsed; return s }
            let chunk = SpokenChunk(index: i, isLast: i == pieces.count - 1, pcm: pcm, sampleRate: rate, startTime: elapsed,
                                    phonemes: piece, phonemeTrack: track, visemes: LipSync.visemes(from: track), gainDB: gainDB)
            elapsed += chunk.duration
            try onChunk(chunk)
        }
        return unknown
    }

    /// Streaming split: every sentence end (pieces under 12 phonemes join the next one),
    /// and still within Kokoro's context.
    static func sentences(_ phonemes: String, limit: Int) -> [String] {
        var out: [String] = [], cur = ""
        for c in phonemes {
            cur.append(c)
            if ".!?…".contains(c) && cur.trimmingCharacters(in: .whitespaces).count >= 12 { out.append(cur); cur = "" }
            else if cur.count >= limit, let space = cur.lastIndex(of: " ") {
                out.append(String(cur[..<space])); cur = String(cur[cur.index(after: space)...])
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = out.last, cur.trimmingCharacters(in: .whitespaces).count < 12, last.count + cur.count < limit {
                out[out.count - 1] = last + cur
            } else { out.append(cur) }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Splits at sentence ends (then spaces) so each chunk fits Kokoro's context.
    static func chunks(_ phonemes: String, limit: Int) -> [String] {
        var out: [String] = [], cur = ""
        for c in phonemes {
            cur.append(c)
            if ".!?".contains(c) && cur.count > limit / 2 { out.append(cur); cur = "" }
            else if cur.count >= limit, let space = cur.lastIndex(of: " ") {
                out.append(String(cur[..<space])); cur = String(cur[cur.index(after: space)...])
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }
}

public enum WAV {
    /// 32-bit float mono WAV.
    public static func data(_ pcm: [Float], sampleRate: Double) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(pcm.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
