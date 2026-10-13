import Foundation
import Testing
@testable import NPCSpeech

private func tokens(_ phonemes: String, framesEach: Int = 4) -> [TimedToken] {
    var out = [TimedToken(kind: .begin, startSample: 0, endSample: 2400)]
    var at = 2400
    for c in phonemes { out.append(TimedToken(kind: .symbol(c), startSample: at, endSample: at + framesEach * 600)); at += framesEach * 600 }
    out.append(TimedToken(kind: .end, startSample: at, endSample: at + 2400))
    return out
}

@Suite struct LipSyncTests {
    @Test func japaneseExampleMatchesReference() {
        var unknown: [Character] = []
        let segs = LipSync.phonemes(from: tokens("ɡeɴɕiɾo no tobʲiɾa βa"), language: .japanese, sampleRate: 24000, unknown: &unknown)
        let phones = segs.map(\.phoneme).filter { $0 != .silence && $0 != .pause }.map(\.rawValue).joined(separator: " ")
        #expect(phones == "G EH N SH IY D AO N AO T AO B IY D AA W AA")
        #expect(unknown.isEmpty)
    }

    @Test func moraicNasalAssimilates() {
        var unknown: [Character] = []
        let segs = LipSync.phonemes(from: tokens("saɴba"), language: .japanese, sampleRate: 24000, unknown: &unknown)
        #expect(segs.map(\.phoneme).contains(.M))
    }

    @Test func englishStressAndCoverage() {
        var unknown: [Character] = []
        let toks = tokens("həlˈO wˈɜɹld.")
        let segs = LipSync.phonemes(from: toks, language: .english, sampleRate: 24000, unknown: &unknown)
        #expect(unknown.isEmpty)
        #expect(segs.first?.start == 0 && abs(segs.last!.end - Double(toks.last!.endSample) / 24000) < 1e-9)
        for (a, b) in zip(segs, segs.dropFirst()) { #expect(abs(a.end - b.start) < 1e-9) }
        #expect(segs.first { $0.phoneme == .OW }?.stress == .primary)
        let vis = LipSync.visemes(from: segs)
        #expect(vis.contains { $0.viseme == .oh } && vis.contains { $0.viseme == .ou }, "OW splits into nucleus and glide")
    }
}

@Suite struct LoudnessTests {
    static func sine(_ amp: Float, seconds: Double = 5, fs: Double = 48000) -> [Float] {
        (0..<Int(seconds * fs)).map { amp * sin(2 * .pi * 997 * Float($0) / Float(fs)) }
    }

    @Test func fullScaleSineIsMinus3LUFS() {
        let m = Loudness.measure(Self.sine(1), sampleRate: 48000)
        #expect(m.method == .gated)
        #expect(abs(m.integratedLUFS - -3.01) < 0.05, "\(m.integratedLUFS)")
    }

    @Test func normalisesToTarget() {
        var x = Self.sine(0.05, fs: 24000)
        Loudness.normalize(&x, sampleRate: 24000)
        #expect(abs(Loudness.measure(x, sampleRate: 24000).integratedLUFS - -23) < 0.05)
    }

    @Test func silenceIsUntouched() {
        var x = [Float](repeating: 0, count: 48000)
        let (m, gain) = Loudness.normalize(&x, sampleRate: 24000)
        #expect(m.method == .silent && gain == 0)
    }
}
