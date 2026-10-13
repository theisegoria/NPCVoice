// Model phoneme timeline -> ARPAbet segments -> visemes, for lip-sync in any engine.
import Foundation

/// The 39 CMU/ARPAbet phonemes plus long silence ("sil") and short pause ("sp").
public enum ARPAbet: String, CaseIterable, Sendable, Codable {
    case AA, AE, AH, AO, AW, AY, B, CH, D, DH, EH, ER, EY, F, G, HH, IH, IY, JH, K,
         L, M, N, NG, OW, OY, P, R, S, SH, T, TH, UH, UW, V, W, Y, Z, ZH
    case silence = "sil", pause = "sp"

    public var isVowel: Bool {
        switch self {
        case .AA, .AE, .AH, .AO, .AW, .AY, .EH, .ER, .EY, .IH, .IY, .OW, .OY, .UH, .UW: true
        default: false
        }
    }
}

/// The 15 visemes (Oculus/ARKit-style names).
public enum Viseme: String, CaseIterable, Sendable, Codable {
    case silence = "sil", PP, FF, TH, DD, kk, CH, SS, RR, aa, E, ih, oh, ou, Y
}

public enum LexicalStress: String, Sendable, Codable { case unspecified, unstressed, primary, secondary }

public struct PhonemeSegment: Sendable, Equatable, Codable {
    public var phoneme: ARPAbet
    public var start: Double            // seconds
    public var end: Double
    public var stress: LexicalStress
    public var source: String           // the model symbols this segment came from
}

public struct VisemeSegment: Sendable, Equatable, Codable {
    public var viseme: Viseme
    public var start: Double
    public var end: Double
    public var weight: Float            // dominance scale (HH and short pauses are light)
}

public enum SpeechLanguage: String, Sendable { case english = "en", japanese = "ja" }

public enum LipSync {
    public struct Settings: Sendable {
        public var pauseMinSeconds = 0.07     // shorter word gaps are absorbed by the preceding phone
        public var silenceMinSeconds = 0.15   // gap runs at least this long become "sil", not "sp"
        public var minSegmentSeconds = 0.005
        public init() {}
    }

    /// Diphthongs split into a nucleus and an off-glide at this fraction of the segment.
    public static let glideSplit = 0.6

    // MARK: Symbol classes (misaki alphabets)

    // Character sets, not string literals: a combining mark (U+0303) next to "ː" in a
    // literal would fuse into one grapheme and neither would match on its own.
    static let gaps: Set<Character> = [" ", ";", ":", ",", ".", "!", "?", "—", "…", "\"", "(", ")", "“", "”", "«", "»"]
    static let modifiers: Set<Character> = ["ː", "\u{0303}", "ʰ", "ʲ", "ᵝ", "↓", "→", "↗", "↘"]
    static func isGap(_ c: Character) -> Bool { gaps.contains(c) }
    static func isModifier(_ c: Character) -> Bool { modifiers.contains(c) }
    static func stressMark(_ c: Character) -> LexicalStress? { c == "ˈ" ? .primary : c == "ˌ" ? .secondary : nil }
    static func reducedVowel(_ c: Character) -> Bool { "əᵊᵻɐ".contains(c) }

    public static func phoneme(for c: Character, language: SpeechLanguage) -> ARPAbet? {
        switch c {
        case "b": return .B; case "d": return .D; case "f": return .F; case "h": return .HH; case "j": return .Y
        case "k": return .K; case "l": return .L; case "m": return .M; case "n": return .N; case "p": return .P
        case "s": return .S; case "t": return .T; case "v": return .V; case "w": return .W; case "z": return .Z
        case "ɡ": return .G; case "ŋ": return .NG; case "ʃ": return .SH; case "ʒ": return .ZH; case "ʤ": return .JH
        case "ʧ": return .CH; case "ɾ": return .D
        default: break
        }
        if language == .english {
            switch c {
            case "A": return .EY; case "I": return .AY; case "O": return .OW; case "W": return .AW; case "Y": return .OY; case "Q": return .OW
            case "æ": return .AE; case "ɑ", "ɒ": return .AA; case "ɔ": return .AO; case "ə", "ᵊ", "ɐ", "ʌ": return .AH
            case "ɛ": return .EH; case "ɜ", "ɚ": return .ER; case "ɪ", "ᵻ": return .IH; case "ʊ": return .UH
            case "i": return .IY; case "u": return .UW; case "a": return .AA; case "e": return .EH; case "o": return .AO
            case "ɹ": return .R; case "ð": return .DH; case "θ": return .TH; case "ʔ": return .T
            case "T": return .D   // misaki writes the flap ɾ as "T" for Kokoro v1.0
            default: return nil
            }
        }
        switch c {   // Japanese (misaki cutlet alphabet)
        case "a": return .AA; case "i": return .IY; case "ɯ", "u": return .UH; case "e": return .EH; case "o": return .AO
        case "ɨ": return .IH; case "ç": return .HH; case "ɸ", "β", "ɰ": return .W; case "ɕ": return .SH
        case "ʥ", "ʑ": return .JH; case "ʨ": return .CH; case "ʦ": return .S; case "ʣ": return .Z
        case "ɲ", "ɴ": return .N; case "ʝ": return .Y; case "ɟ": return .G; case "c": return .K
        default: return nil
        }
    }

    /// Phoneme -> viseme nucleus, optional off-glide, and dominance.
    public static func articulation(_ p: ARPAbet) -> (nucleus: Viseme, glide: Viseme?, weight: Float) {
        switch p {
        case .AA, .AH: (.aa, nil, 1); case .AE, .EH: (.E, nil, 1); case .AO: (.oh, nil, 1)
        case .AW: (.aa, .ou, 1); case .AY: (.aa, .ih, 1); case .EY: (.E, .ih, 1); case .OW: (.oh, .ou, 1); case .OY: (.oh, .ih, 1)
        case .B, .M, .P: (.PP, nil, 1); case .F, .V: (.FF, nil, 1); case .TH, .DH: (.TH, nil, 1)
        case .T, .D, .N, .L: (.DD, nil, 1); case .K, .G, .NG: (.kk, nil, 1); case .HH: (.kk, nil, 0.3)
        case .CH, .JH, .SH, .ZH: (.CH, nil, 1); case .S, .Z: (.SS, nil, 1); case .R, .ER: (.RR, nil, 1)
        case .IH, .IY: (.ih, nil, 1); case .UH, .UW, .W: (.ou, nil, 1); case .Y: (.Y, nil, 1)
        case .silence: (.silence, nil, 1); case .pause: (.silence, nil, 0.5)
        }
    }

    // MARK: Mapping

    struct Unit {
        var isPhone: Bool
        var hard = false
        var phoneme: ARPAbet = .silence
        var stress: LexicalStress = .unspecified
        var start: Int
        var end: Int
        var source = ""
    }

    /// Contiguous ARPAbet segments covering the whole line. Unknown symbols become gaps
    /// and are reported in `unknown`.
    public static func phonemes(from tokens: [TimedToken], language: SpeechLanguage, sampleRate: Double,
                                settings: Settings = .init(), unknown: inout [Character]) -> [PhonemeSegment] {
        var units: [Unit] = []
        var prefixStart: Int?
        var prefixSource = ""
        var pendingStress: LexicalStress?
        func pushGap(_ a: Int, _ b: Int, hard: Bool) {
            var a = a
            if let p = prefixStart { a = p; prefixStart = nil; prefixSource = "" }
            pendingStress = nil
            units.append(Unit(isPhone: false, hard: hard, start: a, end: b))
        }
        // Pass 1: classify. Stress marks and the sokuon donate their span to the next phone.
        for t in tokens {
            guard case .symbol(let c) = t.kind else { pushGap(t.startSample, t.endSample, hard: true); continue }
            if isGap(c) { pushGap(t.startSample, t.endSample, hard: false); continue }
            if let s = stressMark(c) {
                pendingStress = s
                if prefixStart == nil { prefixStart = t.startSample }
                prefixSource.append(c); continue
            }
            if language == .japanese && c == "ʔ" {
                if prefixStart == nil { prefixStart = t.startSample }
                prefixSource.append(c); continue
            }
            if isModifier(c) {
                if let last = units.last, last.isPhone, prefixStart == nil {
                    units[units.count - 1].end = t.endSample
                    units[units.count - 1].source.append(c)
                } else { pushGap(t.startSample, t.endSample, hard: false) }
                continue
            }
            guard let p = phoneme(for: c, language: language) else {
                unknown.append(c); pushGap(t.startSample, t.endSample, hard: false); continue
            }
            var u = Unit(isPhone: true, phoneme: p, start: prefixStart ?? t.startSample, end: t.endSample, source: prefixSource + String(c))
            if p.isVowel {
                if let s = pendingStress { u.stress = s; pendingStress = nil }
                else if language == .english && reducedVowel(c) { u.stress = .unstressed }
            }
            prefixStart = nil; prefixSource = ""
            units.append(u)
        }
        // Pass 2: Japanese moraic nasal assimilation (ɴ -> M before bilabials, NG before velars).
        if language == .japanese {
            for i in units.indices.dropLast() where units[i].isPhone && units[i].source.contains("ɴ") && units[i + 1].isPhone {
                switch units[i + 1].phoneme {
                case .P, .B, .M: units[i].phoneme = .M
                case .K, .G, .NG: units[i].phoneme = .NG
                default: break
                }
            }
        }
        // Pass 3: merge gap runs; short word gaps are absorbed by the preceding phone.
        var merged: [Unit] = []
        for u in units {
            if !u.isPhone, let last = merged.last, !last.isPhone {
                merged[merged.count - 1].end = u.end
                merged[merged.count - 1].hard = last.hard || u.hard
                continue
            }
            merged.append(u)
        }
        var out: [Unit] = []
        var i = 0
        while i < merged.count {
            var u = merged[i]
            if !u.isPhone {
                let seconds = Double(u.end - u.start) / sampleRate
                if u.hard || seconds >= settings.silenceMinSeconds { u.phoneme = .silence }
                else if seconds >= settings.pauseMinSeconds { u.phoneme = .pause }
                else if let last = out.last, last.isPhone { out[out.count - 1].end = u.end; i += 1; continue }
                else if i + 1 < merged.count { merged[i + 1].start = u.start; i += 1; continue }
                else { u.phoneme = .pause }
            }
            out.append(u)
            i += 1
        }
        // Pass 4: segments shorter than the minimum join a neighbour.
        var segments: [PhonemeSegment] = []
        i = 0
        while i < out.count {
            let u = out[i]
            let a = Double(u.start) / sampleRate, b = Double(u.end) / sampleRate
            if b - a < settings.minSegmentSeconds {
                if !segments.isEmpty { segments[segments.count - 1].end = b; segments[segments.count - 1].source += u.source; i += 1; continue }
                if i + 1 < out.count { out[i + 1].start = u.start; out[i + 1].source = u.source + out[i + 1].source; i += 1; continue }
            }
            segments.append(PhonemeSegment(phoneme: u.phoneme, start: a, end: b, stress: u.stress, source: u.source))
            i += 1
        }
        return segments
    }

    /// Viseme track: diphthongs split at `glideSplit`; adjacent equal visemes merge.
    public static func visemes(from phonemes: [PhonemeSegment]) -> [VisemeSegment] {
        var out: [VisemeSegment] = []
        func push(_ v: Viseme, _ a: Double, _ b: Double, _ w: Float) {
            if let last = out.last, last.viseme == v, last.weight == w, abs(last.end - a) < 1e-9 { out[out.count - 1].end = b; return }
            out.append(VisemeSegment(viseme: v, start: a, end: b, weight: w))
        }
        for p in phonemes {
            let art = articulation(p.phoneme)
            if let glide = art.glide {
                let split = p.start + (p.end - p.start) * glideSplit
                push(art.nucleus, p.start, split, art.weight)
                push(glide, split, p.end, art.weight)
            } else {
                push(art.nucleus, p.start, p.end, art.weight)
            }
        }
        return out
    }
}
