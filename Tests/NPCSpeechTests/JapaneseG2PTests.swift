import Foundation
import Testing
@testable import NPCSpeech

private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite(.serialized) struct JapaneseG2PTests {
    static let g2p = try! JapaneseG2P(directory: root.appending(path: "third_party/models/misaki-ja"))
    static let golden = try! JSONDecoder().decode(G2PGolden.self, from: Data(contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "Fixtures/misaki-ja-golden.json")))

    /// Word-level parity with misaki (MeCab + UniDic); the native reader uses macOS's
    /// morphological analysis, so a few readings legitimately differ.
    @Test func parityWithMisaki() {
        var words = 0, matches = 0, exact = 0
        for l in Self.golden.lines {
            let got = Self.g2p.phonemize(l.text)
            if got == l.phonemes { exact += 1 }
            let w = l.phonemes.split(separator: " "), g = got.split(separator: " ")
            if w.count == g.count {
                for (a, b) in zip(w, g) { words += 1; if a == b { matches += 1 } else { print("  ≠ '\(b)' (misaki '\(a)') in \(l.text)") } }
            } else {
                words += w.count
                print("  segmentation \(g.count) vs \(w.count): \(l.text)\n    got:    \(got)\n    misaki: \(l.phonemes)")
            }
        }
        let rate = Double(matches) / Double(max(words, 1))
        print("Japanese G2P parity: \(matches)/\(words) words (\(String(format: "%.1f", rate * 100))%), \(exact)/\(Self.golden.lines.count) lines exact")
        #expect(rate >= 0.97)   // 100% on the 150-line corpus as of 2026-10-12
    }

    @Test func numbersReadNaturally() {
        #expect(JapaneseNumbers.reading("3000") == "さんぜん")
        #expect(JapaneseNumbers.reading("800") == "はっぴゃく")
        #expect(JapaneseNumbers.reading("12345") == "いちまんにせんさんびゃくよんじゅうご")
    }
}
