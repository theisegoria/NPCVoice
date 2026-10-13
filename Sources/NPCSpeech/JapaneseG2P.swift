// Japanese grapheme-to-phoneme for Kokoro.
//
// Provenance: a port of misaki 0.9.4 `cutlet.py` (Apple-2.0 misaki; the cutlet alphabet
// Kokoro's Japanese voices were trained with), using misaki's exported kana table and
// word list (third_party/models/misaki-ja). MeCab + UniDic-lite (~250 MB) is replaced by
// macOS's own Japanese morphological analysis (CFStringTokenizer, Latin transcription),
// with fix-ups that turn its readings into UniDic's *pronunciation* forms: topic
// particles は/へ/を -> わ/え/お, and おう/うう/えい -> ー except at verb/adjective endings.
// Parity against misaki is measured in Tests/NPCSpeechTests (tools/make_ja_golden.py).
import Foundation

public final class JapaneseG2P: @unchecked Sendable {
    private let table: [String: String]
    private let words: Set<String>

    public convenience init(directory: URL) throws {
        let table = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appending(path: "hepburn.json")))
        let words = try String(contentsOf: directory.appending(path: "ja_words.txt"), encoding: .utf8)
        self.init(table: table, words: Set(words.split(separator: "\n").map(String.init)))
    }

    init(table: [String: String], words: Set<String>) {
        self.table = table
        self.words = words
    }

    struct Word { var surface: String; var hira: String; var charType: Int }

    static let sokuonSpaces = try! NSRegularExpression(pattern: #"(?<![!",.:;?»—…”]) (?=ʔ)|(?<=ʔ) (?!["«“])"#)   // 6 = kana-mapped word, 3 = symbol, 5 = ascii

    private let overrideLock = NSLock()
    private var overrides: [String: String] = [:]

    /// `overrides`: author pronunciations (surface -> misaki phonemes) for names and coinages.
    public func phonemize(_ text: String, overrides: [String: String] = [:]) -> String {
        overrideLock.lock(); defer { overrideLock.unlock() }
        self.overrides = overrides
        defer { self.overrides = [:] }
        return phonemizeLocked(text)
    }

    private func phonemizeLocked(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let normalized = normalize(text)
        let tokens = romajiTokens(segment(normalized))
        var out = tokens.map { $0.surface + ($0.space ? " " : "") }.joined()
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/\s+/, with: " ")
            .replacingOccurrences(of: "(", with: "«").replacingOccurrences(of: ")", with: "»")
        // Swift Regex has no lookbehind; ICU does.
        out = Self.sokuonSpaces.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        return out
    }

    // MARK: - Normalisation (cutlet._normalize_text)

    func normalize(_ text: String) -> String {
        var t = text.replacing(/[〜～](?=\d)/, with: "から")
        let ext: [Character: Character] = ["ㇰ": "ク", "ㇱ": "シ", "ㇲ": "ス", "ㇳ": "ト", "ㇴ": "ヌ", "ㇵ": "ハ", "ㇶ": "ヒ", "ㇷ": "フ",
                                           "ㇸ": "ヘ", "ㇹ": "ホ", "ㇺ": "ム", "ㇻ": "ラ", "ㇼ": "リ", "ㇽ": "ル", "ㇾ": "レ", "ㇿ": "ロ"]
        t = String(t.map { ext[$0] ?? $0 })
        t = t.precomposedStringWithCompatibilityMapping          // NFKC: full-width ASCII -> half, half-width kana -> full
        var out = "", digits = ""
        func flush() { if !digits.isEmpty { out += " " + JapaneseNumbers.reading(digits); digits = "" } }
        for c in t { if c.isASCII && c.isNumber { digits.append(c) } else { flush(); out.append(c) } }
        flush()
        return out
    }

    // MARK: - Segmentation + readings (replaces MeCab/UniDic)

    func segment(_ text: String) -> [Word] {
        let ns = text as NSString
        let cf = text as CFString
        let tok = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)), kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var out: [Word] = []
        var at = 0
        func gap(_ upTo: Int) {
            guard upTo > at else { return }
            for c in ns.substring(with: NSRange(location: at, length: upTo - at)) {
                if c.isWhitespace { out.append(Word(surface: " ", hira: " ", charType: 3)); continue }
                out.append(Word(surface: String(c), hira: String(c), charType: c.isASCII ? (c.isLetter ? 5 : 3) : 3))
            }
        }
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            gap(r.location)
            let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
            at = r.location + r.length
            if surface.allSatisfy({ $0.isASCII }) {
                out.append(Word(surface: surface, hira: surface, charType: surface.allSatisfy(\.isLetter) ? 5 : 3)); continue
            }
            if surface.allSatisfy({ Self.isKana($0) }) {
                out.append(Word(surface: surface, hira: Self.pronunciation(surface: surface, reading: Self.kataToHira(surface)), charType: 6)); continue
            }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String ?? ""
            let reading = Self.latinToHiragana(latin)
            out.append(Word(surface: surface, hira: Self.pronunciation(surface: surface, reading: reading), charType: reading.isEmpty ? 3 : 6))
        }
        gap(ns.length)
        return out
    }

    static func isKana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3040...0x30FF).contains($0.value) }
    }

    static func kataToHira(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { (0x30A1...0x30F6).contains($0.value) ? Unicode.Scalar($0.value - 0x60)! : $0 }))
    }

    /// Apple's Latin transcription -> hiragana; macron long vowels become ー.
    static func latinToHiragana(_ latin: String) -> String {
        // Keep "'" (separates ん from a vowel or n: fun'iki, an'nai) and "~" (sokuon,
        // "ma~tsu" = まっ); the ICU transform handles both.
        var s = latin
        for (m, v) in [("ā", "a"), ("ī", "i"), ("ū", "u"), ("ē", "e"), ("ō", "o")] { s = s.replacingOccurrences(of: m, with: v + "-") }
        let h = s.applyingTransform(.latinToHiragana, reverse: false) ?? ""
        return h.replacingOccurrences(of: "-", with: "ー")
    }

    static let fixedReadings = ["こんにちは": "こんにちわ", "こんばんは": "こんばんわ"]

    /// UniDic pronunciation form: particles and long vowels.
    static func pronunciation(surface: String, reading: String) -> String {
        if let fixed = fixedReadings[surface] { return fixed }
        switch surface {
        case "は": return "わ"
        case "へ": return "え"
        case "を": return "お"
        default: break
        }
        // Long vowels (おう/うう -> oー/uー, えい -> eー) inside a word, but not a final
        // う/い that is okurigana of a verb or adjective (思う, 美しい).
        let chars = Array(reading)
        guard chars.count >= 2 else { return reading }
        // Only kanji + う okurigana marks a verb ending (思う); pure-kana words lengthen
        // everywhere (ようこそ, でしょう, いい).
        let hasKanji = surface.contains { !isKana($0) }
        let protectLast = hasKanji && surface.last == "う"   // UniDic lengthens final い (欲しい -> ホシー) but not verb う
        var out: [Character] = [chars[0]]
        for i in 1..<chars.count {
            let c = chars[i]
            let isLast = i == chars.count - 1
            if c == "お", vowel(of: out.last!) == "o" { out.append("ー"); continue }          // おお -> oː (大きな)
            if c == "あ", vowel(of: out.last!) == "a" { out.append("ー"); continue }          // まあ -> maː
            if c == "え", vowel(of: out.last!) == "e" { out.append("ー"); continue }          // ねえ -> neː
            if (c == "う" || c == "い") && !(isLast && protectLast), let v = vowel(of: out.last!) {
                if (c == "う" && (v == "o" || v == "u")) || (c == "い" && (v == "e" || v == "i")) { out.append("ー"); continue }
            }
            out.append(c)
        }
        return String(out)
    }

    static func vowel(of kana: Character) -> Character? {
        let rows: [(String, Character)] = [("あかさたなはまやらわがざだばぱぁゃ", "a"), ("いきしちにひみりぎじぢびぴぃ", "i"),
                                           ("うくすつぬふむゆるぐずづぶぷぅゅ", "u"), ("えけせてねへめれげぜでべぺぇ", "e"),
                                           ("おこそとのほもよろをごぞどぼぽぉょ", "o")]
        for (set, v) in rows where set.contains(kana) { return v }
        return nil
    }

    // MARK: - cutlet._romaji_tokens / _romaji_word / _get_single_mapping

    struct Token { var surface: String; var space: Bool }

    func romajiTokens(_ input: [Word]) -> [Token] {
        // Group consecutive same-type words whose concatenation is a known word.
        var grouped: [Word] = []
        var i = 0
        while i < input.count {
            let z = (i + 1..<input.count).first { input[$0].charType != input[i].charType } ?? input.count
            if let j = stride(from: z, to: i, by: -1).first(where: { let w = input[i..<$0].map(\.surface).joined(); return words.contains(w) || overrides[w] != nil }) {
                grouped.append(Word(surface: input[i..<j].map(\.surface).joined(), hira: input[i..<j].map(\.hira).joined(), charType: input[i].charType))
                i = j
            } else { grouped.append(input[i]); i += 1 }
        }
        var out: [Token] = []
        for w in grouped {
            let roma = romajiWord(w)
            var tok = Token(surface: roma, space: false)
            if "「『«".contains(w.surface) || roma == "(" || roma == "[" {
                if !out.isEmpty { out[out.count - 1].space = true }
            } else if "」』»".contains(w.surface) || ["]", ")", ".", ",", "?", "!", ":"].contains(roma) {
                if !out.isEmpty { out[out.count - 1].space = false }
                tok.space = true
            } else if roma == " " {
                tok.space = false
            } else {
                tok.space = true
            }
            out.append(tok)
        }
        for k in out.indices { out[k].surface = out[k].surface.replacingOccurrences(of: "っ", with: "") }
        return out
    }

    func romajiWord(_ w: Word) -> String {
        if let o = overrides[w.surface] { return o }
        if w.surface.allSatisfy(\.isASCII) { return w.surface }
        // Symbols: mapped punctuation, ASCII as-is, anything else (――, ・, ♪) is silent like misaki.
        if w.charType == 3 { return String(w.surface.map { table[String($0)] ?? ($0.isASCII ? String($0) : "") }.joined()) }
        if w.charType != 6 { return "" }
        let hira = Array(w.hira)
        var out = ""
        for k in hira.indices {
            out += mapping(k > 0 ? hira[k - 1] : nil, hira[k], k < hira.count - 1 ? hira[k + 1] : nil)
        }
        return out
    }

    static let sutegana: Set<Character> = ["ゃ", "ゅ", "ょ", "ぁ", "ぃ", "ぅ", "ぇ", "ぉ"]
    static let odori: Set<Character> = ["〃", "々", "ゝ", "ゞ", "ヽ"]

    func mapping(_ pk: Character?, _ kk: Character, _ nk: Character?) -> String {
        if Self.odori.contains(kk) {
            if kk == "ゝ" || kk == "ヽ" { return pk.map { table[String($0)] ?? "" } ?? "" }
            return ""
        }
        if let pk, let v = table[String(pk) + String(kk)] { return v }
        if let nk, table[String(kk) + String(nk)] != nil { return "" }
        if let nk, Self.sutegana.contains(nk) {
            if kk == "っ" { return "" }
            guard let a = table[String(kk)], let b = table[String(nk)] else { return "" }
            return String(a.dropLast()) + b
        }
        if Self.sutegana.contains(kk) { return "" }
        if kk == "ー" { return "ː" }
        if kk == "っ" { return "ʔ" }
        if kk == "ん" {
            if let nk, let t = table[String(nk)], let f = t.first {
                if "mpb".contains(f) { return "m" }
                if "kɡ".contains(f) { return "ŋ" }
                if t.hasPrefix("ɲ") || t.hasPrefix("ʨ") || t.hasPrefix("ʥ") { return "ɲ" }
                if "ntdɾz".contains(f) { return "n" }
            }
            return "ɴ"
        }
        return table[String(kk)] ?? ""
    }
}

/// Kana readings for digit runs (misaki num2kana's role), with the usual sound changes.
enum JapaneseNumbers {
    static let digits = ["ぜろ", "いち", "に", "さん", "よん", "ご", "ろく", "なな", "はち", "きゅう"]

    static func reading(_ s: String) -> String {
        guard let n = Int(s) else { return s }
        if n == 0 { return "ぜろ" }
        var parts: [String] = []
        var rest = n
        for (value, name) in [(100_000_000, "おく"), (10_000, "まん")] where rest >= value {
            parts.append(below10000(rest / value) + name); rest %= value
        }
        if rest > 0 { parts.append(below10000(rest)) }
        return parts.joined()
    }

    static func below10000(_ n: Int) -> String {
        var s = ""
        let th = n / 1000, h = (n / 100) % 10, t = (n / 10) % 10, o = n % 10
        if th > 0 { s += [1: "せん", 3: "さんぜん", 8: "はっせん"][th] ?? digits[th] + "せん" }
        if h > 0 { s += [1: "ひゃく", 3: "さんびゃく", 6: "ろっぴゃく", 8: "はっぴゃく"][h] ?? digits[h] + "ひゃく" }
        if t > 0 { s += t == 1 ? "じゅう" : digits[t] + "じゅう" }
        if o > 0 { s += digits[o] }
        return s
    }
}
