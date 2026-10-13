// Native Kokoro-82M v1.0 synthesis on Core ML (no Python at runtime).
//
// Stage 1 (KokoroDuration): token ids + style -> per-token durations and features.
// Host:                      durations -> frames; features expanded by repetition.
// Stage 2 (KokoroDecoder):   expanded features + style -> 24 kHz PCM (600 samples/frame).
// Models come from tools/convert_kokoro_coreml.py; see third_party/PROVENANCE.md.
import CoreML
import Foundation

public enum SpeechError: Error, CustomStringConvertible {
    case missingModel(String)
    case unknownVoice(String)
    case emptyInput
    case tooLong(Int)
    case coreML(String)
    public var description: String {
        switch self {
        case .missingModel(let m): "Kokoro model files not found: \(m)"
        case .unknownVoice(let v): "unknown voice '\(v)'"
        case .emptyInput: "no speakable phonemes"
        case .tooLong(let n): "line has \(n) phonemes; Kokoro's limit is 510 (split it into sentences)"
        case .coreML(let m): "Core ML: \(m)"
        }
    }
}

/// One model token and the samples it covers in the output audio.
public struct TimedToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case begin, symbol(Character), end }
    public var kind: Kind
    public var startSample: Int
    public var endSample: Int
}

public struct SynthesisResult: Sendable {
    public var pcm: [Float]
    public var sampleRate: Double
    public var tokens: [TimedToken]
    public var phonemes: String
    public var duration: Double { Double(pcm.count) / sampleRate }
}

public final class KokoroSynthesizer: @unchecked Sendable {
    public static let sampleRate = 24_000.0
    public static let samplesPerFrame = 600
    public static let maxPhonemes = 510

    public let directory: URL
    public let voices: [String]
    private let vocab: [Character: Int32]
    private let duration: MLModel
    private let decoder: MLModel
    private let voiceRows: [String: Int]
    private let voiceLock = NSLock()
    private var voiceCache: [String: [Float]] = [:]

    /// Loads (and on first use compiles) both stages. `computeUnits` defaults to CPU+GPU:
    /// the decoder is fp32 and accumulates phase, so it is not an ANE candidate as is.
    public init(directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        self.directory = directory
        let fm = FileManager.default
        for f in ["KokoroDuration.mlpackage", "KokoroDecoder.mlpackage", "vocab.json", "manifest.json"]
        where !fm.fileExists(atPath: directory.appending(path: f).path) { throw SpeechError.missingModel(f) }

        let rawVocab = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: directory.appending(path: "vocab.json")))
        var v: [Character: Int32] = [:]
        for (k, id) in rawVocab where k.count == 1 { v[k.first!] = id }
        vocab = v

        struct Manifest: Decodable { struct Voice: Decodable { let rows: Int; let dim: Int }; let voices: [String: Voice] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appending(path: "manifest.json")))
        voiceRows = manifest.voices.mapValues(\.rows)
        voices = manifest.voices.keys.sorted()

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        duration = try MLModel(contentsOf: try Self.compiled(directory.appending(path: "KokoroDuration.mlpackage")), configuration: config)
        decoder = try MLModel(contentsOf: try Self.compiled(directory.appending(path: "KokoroDecoder.mlpackage")), configuration: config)
    }

    /// Compiled .mlmodelc, cached next to the user's caches keyed by package mtime.
    private static func compiled(_ package: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = (try? fm.attributesOfItem(atPath: package.appending(path: "Manifest.json").path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "NPCVoice/coreml/\(package.deletingPathExtension().lastPathComponent)-\(Int(stamp)).mlmodelc")
        if fm.fileExists(atPath: cache.path) { return cache }
        let tmp = try MLModel.compileModel(at: package)
        try fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: cache)
        try fm.moveItem(at: tmp, to: cache)
        return cache
    }

    /// Symbols the model knows; anything else in `phonemes` is dropped (as Kokoro does).
    public func tokenIDs(_ phonemes: String) -> [Int32] {
        [0] + phonemes.compactMap { vocab[$0] } + [0]
    }

    public func synthesize(phonemes: String, voice: String, speed: Double = 1.0) throws -> SynthesisResult {
        let kept = phonemes.filter { vocab[$0] != nil }
        guard !kept.isEmpty else { throw SpeechError.emptyInput }
        guard kept.count <= Self.maxPhonemes else { throw SpeechError.tooLong(kept.count) }
        let ids: [Int32] = [0] + kept.map { vocab[$0]! } + [0]
        let ref = try styleVector(voice: voice, phonemeCount: kept.count)
        let n = ids.count

        // Stage 1.
        let idArray = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        ids.withUnsafeBufferPointer { src in
            idArray.withUnsafeMutableBytes { dst, _ in dst.copyMemory(from: UnsafeRawBufferPointer(src)) }
        }
        let refArray = try floatArray(ref, shape: [1, 256])
        let a = try predict(duration, ["input_ids": idArray, "ref_s": refArray])
        guard let durations = a.featureValue(for: "duration")?.multiArrayValue,
              let d = a.featureValue(for: "d")?.multiArrayValue,
              let tEn = a.featureValue(for: "t_en")?.multiArrayValue else { throw SpeechError.coreML("stage 1 outputs") }

        // Host alignment: round(duration / speed), at least one frame per token.
        let durs = toFloats(durations)
        let frames = durs.map { max(1, Int(($0 / Float(speed)).rounded(.toNearestOrEven))) }
        let total = frames.reduce(0, +)

        // en[1,640,T] = d^T expanded; asr[1,512,T] = t_en expanded.
        let dF = toFloats(d)            // [1, n, 640] row-major
        let tF = toFloats(tEn)          // [1, 512, n]
        var en = [Float](repeating: 0, count: 640 * total)
        var asr = [Float](repeating: 0, count: 512 * total)
        var col = 0
        for (tok, count) in frames.enumerated() {
            for _ in 0..<count {
                for c in 0..<640 { en[c * total + col] = dF[tok * 640 + c] }
                for c in 0..<512 { asr[c * total + col] = tF[c * n + tok] }
                col += 1
            }
        }

        // Stage 2.
        let b = try predict(decoder, ["en": try floatArray(en, shape: [1, 640, total]),
                                      "asr": try floatArray(asr, shape: [1, 512, total]),
                                      "ref_s": refArray])
        guard let audio = b.featureValue(for: "audio")?.multiArrayValue else { throw SpeechError.coreML("stage 2 output") }
        let pcm = toFloats(audio)

        var tokens: [TimedToken] = []
        var at = 0
        let symbols = Array(kept)
        for (i, f) in frames.enumerated() {
            let len = f * Self.samplesPerFrame
            let kind: TimedToken.Kind = i == 0 ? .begin : i == frames.count - 1 ? .end : .symbol(symbols[i - 1])
            tokens.append(TimedToken(kind: kind, startSample: at, endSample: min(at + len, pcm.count)))
            at += len
        }
        return SynthesisResult(pcm: pcm, sampleRate: Self.sampleRate, tokens: tokens, phonemes: String(kept))
    }

    // MARK: - Helpers

    /// Kokoro picks the style row by phoneme count (KPipeline: pack[len(phonemes) - 1]).
    private func styleVector(voice: String, phonemeCount: Int) throws -> [Float] {
        guard let rows = voiceRows[voice] else { throw SpeechError.unknownVoice(voice) }
        voiceLock.lock(); defer { voiceLock.unlock() }
        if voiceCache[voice] == nil {
            let data = try Data(contentsOf: directory.appending(path: "voices/\(voice).f32"))
            voiceCache[voice] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let pack = voiceCache[voice]!
        let row = min(max(phonemeCount - 1, 0), rows - 1)
        return Array(pack[(row * 256)..<(row * 256 + 256)])
    }

    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray]) throws -> MLFeatureProvider {
        do { return try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: inputs)) }
        catch { throw SpeechError.coreML("\(error)") }
    }

    private func floatArray(_ v: [Float], shape: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        v.withUnsafeBufferPointer { src in
            a.withUnsafeMutableBytes { dst, _ in dst.copyMemory(from: UnsafeRawBufferPointer(src)) }
        }
        return a
    }

    /// Contiguous row-major Float copy of any float multiarray (handles strides and fp16).
    private func toFloats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let count = shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        a.withUnsafeBytes { raw in
            for i in 0..<count {
                var rem = i, offset = 0
                for dim in stride(from: shape.count - 1, through: 0, by: -1) {
                    index[dim] = rem % shape[dim]; rem /= shape[dim]
                    offset += index[dim] * strides[dim]
                }
                switch a.dataType {
                case .float32: out[i] = raw.load(fromByteOffset: offset * 4, as: Float.self)
                case .float16: out[i] = Float(raw.load(fromByteOffset: offset * 2, as: Float16.self))
                case .double: out[i] = Float(raw.load(fromByteOffset: offset * 8, as: Double.self))
                default: out[i] = 0
                }
            }
        }
        return out
    }
}
