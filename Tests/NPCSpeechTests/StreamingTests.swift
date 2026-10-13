import Foundation
import Testing
@testable import NPCSpeech

private let models = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "third_party/models")
private let haveModels = FileManager.default.fileExists(atPath: models.appending(path: "kokoro-82m-coreml/KokoroDecoder.mlpackage").path)

@Suite("Sentence splitting for streamed speech")
struct SentenceSplitTests {
    @Test func splitsEverySentenceAndMergesFragments() {
        let p = "ˈivnɪŋ, lˈʌv. ɐ ɹˈum kˈɔsts θɹˈi sˈɪlvəɹ mˈɑɹks ɐ nˈIt. bɹˈɛkfəst ɪz ˈɛkstɹə. ˈO!"
        let s = SpeechSynthesizer.sentences(p, limit: 510)
        #expect(s.count == 3, "\(s)")                 // "ˈO!" is too short and joins the last sentence
        #expect(s.joined(separator: " ") == p)
    }

    @Test func respectsKokoroContext() {
        let long = String(repeating: "lˈɔŋ wˈɜɹd ", count: 120)
        for piece in SpeechSynthesizer.sentences(long, limit: 510) { #expect(piece.count <= 510) }
    }
}

@Suite("Streamed speech", .enabled(if: haveModels, "speech models not present"), .serialized)
struct StreamingTests {
    static let synth = try! SpeechSynthesizer(models: models)

    @Test func chunksTileTheLineWithOneGain() throws {
        let text = "Evening, love. A room costs three silver marks a night. Breakfast is extra."
        var chunks: [SpokenChunk] = []
        try Self.synth.stream(text, voice: "af_heart") { chunks.append($0) }
        #expect(chunks.count == 3)
        #expect(chunks.map(\.index) == [0, 1, 2])
        #expect(chunks.last?.isLast == true && chunks.dropLast().allSatisfy { !$0.isLast })
        var t = 0.0
        for c in chunks {
            #expect(abs(c.startTime - t) < 1e-9, "chunks are contiguous")
            for v in c.visemes { #expect(v.start >= c.startTime - 1e-6 && v.end <= c.startTime + c.duration + 1e-6) }
            t += c.duration
        }
        // One line gain (the peak guard may only lower it).
        #expect(chunks.dropFirst().allSatisfy { $0.gainDB <= chunks[0].gainDB + 1e-9 })
        let peak = chunks.flatMap(\.pcm).map(abs).max() ?? 0
        #expect(20 * log10(Double(peak)) <= -1.0 + 1e-3, "peak ceiling")
        // Sentence padding is trimmed: the streamed line times like whole-line synthesis.
        let whole = try Self.synth.speak(text, voice: "af_heart")
        #expect(abs(t - whole.duration) < 0.15 * whole.duration, "streamed \(t) s vs whole \(whole.duration) s")
        // Whole-line integrated loudness lands near the -23 LUFS target.
        let m = Loudness.measure(chunks.flatMap(\.pcm), sampleRate: chunks[0].sampleRate)
        #expect(abs(m.integratedLUFS + 23) < 3, "\(m.integratedLUFS) LUFS")
    }

    @Test func stopsWhenCancelled() throws {
        var count = 0
        try Self.synth.stream("One sentence here. Another sentence there. And a third one.", voice: "af_heart",
                              isCancelled: { count >= 1 }) { _ in count += 1 }
        #expect(count == 1)
    }
}
