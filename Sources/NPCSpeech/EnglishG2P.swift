// English grapheme-to-phoneme for Kokoro (American English).
//
// Provenance: a port of misaki 0.9.4 `en.py` (Apache-2.0, the G2P Kokoro-82M was trained
// with) using misaki's own us_gold/us_silver lexicons. Two dependencies are replaced:
//  * spaCy (tokenizer + POS tagger) by a rule tokenizer and a small context tagger that
//    only produces the tags misaki branches on (DT, PRP, IN/TO, MD, CD, $, punctuation,
//    NNP, and NOUN/VERB hints for the ~790 homographs);
//  * num2words (LGPL) by NumberWords.
// Parity against misaki is measured in Tests/NPCSpeechTests (tools/make_g2p_golden.py).
// Words outside the lexicon are spelled with letter names and reported, instead of
// misaki's "❓".
import Foundation

public final class EnglishG2P: @unchecked Sendable {
    public struct Result: Sendable {
        public var phonemes: String
        /// Words that were not in the lexicon (spoken by spelling them out).
        public var unknownWords: [String]
    }

    enum Entry { case word(String), homograph([String: String?]) }

    private let golds: [String: Entry]
    private let silvers: [String: Entry]

    public convenience init(directory: URL) throws {
        try self.init(gold: Data(contentsOf: directory.appending(path: "us_gold.json")),
                      silver: Data(contentsOf: directory.appending(path: "us_silver.json")))
    }

    init(gold: Data, silver: Data) throws {
        golds = Self.grow(try Self.load(gold))
        silvers = Self.grow(try Self.load(silver))
    }

    private static func load(_ data: Data) throws -> [String: Entry] {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out = [String: Entry](minimumCapacity: raw.count)
        for (k, v) in raw {
            if let s = v as? String { out[k] = .word(s) }
            else if let d = v as? [String: Any] {
                var m: [String: String?] = [:]
                for (tag, p) in d { m[tag] = p as? String }
                out[k] = .homograph(m)
            }
        }
        return out
    }

    /// misaki Lexicon.grow_dictionary: add Capitalized / lowercase variants.
    private static func grow(_ d: [String: Entry]) -> [String: Entry] {
        var e: [String: Entry] = [:]
        for (k, v) in d where k.count >= 2 {
            if k == k.lowercased() {
                if k != pyCapitalize(k) { e[pyCapitalize(k)] = v }
            } else if k == pyCapitalize(k.lowercased()) {
                e[k.lowercased()] = v
            }
        }
        return e.merging(d) { _, new in new }
    }

    // MARK: - Public entry point

    private let overrideLock = NSLock()
    private var overrides: [String: String] = [:]

    /// `overrides`: author pronunciations (word -> misaki phonemes); exact word first, then lowercase.
    public func phonemize(_ text: String, overrides: [String: String] = [:]) -> Result {
        overrideLock.lock(); defer { overrideLock.unlock() }
        self.overrides = overrides
        defer { self.overrides = [:] }
        return phonemizeLocked(text)
    }

    private func phonemizeLocked(_ text: String) -> Result {
        var unknown: [String] = []
        let tokens = Self.tag(Self.tokenize(text.trimmingCharacters(in: .whitespaces)))
        var words = retokenize(tokens)
        var ctx = Context()
        for i in words.indices.reversed() {
            switch words[i] {
            case .single(var w):
                if w.phonemes == nil {
                    (w.phonemes, w.rating) = lexicon(w, ctx)
                    if w.phonemes == nil { w.phonemes = spell(w.text); unknown.append(w.text) }
                }
                ctx = Self.tokenContext(ctx, w.phonemes, w)
                words[i] = .single(w)
            case .group(var w):
                var left = 0, right = w.count
                while left < right {
                    var merged: Tok?
                    if !w[left..<right].contains(where: { $0.alias != nil || $0.phonemes != nil }) {
                        merged = Self.merge(Array(w[left..<right]), unk: nil)
                    }
                    let (ps, rating) = merged.map { lexicon($0, ctx) } ?? (nil, nil)
                    if let ps {
                        w[left].phonemes = ps; w[left].rating = rating
                        for x in (left + 1)..<right { w[x].phonemes = ""; w[x].rating = rating }
                        ctx = Self.tokenContext(ctx, ps, merged!)
                        right = left; left = 0
                    } else if left + 1 < right {
                        left += 1
                    } else {
                        right -= 1
                        if w[right].phonemes == nil {
                            if w[right].text.allSatisfy({ Self.subtokenJunks.contains($0) }) {
                                w[right].phonemes = ""; w[right].rating = 3
                            } else {
                                w[right].phonemes = spell(w[right].text); unknown.append(w[right].text)
                            }
                        }
                        left = 0
                    }
                }
                Self.resolve(&w)
                words[i] = .group(w)
            }
        }
        let merged = words.map { w -> Tok in
            switch w { case .single(let t): t; case .group(let g): Self.merge(g, unk: "❓") }
        }
        var out = ""
        for t in merged {
            var p = t.phonemes ?? "❓"
            p = p.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
            out += p + t.whitespace
        }
        return Result(phonemes: out, unknownWords: unknown)
    }

    // MARK: - Tokens

    struct Tok {
        var text: String
        var tag: String
        var whitespace: String
        var phonemes: String?
        var rating: Int?
        var isHead = true
        var alias: String?
        var stress: Double?
        var currency: String?
        var prespace = false
    }

    enum Word { case single(Tok), group([Tok]) }

    struct Context { var futureVowel: Bool?; var futureTo = false }

    static let subtokenJunks: Set<Character> = ["'", ",", "-", ".", "_", "‘", "’", "/"]
    static let puncts: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…", "\"", "“", "”"]
    static let nonQuotePuncts: Set<Character> = [";", ":", ",", ".", "!", "?", "—", "…"]
    static let punctTags: Set<String> = [".", ",", "-LRB-", "-RRB-", "``", "\"\"", "''", ":", "$", "#", "NFP"]
    static let punctTagPhonemes = ["-LRB-": "(", "-RRB-": ")", "``": "\u{201C}", "\"\"": "\u{201D}", "''": "\u{201D}"]
    static let consonants = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    static let vowels = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let usTaus = Set("AIOWYiuæɑəɛɪɹʊʌ")
    static let diphthongs = Set("AIOQWYʤʧ")
    static let primary: Character = "ˈ", secondary: Character = "ˌ"
    static let currencies = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]
    static let ordinals: Set<String> = ["st", "nd", "rd", "th"]
    static let addSymbols = [".": "dot", "/": "slash"]
    static let symbols = ["%": "percent", "&": "and", "+": "plus", "@": "at"]

    // MARK: - Tokenizer (spaCy-like) and context tagger

    static let prefixChars: Set<Character> = ["\"", "“", "‘", "(", "[", "{", "$", "£", "€", "«", "'"]
    static let suffixChars: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "”", "’", "»", "…", "'"]
    static let contractions = ["n't", "'s", "'m", "'re", "'ve", "'ll", "'d", "’s", "’m", "’re", "’ve", "’ll", "’d", "n’t"]

    static func tokenize(_ text: String) -> [Tok] {
        var tokens: [Tok] = []
        var chunk = "", ws = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            var pieces = splitChunk(chunk)
            pieces[pieces.count - 1].whitespace = ws
            tokens.append(contentsOf: pieces)
            chunk = ""; ws = ""
        }
        for c in text {
            if c.isWhitespace { ws.append(c) }
            else { if !ws.isEmpty { flush() }; chunk.append(c) }
        }
        flush()
        return tokens
    }

    private static func splitChunk(_ chunk: String) -> [Tok] {
        var s = Substring(chunk)
        var pre: [String] = [], suf: [String] = []
        while let f = s.first, prefixChars.contains(f), s.count > 1 { pre.append(String(f)); s = s.dropFirst() }
        while s.count > 1 {
            if s.hasSuffix("...") { suf.insert("...", at: 0); s = s.dropLast(3); continue }
            if let l = s.last, suffixChars.contains(l) {
                // Keep abbreviation-like single letters with a period ("U.S.") together.
                if l == ".", s.dropLast().contains(".") && s.dropLast().last?.isLetter == true && s.count <= 5 { break }
                suf.insert(String(l), at: 0); s = s.dropLast(); continue
            }
            break
        }
        var middle: [String] = []
        if let c = contractions.first(where: { s.lowercased().hasSuffix($0) && s.count > $0.count }) {
            middle = [String(s.dropLast(c.count)), String(s.suffix(c.count))]
        } else { middle = [String(s)] }
        // Infixes: em dash and ellipsis split words; hyphens between letters split too.
        var parts: [String] = []
        for m in middle {
            var cur = ""
            let chars = Array(m)
            for (i, ch) in chars.enumerated() {
                let hyphen = ch == "-" && i > 0 && i < chars.count - 1 && chars[i - 1].isLetter && chars[i + 1].isLetter
                if ch == "—" || ch == "–" || ch == "…" || hyphen {
                    if !cur.isEmpty { parts.append(cur); cur = "" }
                    parts.append(String(ch))
                } else { cur.append(ch) }
            }
            if !cur.isEmpty { parts.append(cur) }
        }
        return (pre + parts + suf).filter { !$0.isEmpty }.map { Tok(text: $0, tag: "", whitespace: "") }
    }

    static let determiners: Set<String> = ["a", "an", "the", "this", "that", "these", "those", "every", "each", "some", "any", "no",
                                          "my", "your", "his", "her", "its", "our", "their", "another", "which", "what"]
    static let subjects: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "who"]
    static let modals: Set<String> = ["will", "would", "can", "could", "should", "must", "may", "might", "shall", "do", "does", "did",
                                      "'ll", "'d", "n't", "to"]
    static let prepositions: Set<String> = ["in", "on", "at", "by", "for", "from", "with", "of", "into", "over", "under", "about",
                                            "after", "before", "through", "between", "near", "without", "since", "until", "like"]
    static let pronouns: Set<String> = ["i", "you", "he", "she", "it", "we", "they", "me", "him", "us", "them"]

    /// The Penn tags misaki branches on; everything else is left as "" (DEFAULT reading).
    static func tag(_ tokens: [Tok]) -> [Tok] {
        var out = tokens
        var sentenceStart = true
        for i in out.indices {
            let t = out[i].text, l = t.lowercased()
            let prev = i > 0 ? out[i - 1].text.lowercased() : ""
            var tag = ""
            if t.count == 1, let c = t.first, currencies[t] != nil, !c.isLetter { tag = "$" }
            else if [".", "!", "?", "...", "…"].contains(t) { tag = "." }
            else if t == "," { tag = "," }
            else if [";", ":", "—", "–", "-"].contains(t) { tag = ":" }
            else if t == "(" || t == "[" { tag = "-LRB-" } else if t == ")" || t == "]" { tag = "-RRB-" }
            else if t == "“" { tag = "``" } else if t == "”" { tag = "''" }
            else if t == "\"" { tag = i == 0 || out[i - 1].whitespace != "" ? "``" : "''" }   // attached to the previous token = closing
            else if t.first?.isNumber == true { tag = "CD" }
            else if determiners.contains(l) && !(l == "that" && i + 1 < out.count && pronouns.contains(out[i + 1].text.lowercased())) { tag = "DT" }
            else if l == "to" { tag = "TO" }
            else if pronouns.contains(l) { tag = "PRP" }
            else if prepositions.contains(l) { tag = "IN" }
            else if ["will", "would", "can", "could", "should", "must", "may", "might", "shall"].contains(l) { tag = "MD" }
            else if t.first?.isUppercase == true && !sentenceStart && t != "I" && t.dropFirst().contains(where: \.isLowercase) { tag = "NNP" }
            else if determiners.contains(prev) || prev == "'s" || prev == "’s" { tag = "NN" }
            else if sentenceStart && t.first?.isUppercase == true { tag = "VB" }   // NPC lines open with imperatives ("Close the door")
            else if modals.contains(prev) || subjects.contains(prev) { tag = "VB" }
            out[i].tag = tag
            sentenceStart = tag == "." || (sentenceStart && (tag == "``" || tag == "-LRB-"))
        }
        return out
    }

    // MARK: - misaki G2P.retokenize / merge / resolve

    func retokenize(_ tokens: [Tok]) -> [Word] {
        var words: [Word] = []
        var currency: String?
        for (i, token) in tokens.enumerated() {
            var tks: [Tok]
            if token.alias == nil && token.phonemes == nil {
                tks = Self.subtokenize(token.text).map { Tok(text: $0, tag: token.tag, whitespace: "", stress: token.stress) }
                if tks.isEmpty { tks = [Tok(text: token.text, tag: token.tag, whitespace: "")] }
            } else { tks = [token] }
            tks[tks.count - 1].whitespace = token.whitespace
            for j in tks.indices {
                var tk = tks[j]
                if tk.alias != nil || tk.phonemes != nil {
                } else if tk.tag == "$" && Self.currencies[tk.text] != nil {
                    currency = tk.text; tk.phonemes = ""; tk.rating = 4
                } else if tk.tag == ":" && (tk.text == "-" || tk.text == "–") {
                    tk.phonemes = "—"; tk.rating = 3
                } else if Self.punctTags.contains(tk.tag) && !tk.text.lowercased().allSatisfy({ $0 >= "a" && $0 <= "z" }) {
                    tk.phonemes = Self.punctTagPhonemes[tk.tag] ?? String(tk.text.filter { Self.puncts.contains($0) })
                    tk.rating = 4
                } else if let cur = currency {
                    if tk.tag != "CD" { currency = nil }
                    else if j + 1 == tks.count && (i + 1 == tokens.count || tokens[i + 1].tag != "CD") { tk.currency = cur }
                } else if j > 0 && j < tks.count - 1 && tk.text == "2",
                          let a = tks[j - 1].text.last, let b = tks[j + 1].text.first, a.isLetter && b.isLetter {
                    tk.alias = "to"
                }
                if tk.alias != nil || tk.phonemes != nil {
                    words.append(.single(tk))
                } else if case .group(var g)? = words.last, g.last!.whitespace.isEmpty {
                    tk.isHead = false
                    g.append(tk)
                    words[words.count - 1] = .group(g)
                } else {
                    words.append(tk.whitespace.isEmpty ? .group([tk]) : .single(tk))
                }
            }
        }
        return words.map { w in if case .group(let g) = w, g.count == 1 { return .single(g[0]) }; return w }
    }

    private static let subtokenRegex = try! NSRegularExpression(pattern:
        #"^['‘’]+|\p{Lu}(?=\p{Lu}\p{Ll})|(?:^-)?(?:\d?[,.]?\d)+|[-_]+|['‘’]{2,}|\p{L}*?(?:['‘’]\p{L})*?\p{Ll}(?=\p{Lu})|\p{L}+(?:['‘’]\p{L})*|[^-_\p{L}'‘’\d]|['‘’]+$"#)

    static func subtokenize(_ word: String) -> [String] {
        let ns = word as NSString
        return subtokenRegex.matches(in: word, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func merge(_ tokens: [Tok], unk: String?) -> Tok {
        let stresses = Set(tokens.compactMap(\.stress))
        var phonemes: String?
        if let unk {
            var p = ""
            for tk in tokens {
                if tk.prespace, let last = p.last, !last.isWhitespace, let tp = tk.phonemes, !tp.isEmpty { p += " " }
                p += tk.phonemes ?? unk
            }
            phonemes = p
        }
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens.last!.text
        let tag = tokens.max { a, b in
            a.text.reduce(0) { $0 + ($1.isLowercase || !$1.isLetter ? 1 : 2) } < b.text.reduce(0) { $0 + ($1.isLowercase || !$1.isLetter ? 1 : 2) }
        }!.tag
        let currency = tokens.compactMap(\.currency).max()
        var t = Tok(text: text, tag: tag, whitespace: tokens.last!.whitespace, phonemes: phonemes)
        t.isHead = tokens[0].isHead
        t.stress = stresses.count == 1 ? stresses.first : nil
        t.currency = currency
        t.prespace = tokens[0].prespace
        t.rating = tokens.contains { $0.rating == nil } ? nil : tokens.compactMap(\.rating).min()
        return t
    }

    static func stressWeight(_ ps: String?) -> Int {
        guard let ps else { return 0 }
        return ps.reduce(0) { $0 + (diphthongs.contains($1) ? 2 : 1) }
    }

    static func resolve(_ tokens: inout [Tok]) {
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + tokens.last!.text
        let classes = Set(text.filter { !subtokenJunks.contains($0) }.map { $0.isLetter ? 0 : ($0.isNumber ? 1 : 2) })
        let prespace = text.contains(" ") || text.contains("/") || classes.count > 1
        for i in tokens.indices {
            if tokens[i].phonemes == nil {
                if i == tokens.count - 1, tokens[i].text.count == 1, nonQuotePuncts.contains(tokens[i].text.first!) {
                    tokens[i].phonemes = tokens[i].text; tokens[i].rating = 3
                } else if tokens[i].text.allSatisfy({ subtokenJunks.contains($0) }) {
                    tokens[i].phonemes = ""; tokens[i].rating = 3
                }
            } else if i > 0 { tokens[i].prespace = prespace }
        }
        if prespace { return }
        var idx = tokens.enumerated().compactMap { i, t -> (Bool, Int, Int)? in
            guard let p = t.phonemes, !p.isEmpty else { return nil }
            return (p.contains(primary), stressWeight(p), i)
        }
        if idx.count == 2 && tokens[idx[0].2].text.count == 1 {
            let i = idx[1].2
            tokens[i].phonemes = applyStress(tokens[i].phonemes, -0.5)
            return
        } else if idx.count < 2 || idx.filter(\.0).count <= (idx.count + 1) / 2 {
            return
        }
        idx.sort { a, b in a.0 != b.0 ? !a.0 : a.1 != b.1 ? a.1 < b.1 : a.2 < b.2 }
        for (_, _, i) in idx.prefix(idx.count / 2) { tokens[i].phonemes = applyStress(tokens[i].phonemes, -0.5) }
    }

    static func tokenContext(_ ctx: Context, _ ps: String?, _ token: Tok) -> Context {
        var vowel = ctx.futureVowel
        if let ps, !ps.isEmpty {
            for c in ps where vowels.contains(c) || consonants.contains(c) || nonQuotePuncts.contains(c) {
                vowel = nonQuotePuncts.contains(c) ? nil : vowels.contains(c)
                break
            }
        }
        let futureTo = token.text == "to" || token.text == "To" || (token.text == "TO" && (token.tag == "TO" || token.tag == "IN"))
        return Context(futureVowel: vowel, futureTo: futureTo)
    }

    // MARK: - Stress

    static func applyStress(_ ps: String?, _ stress: Double?) -> String? {
        guard let ps else { return nil }
        guard let stress else { return ps }
        let hasP = ps.contains(primary), hasS = ps.contains(secondary)
        func restress(_ s: String) -> String {
            var items = Array(s).enumerated().map { (Double($0.offset), $0.element) }
            for (k, item) in items.enumerated() where item.1 == primary || item.1 == secondary {
                if let j = items[k...].first(where: { vowels.contains($0.1) }) { items[k].0 = j.0 - 0.5 }
            }
            return String(items.sorted { $0.0 < $1.0 }.map(\.1))
        }
        if stress < -1 { return ps.filter { $0 != primary && $0 != secondary } }
        if stress == -1 || ((stress == 0 || stress == -0.5) && hasP) {
            return String(ps.filter { $0 != secondary }.map { $0 == primary ? secondary : $0 })
        }
        if (stress == 0 || stress == 0.5 || stress == 1) && !hasP && !hasS {
            if !ps.contains(where: { vowels.contains($0) }) { return ps }
            return restress(String(secondary) + ps)
        }
        if stress >= 1 && !hasP && hasS { return String(ps.map { $0 == secondary ? primary : $0 }) }
        if stress > 1 && !hasP && !hasS {
            if !ps.contains(where: { vowels.contains($0) }) { return ps }
            return restress(String(primary) + ps)
        }
        return ps
    }

    // MARK: - Lexicon (misaki Lexicon)

    static func parentTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        if tag.hasPrefix("VB") { return "VERB" }
        if tag.hasPrefix("NN") { return "NOUN" }
        if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
        if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
        return tag
    }

    static let lexiconOrds: Set<UInt32> = Set([39, 45] + Array(65...90) + Array(97...122))

    private func goldWord(_ k: String) -> String? { if case .word(let s)? = golds[k] { return s }; return nil }

    func getNNP(_ word: String) -> (String?, Int?) {
        var parts: [String] = []
        for c in word where c.isLetter {
            guard let p = goldWord(String(c).uppercased()) else { return (nil, nil) }
            parts.append(p)
        }
        guard var ps = Self.applyStress(parts.joined(), 0) else { return (nil, nil) }
        if let r = ps.lastIndex(of: Self.secondary) { ps.replaceSubrange(r...r, with: String(Self.primary)) }
        return (ps, 3)
    }

    func specialCase(_ word: String, _ tag: String, _ stress: Double?, _ ctx: Context) -> (String?, Int?) {
        if tag == "ADD", let w = Self.addSymbols[word] { return lookup(w, nil, -0.5, ctx) }
        if let w = Self.symbols[word] { return lookup(w, nil, nil, ctx) }
        let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if stripped.contains("."), word.replacingOccurrences(of: ".", with: "").allSatisfy(\.isLetter),
           (word.split(separator: ".").map(\.count).max() ?? 0) < 3 { return getNNP(word) }
        switch word {
        case "a", "A": return (tag == "DT" ? "ɐ" : "ˈA", 4)
        case "am", "Am", "AM":
            if tag.hasPrefix("NN") { return getNNP(word) }
            if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 { return (goldWord("am"), 4) }
            return ("ɐm", 4)
        case "an", "An", "AN":
            if word == "AN" && tag.hasPrefix("NN") { return getNNP(word) }
            return ("ɐn", 4)
        default: break
        }
        if word == "I" && tag == "PRP" { return ("\(Self.secondary)I", 4) }
        if ["by", "By", "BY"].contains(word) && Self.parentTag(tag) == "ADV" { return ("bˈI", 4) }
        if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
            switch ctx.futureVowel { case nil: return (goldWord("to"), 4); case false?: return ("tə", 4); case true?: return ("tʊ", 4) }
        }
        if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
            return ((ctx.futureVowel == nil || tag != "IN" ? String(Self.primary) : "") + "ɪn", 4)
        }
        if word == "the" || word == "The" || (word == "THE" && tag == "DT") { return (ctx.futureVowel == true ? "ði" : "ðə", 4) }
        if tag == "IN", word.range(of: #"^(?i)vs\.?$"#, options: .regularExpression) != nil { return lookup("versus", nil, nil, ctx) }
        if ["used", "Used", "USED"].contains(word), case .homograph(let h)? = golds["used"] {
            if (tag == "VBD" || tag == "JJ") && ctx.futureTo { return ((h["VBD"] ?? nil), 4) }
            return ((h["DEFAULT"] ?? nil), 4)
        }
        return (nil, nil)
    }

    func isKnown(_ word: String, _ tag: String) -> Bool {
        if golds[word] != nil || Self.symbols[word] != nil || silvers[word] != nil { return true }
        if !word.allSatisfy(\.isLetter) || !word.unicodeScalars.allSatisfy({ Self.lexiconOrds.contains($0.value) }) { return false }
        if word.count == 1 { return true }
        if word == word.uppercased() && golds[word.lowercased()] != nil { return true }
        let rest = String(word.dropFirst())
        return rest == rest.uppercased()
    }

    func lookup(_ word0: String, _ tag0: String?, _ stress: Double?, _ ctx: Context?) -> (String?, Int?) {
        var word = word0, tag = tag0
        var isNNP: Bool?
        if word == word.uppercased() && golds[word] == nil {
            word = word.lowercased()
            isNNP = tag == "NNP"
        }
        var entry = golds[word], rating = 4
        if entry == nil && isNNP != true { entry = silvers[word]; rating = 3 }
        var ps: String?
        switch entry {
        case .word(let s)?: ps = s
        case .homograph(let h)?:
            if let ctx, ctx.futureVowel == nil, h.keys.contains("None") { tag = "None" }
            else if tag == nil || h[tag!] == nil { tag = Self.parentTag(tag) }
            ps = (tag.flatMap { h[$0] } ?? h["DEFAULT"]) ?? nil
        case nil: ps = nil
        }
        if ps == nil || (isNNP == true && !ps!.contains(Self.primary)) {
            let (p, r) = getNNP(word)
            if p != nil { return (p, r) }
        }
        return (Self.applyStress(ps, stress), rating)
    }

    func suffixS(_ stem: String?) -> String? {
        guard let stem, let l = stem.last else { return nil }
        if "ptkfθ".contains(l) { return stem + "s" }
        if "szʃʒʧʤ".contains(l) { return stem + "ᵻz" }
        return stem + "z"
    }

    func stemS(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String?, Int?) {
        guard word.count >= 3, word.hasSuffix("s") else { return (nil, nil) }
        let t = tag ?? ""
        var stem: String
        if !word.hasSuffix("ss") && isKnown(String(word.dropLast()), t) { stem = String(word.dropLast()) }
        else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies"))) && isKnown(String(word.dropLast(2)), t) {
            stem = String(word.dropLast(2))
        } else if word.count > 4 && word.hasSuffix("ies") && isKnown(String(word.dropLast(3)) + "y", t) {
            stem = String(word.dropLast(3)) + "y"
        } else { return (nil, nil) }
        let (p, r) = lookup(stem, tag, stress, ctx)
        return (suffixS(p), r)
    }

    func suffixED(_ stem: String?) -> String? {
        guard let stem, let l = stem.last else { return nil }
        if "pkfθʃsʧ".contains(l) { return stem + "t" }
        if l == "d" { return stem + "ᵻd" }
        if l != "t" { return stem + "d" }
        if stem.count < 2 { return stem + "ɪd" }
        if Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) { return String(stem.dropLast()) + "ɾᵻd" }
        return stem + "ᵻd"
    }

    func stemED(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String?, Int?) {
        guard word.count >= 4, word.hasSuffix("d") else { return (nil, nil) }
        let t = tag ?? ""
        var stem: String
        if !word.hasSuffix("dd") && isKnown(String(word.dropLast()), t) { stem = String(word.dropLast()) }
        else if word.count > 4 && word.hasSuffix("ed") && !word.hasSuffix("eed") && isKnown(String(word.dropLast(2)), t) { stem = String(word.dropLast(2)) }
        else { return (nil, nil) }
        let (p, r) = lookup(stem, tag, stress, ctx)
        return (suffixED(p), r)
    }

    func suffixING(_ stem: String?) -> String? {
        guard let stem else { return nil }
        if stem.count > 1 && stem.last == "t" && Self.usTaus.contains(stem[stem.index(stem.endIndex, offsetBy: -2)]) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    func stemING(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: Context?) -> (String?, Int?) {
        guard word.count >= 5, word.hasSuffix("ing") else { return (nil, nil) }
        let t = tag ?? ""
        let base = String(word.dropLast(3))
        var stem: String
        if word.count > 5 && isKnown(base, t) { stem = base }
        else if isKnown(base + "e", t) { stem = base + "e" }
        else if word.count > 5, word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil,
                isKnown(String(word.dropLast(4)), t) { stem = String(word.dropLast(4)) }
        else { return (nil, nil) }
        let (p, r) = lookup(stem, tag, stress, ctx)
        return (suffixING(p), r)
    }

    func getWord(_ word0: String, _ tag: String, _ stress: Double?, _ ctx: Context) -> (String?, Int?) {
        let sc = specialCase(word0, tag, stress, ctx)
        if sc.0 != nil { return sc }
        var word = word0
        let wl = word.lowercased()
        let rest = String(word.dropFirst())
        if word.count > 1, word.replacingOccurrences(of: "'", with: "").allSatisfy(\.isLetter), word != wl,
           tag != "NNP" || word.count > 7, golds[word] == nil, silvers[word] == nil,
           word == word.uppercased() || rest == rest.lowercased(),
           golds[wl] != nil || silvers[wl] != nil
            || stemS(wl, tag, stress, ctx).0 != nil || stemED(wl, tag, stress, ctx).0 != nil || stemING(wl, tag, stress, ctx).0 != nil {
            word = wl
        }
        if isKnown(word, tag) { return lookup(word, tag, stress, ctx) }
        if word.hasSuffix("s'") && isKnown(String(word.dropLast(2)) + "'s", tag) { return lookup(String(word.dropLast(2)) + "'s", tag, stress, ctx) }
        if word.hasSuffix("'") && isKnown(String(word.dropLast()), tag) { return lookup(String(word.dropLast()), tag, stress, ctx) }
        let s = stemS(word, tag, stress, ctx); if s.0 != nil { return s }
        let ed = stemED(word, tag, stress, ctx); if ed.0 != nil { return ed }
        let ing = stemING(word, tag, stress ?? 0.5, ctx); if ing.0 != nil { return ing }
        return (nil, nil)
    }

    // MARK: - Numbers

    static func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" } }
    static func isDigits(_ s: String) -> Bool { isDigits(Substring(s)) }

    static func isNumber(_ word0: String, isHead: Bool) -> Bool {
        guard word0.contains(where: { $0 >= "0" && $0 <= "9" }) else { return false }
        var word = word0
        for s in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where word.hasSuffix(s) { word = String(word.dropLast(s.count)); break }
        return word.enumerated().allSatisfy { i, c in (c >= "0" && c <= "9") || c == "," || c == "." || (isHead && i == 0 && c == "-") }
    }

    func getNumber(_ word0: String, currency: String?, isHead: Bool) -> (String?, Int?) {
        var word = word0
        var suffix: String?
        if let r = word.range(of: #"[a-z']+$"#, options: .regularExpression) { suffix = String(word[r]); word.removeSubrange(r) }
        var result: [(String, Int)] = []
        if word.hasPrefix("-") { if let p = lookup("minus", nil, nil, nil).0 { result.append((p, 4)) }; word.removeFirst() }
        func extend(_ words: String) {
            for w in words.split(whereSeparator: { !($0 >= "a" && $0 <= "z") }).map(String.init) where w != "and" {
                let (p, r) = lookup(w, nil, w == "point" ? -2 : nil, nil)
                if let p { result.append((p, r ?? 4)) }
            }
        }
        if Self.isDigits(word), let suffix, Self.ordinals.contains(suffix) {
            extend(NumberWords.ordinal(Int(word) ?? 0))
        } else if result.isEmpty && word.count == 4 && Self.currencies[currency ?? ""] == nil && Self.isDigits(word) {
            extend(NumberWords.year(Int(word)!))
        } else if !isHead && !word.contains(".") {
            let num = word.replacingOccurrences(of: ",", with: "")
            if num.first == "0" || num.count > 3 { for d in num { extend(NumberWords.cardinal(Int(String(d)) ?? 0)) } }
            else if num.count == 3 && !num.hasSuffix("00") {
                let ds = Array(num)
                extend(NumberWords.cardinal(Int(String(ds[0]))!))
                if ds[1] == "0" { if let p = lookup("O", nil, -2, nil).0 { result.append((p, 4)) }; extend(NumberWords.cardinal(Int(String(ds[2]))!)) }
                else { extend(NumberWords.cardinal(Int(String(ds[1...]))!)) }
            } else { extend(NumberWords.cardinal(Int(num) ?? 0)) }
        } else if word.filter({ $0 == "." }).count > 1 || !isHead {
            for num in word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: true) {
                if num.first == "0" || (num.count != 2 && num.dropFirst().contains(where: { $0 != "0" })) {
                    for d in num { extend(NumberWords.cardinal(Int(String(d))!)) }
                } else { extend(NumberWords.cardinal(Int(num)!)) }
            }
        } else if let cur = currency, let units = Self.currencies[cur], Self.isCurrency(word) {
            var pairs = zip(word.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 },
                            [units.0, units.1]).map { ($0, $1) }
            if pairs.count > 1 { if pairs[1].0 == 0 { pairs = [pairs[0]] } else if pairs[0].0 == 0 { pairs = [pairs[1]] } }
            for (k, (n, unit)) in pairs.enumerated() {
                if k > 0, let p = lookup("and", nil, nil, nil).0 { result.append((p, 4)) }
                extend(NumberWords.cardinal(n))
                let u = abs(n) != 1 && unit != "pence" ? stemS(unit + "s", nil, nil, nil).0 : lookup(unit, nil, nil, nil).0
                if let u { result.append((u, 4)) }
            }
        } else {
            if Self.isDigits(word) { extend(NumberWords.cardinal(Int(word) ?? 0)) }
            else if !word.contains(".") { let n = Int(word.replacingOccurrences(of: ",", with: "")) ?? 0
                extend(suffix.map { Self.ordinals.contains($0) } == true ? NumberWords.ordinal(n) : NumberWords.cardinal(n)) }
            else {
                let w = word.replacingOccurrences(of: ",", with: "")
                if w.first == "." { extend("point " + w.dropFirst().map { NumberWords.cardinal(Int(String($0))!) }.joined(separator: " ")) }
                else { extend(NumberWords.decimal(w)) }
            }
        }
        guard !result.isEmpty else { return (nil, nil) }
        let joined = result.map(\.0).joined(separator: " ")
        let rating = result.map(\.1).min()
        switch suffix {
        case "s", "'s": return (suffixS(joined), rating)
        case "ed", "'d": return (suffixED(joined), rating)
        case "ing": return (suffixING(joined), rating)
        default: return (joined, rating)
        }
    }

    static func isCurrency(_ word: String) -> Bool {
        guard word.contains(".") else { return true }
        if word.filter({ $0 == "." }).count > 1 { return false }
        let cents = word.split(separator: ".", omittingEmptySubsequences: false)[1]
        return cents.count < 3 || Set(cents) == ["0"]
    }

    func appendCurrency(_ ps: String, _ currency: String?) -> String {
        guard let currency, let units = Self.currencies[currency], let c = stemS(units.0 + "s", nil, nil, nil).0 else { return ps }
        return "\(ps) \(c)"
    }

    // MARK: - Lexicon.__call__

    func lexicon(_ tk: Tok, _ ctx: Context) -> (String?, Int?) {
        var word = (tk.alias ?? tk.text).replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        word = word.precomposedStringWithCompatibilityMapping
        if let o = overrides[word] ?? overrides.first(where: { $0.key.lowercased() == word.lowercased() })?.value { return (o, 5) }
        let stress: Double? = word == word.lowercased() ? nil : (word == word.uppercased() ? 2 : 0.5)
        let (ps, rating) = getWord(word, tk.tag, stress, ctx)
        if let ps { return (Self.applyStress(appendCurrency(ps, tk.currency), tk.stress), rating) }
        if Self.isNumber(word, isHead: tk.isHead) {
            let (p, r) = getNumber(word, currency: tk.currency, isHead: tk.isHead)
            return (Self.applyStress(p, tk.stress), r)
        }
        return (nil, nil)
    }

    /// Out-of-lexicon words (mostly invented names): split into the fewest lexicon pieces
    /// of two or more letters ("Saltwren" -> salt + wren, "Tamsin" -> tam + sin) and keep
    /// one primary stress; spell with letter names only if no split exists.
    func spell(_ word: String) -> String {
        let letters = Array(word.lowercased().filter(\.isLetter))
        guard !letters.isEmpty else { return "" }
        let n = letters.count
        // best[i]: fewest pieces covering letters[0..<i]; pieces of 2-12 letters.
        var best = [Int](repeating: .max, count: n + 1), back = [Int](repeating: -1, count: n + 1)
        var piecePS = [String?](repeating: nil, count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i] != .max && n - i >= 2 {
            for len in 2...min(12, n - i) {
                let piece = String(letters[i..<(i + len)])
                guard let ps = plainPronunciation(piece) else { continue }
                if best[i] + 1 < best[i + len] { best[i + len] = best[i] + 1; back[i + len] = i; piecePS[i + len] = ps }
            }
        }
        guard best[n] != .max, best[n] <= max(2, n / 3) else { return getNNP(String(letters)).0 ?? "" }
        var parts: [String] = [], at = n
        while at > 0 { parts.insert(piecePS[at]!, at: 0); at = back[at] }
        // One primary stress, on the first piece that has one; the rest secondary.
        var seenPrimary = false
        return parts.map { p in
            String(p.map { c -> Character in
                guard c == Self.primary else { return c }
                if seenPrimary { return Self.secondary }
                seenPrimary = true; return c
            })
        }.joined()
    }

    /// A plain (non-homograph) gold or silver pronunciation for a lowercase piece.
    private func plainPronunciation(_ piece: String) -> String? {
        for dict in [golds, silvers] {
            if case .word(let s)? = dict[piece] { return s }
            if case .homograph(let h)? = dict[piece], let d = h["DEFAULT"] ?? nil { return d }
        }
        return nil
    }
}

/// misaki Python's str.capitalize(): first character upper, the rest lower.
func pyCapitalize(_ s: String) -> String {
    guard let f = s.first else { return s }
    return String(f).uppercased() + s.dropFirst().lowercased()
}
