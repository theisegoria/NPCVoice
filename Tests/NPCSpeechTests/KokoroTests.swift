import Foundation
import Testing
@testable import NPCSpeech

private let modelDir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "third_party/models/kokoro-82m-coreml")
private let haveModel = FileManager.default.fileExists(atPath: modelDir.appending(path: "KokoroDecoder.mlpackage").path)

struct KokoroManifest: Decodable {
    struct Fixture: Decodable { let voice: String; let phonemes: String; let input_ids: [Int32]; let pred_dur: [Int]; let samples: Int; let audio: String }
    let fixtures: [Fixture]
}

/// Swift + Core ML against the PyTorch reference fixtures written by the converter.
@Suite(.enabled(if: haveModel, "converted Kokoro models not present"), .serialized)
struct KokoroParity {
    static let synth = try! KokoroSynthesizer(directory: modelDir)
    static let manifest = try! JSONDecoder().decode(KokoroManifest.self, from: Data(contentsOf: modelDir.appending(path: "manifest.json")))

    @Test func matchesPyTorchReference() throws {
        for fx in Self.manifest.fixtures {
            #expect(Self.synth.tokenIDs(fx.phonemes) == fx.input_ids, "\(fx.voice) ids")
            let clock = ContinuousClock()
            var result: SynthesisResult!
            let elapsed = try clock.measure { result = try Self.synth.synthesize(phonemes: fx.phonemes, voice: fx.voice) }
            let frames = result.tokens.map { ($0.endSample - $0.startSample + 599) / 600 }
            #expect(frames == fx.pred_dur, "\(fx.voice) durations")
            #expect(result.pcm.count == fx.samples)
            let want = try Data(contentsOf: modelDir.appending(path: fx.audio)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let n = min(want.count, result.pcm.count)
            var sig = 0.0, err = 0.0
            for i in 0..<n { sig += Double(want[i] * want[i]); let d = Double(result.pcm[i] - want[i]); err += d * d }
            let snr = 10 * log10(sig / max(err, 1e-12))
            let rtf = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print("\(fx.voice): SNR \(String(format: "%.1f", snr)) dB, \(String(format: "%.2f", result.duration)) s audio in \(String(format: "%.3f", rtf)) s (RTF \(String(format: "%.3f", rtf / result.duration)))")
            #expect(snr > 25, "\(fx.voice) SNR \(snr)")
        }
    }

    @Test func timelineTilesTheAudio() throws {
        let r = try Self.synth.synthesize(phonemes: "həlˈO wˈɜɹld.", voice: "af_heart")
        #expect(r.tokens.first?.kind == .begin && r.tokens.last?.kind == .end)
        #expect(r.tokens.first?.startSample == 0 && r.tokens.last?.endSample == r.pcm.count)
        for (a, b) in zip(r.tokens, r.tokens.dropFirst()) { #expect(a.endSample == b.startSample) }
    }

    @Test func rejectsBadInput() {
        #expect(throws: SpeechError.self) { try Self.synth.synthesize(phonemes: "", voice: "af_heart") }
        #expect(throws: SpeechError.self) { try Self.synth.synthesize(phonemes: "hi", voice: "nobody") }
    }
}

extension KokoroParity {
    @Test func realOutputMapsToLipSync() throws {
        for fx in Self.manifest.fixtures {
            let r = try Self.synth.synthesize(phonemes: fx.phonemes, voice: fx.voice)
            var unknown: [Character] = []
            let segs = LipSync.phonemes(from: r.tokens, language: fx.voice.hasPrefix("j") ? .japanese : .english,
                                        sampleRate: r.sampleRate, unknown: &unknown)
            #expect(unknown.isEmpty, "\(fx.voice): \(unknown)")
            #expect(abs(segs.last!.end - r.duration) < 1e-6)
            var pcm = r.pcm
            Loudness.normalize(&pcm, sampleRate: r.sampleRate)
            #expect(abs(Loudness.measure(pcm, sampleRate: r.sampleRate).integratedLUFS - -23) < 0.1)
        }
    }
}

@Suite(.enabled(if: SpeechSynthesizer.defaultModelsDirectory() != nil, "speech models not present"), .serialized)
struct EndToEndSpeech {
    static let synth = try! SpeechSynthesizer(models: SpeechSynthesizer.defaultModelsDirectory()!)

    @Test(arguments: [("af_heart", "Evening, love. A room costs three silver marks a night."),
                      ("jf_alpha", "ようこそ、旅の方。嵐の前の晩に、鈴が鳴ります。")])
    func speaksTextWithLipSync(voice: String, text: String) throws {
        let line = try Self.synth.speak(text, voice: voice)
        #expect(line.duration > 1 && line.duration < 10)
        #expect(!line.visemes.isEmpty && abs(line.visemes.last!.end - line.duration) < 1e-6)
        #expect(abs(Loudness.measure(line.pcm, sampleRate: line.sampleRate).integratedLUFS - -23) < 0.1)
    }
}
