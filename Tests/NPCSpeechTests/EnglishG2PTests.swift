import Foundation
import Testing
@testable import NPCSpeech

private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct G2PGolden: Decodable { struct Line: Decodable { let text: String; let phonemes: String }; let lines: [Line] }

@Suite(.serialized) struct EnglishG2PTests {
    static let g2p = try! EnglishG2P(directory: root.appending(path: "third_party/models/misaki-en"))
    static let golden = try! JSONDecoder().decode(G2PGolden.self, from: Data(contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "Fixtures/misaki-en-golden.json")))

    /// Word-level parity with misaki, ignoring words misaki itself could not pronounce (❓).
    @Test func parityWithMisaki() {
        var words = 0, matches = 0, lines = 0, exactLines = 0
        for l in Self.golden.lines {
            let got = Self.g2p.phonemize(l.text).phonemes
            let w = l.phonemes.split(separator: " "), g = got.split(separator: " ")
            lines += 1
            if got == l.phonemes { exactLines += 1 }
            if w.count == g.count {
                for (a, b) in zip(w, g) where !a.contains("❓") { words += 1; if a == b { matches += 1 } else { print("  ≠ '\(b)' (misaki '\(a)') in: \(l.text)") } }
            } else {
                words += w.count
                print("  token count \(g.count) vs \(w.count): \(l.text)\n    got:    \(got)\n    misaki: \(l.phonemes)")
            }
        }
        let rate = Double(matches) / Double(words)
        print("English G2P parity: \(matches)/\(words) words (\(String(format: "%.1f", rate * 100))%), \(exactLines)/\(lines) lines exact")
        #expect(rate >= 0.95)
    }

    @Test func numbersAndCurrency() {
        #expect(NumberWords.year(1999) == "nineteen hundred and ninety-nine")
        #expect(NumberWords.year(1905) == "nineteen hundred and five")
        #expect(NumberWords.year(2010) == "two thousand and ten")
        #expect(NumberWords.year(1066) == "one thousand and sixty-six")
        #expect(NumberWords.ordinal(21) == "twenty-first")
        #expect(NumberWords.cardinal(2500) == "two thousand, five hundred")
        #expect(!Self.g2p.phonemize("It costs $3.50.").phonemes.contains("❓"))
    }

    @Test func authorOverridesWin() {
        let r = Self.g2p.phonemize("Ask Okafor, not okafor.", overrides: ["Okafor": "Okˈɑfɔɹ"])
        #expect(r.phonemes.components(separatedBy: "Okˈɑfɔɹ").count == 3, "both spellings use the override: \(r.phonemes)")
        #expect(r.unknownWords.isEmpty)
        #expect(Self.g2p.phonemize("Okafor").unknownWords == ["Okafor"], "overrides do not leak between calls")
    }

    @Test func unknownWordsAreSpelledNotDropped() {
        let r = Self.g2p.phonemize("Zyxquor waits.")
        #expect(r.unknownWords == ["Zyxquor"])
        #expect(!r.phonemes.contains("❓") && !r.phonemes.isEmpty)
    }
}
