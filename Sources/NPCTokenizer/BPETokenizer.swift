// Byte-level BPE tokenizer for Hugging Face `tokenizer.json` files of the GPT-2 /
// Qwen family (BPE model, NFC normalizer, Split(regex, Isolated) + ByteLevel
// pre-tokenizer, ByteLevel decoder). Dependency-free; verified token-for-token
// against the Python `tokenizers` library (Tests/NPCTokenizerTests).
import Foundation

public enum TokenizerLoadError: Error, CustomStringConvertible {
    case unsupported(String)
    case malformed(String)
    public var description: String {
        switch self {
        case .unsupported(let m): "unsupported tokenizer: \(m)"
        case .malformed(let m): "malformed tokenizer.json: \(m)"
        }
    }
}

public final class BPETokenizer: @unchecked Sendable {
    public struct AddedToken: Sendable {
        public let id: Int
        public let content: String
        public let special: Bool
    }

    public let vocabSize: Int
    public let addedTokens: [AddedToken]

    private let vocab: [String: Int]
    private let idToToken: [Int: String]
    private let mergeRanks: [String: Int]          // "left\u{1}right" -> rank
    private let splitter: NSRegularExpression
    private let addedSplitter: NSRegularExpression?
    private let addedByContent: [String: AddedToken]
    private let addedByID: [Int: AddedToken]
    private let byteToChar: [Character]             // GPT-2 bytes_to_unicode
    private let charToByte: [Character: UInt8]

    private let cacheLock = NSLock()
    private var cache: [String: [Int]] = [:]

    public convenience init(directory: URL) throws {
        try self.init(tokenizerJSON: Data(contentsOf: directory.appending(path: "tokenizer.json")))
    }

    public init(tokenizerJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any] else { throw TokenizerLoadError.malformed("no model") }
        guard model["type"] as? String == "BPE" else { throw TokenizerLoadError.unsupported("model type \(model["type"] ?? "nil")") }
        if (model["byte_fallback"] as? Bool) == true { throw TokenizerLoadError.unsupported("byte_fallback") }
        if let n = root["normalizer"] as? [String: Any], n["type"] as? String != "NFC" {
            throw TokenizerLoadError.unsupported("normalizer \(n["type"] ?? "nil")")
        }

        guard let v = model["vocab"] as? [String: Int] else { throw TokenizerLoadError.malformed("vocab") }
        vocab = v
        var inverse = [Int: String](minimumCapacity: v.count)
        for (k, id) in v { inverse[id] = k }

        var ranks = [String: Int]()
        guard let merges = model["merges"] as? [Any] else { throw TokenizerLoadError.malformed("merges") }
        ranks.reserveCapacity(merges.count)
        for (rank, m) in merges.enumerated() {
            if let pair = m as? [String], pair.count == 2 { ranks[pair[0] + "\u{1}" + pair[1]] = rank }
            else if let s = m as? String, let space = s.firstIndex(of: " ") {
                ranks[String(s[..<space]) + "\u{1}" + String(s[s.index(after: space)...])] = rank
            } else { throw TokenizerLoadError.malformed("merge \(rank)") }
        }
        mergeRanks = ranks

        // Pre-tokenizer: Sequence[Split(regex, Isolated), ByteLevel(use_regex: false)].
        guard let pre = root["pre_tokenizer"] as? [String: Any],
              let steps = pre["pretokenizers"] as? [[String: Any]],
              let split = steps.first(where: { $0["type"] as? String == "Split" }),
              let pattern = (split["pattern"] as? [String: Any])?["Regex"] as? String,
              split["behavior"] as? String == "Isolated",
              steps.contains(where: { $0["type"] as? String == "ByteLevel" }) else {
            throw TokenizerLoadError.unsupported("pre_tokenizer (expects Split[Isolated] + ByteLevel)")
        }
        splitter = try NSRegularExpression(pattern: pattern)

        var added: [AddedToken] = []
        for a in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? Int, let content = a["content"] as? String else { continue }
            added.append(AddedToken(id: id, content: content, special: a["special"] as? Bool ?? false))
            inverse[id] = content
        }
        addedTokens = added
        addedByContent = Dictionary(added.map { ($0.content, $0) }, uniquingKeysWith: { a, _ in a })
        addedByID = Dictionary(added.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Longest first, so "<|im_start|>" wins over any shorter prefix.
        let alternation = added.map(\.content).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        addedSplitter = alternation.isEmpty ? nil : try NSRegularExpression(pattern: alternation.joined(separator: "|"))
        idToToken = inverse
        vocabSize = (inverse.keys.max() ?? -1) + 1

        // GPT-2 bytes_to_unicode.
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var table = [Character](repeating: " ", count: 256)
        var back = [Character: UInt8]()
        for (b, c) in zip(bs, cs) {
            let ch = Character(Unicode.Scalar(UInt32(c))!)
            table[b] = ch
            back[ch] = UInt8(b)
        }
        byteToChar = table
        charToByte = back
    }

    // MARK: Encoding

    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        for (segment, isAdded) in splitAdded(text) {
            if isAdded, let t = addedByContent[segment] { ids.append(t.id); continue }
            let normalized = segment.precomposedStringWithCanonicalMapping
            for word in preTokenize(normalized) { ids.append(contentsOf: bpe(word)) }
        }
        return ids
    }

    public func tokenID(_ token: String) -> Int? { addedByContent[token]?.id ?? vocab[token] }
    public func token(_ id: Int) -> String? { idToToken[id] }
    public func isSpecial(_ id: Int) -> Bool { addedByID[id]?.special ?? false }

    /// Splits around added tokens (matched literally, before normalization).
    private func splitAdded(_ text: String) -> [(String, Bool)] {
        guard let re = addedSplitter else { return [(text, false)] }
        let ns = text as NSString
        var out: [(String, Bool)] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { out.append((ns.substring(with: NSRange(location: last, length: m.range.location - last)), false)) }
            out.append((ns.substring(with: m.range), true))
            last = m.range.location + m.range.length
        }
        if last < ns.length { out.append((ns.substring(from: last), false)) }
        return out
    }

    /// Split(regex, Isolated): matches and the gaps between them are both pieces.
    private func preTokenize(_ text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var last = 0
        for m in splitter.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            if m.range.location > last { pieces.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
            pieces.append(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        if last < ns.length { pieces.append(ns.substring(from: last)) }
        // ByteLevel: each UTF-8 byte becomes one printable character.
        return pieces.map { String($0.utf8.map { byteToChar[Int($0)] }) }
    }

    private func bpe(_ word: String) -> [Int] {
        cacheLock.lock()
        if let hit = cache[word] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        var parts = word.map(String.init)
        while parts.count > 1 {
            var best = Int.max, at = -1
            for i in 0..<(parts.count - 1) {
                if let r = mergeRanks[parts[i] + "\u{1}" + parts[i + 1]], r < best { best = r; at = i }
            }
            if at < 0 { break }
            // Merge every occurrence of the best pair, left to right.
            let left = parts[at], right = parts[at + 1]
            var merged: [String] = []
            merged.reserveCapacity(parts.count)
            var i = 0
            while i < parts.count {
                if i < parts.count - 1 && parts[i] == left && parts[i + 1] == right {
                    merged.append(left + right); i += 2
                } else {
                    merged.append(parts[i]); i += 1
                }
            }
            parts = merged
        }
        let ids = parts.compactMap { vocab[$0] }

        cacheLock.lock()
        if cache.count > 50_000 { cache.removeAll(keepingCapacity: true) }
        cache[word] = ids
        cacheLock.unlock()
        return ids
    }

    // MARK: Decoding

    public func decode(_ ids: [Int], skipSpecialTokens: Bool = false) -> String {
        var out = ""
        var bytes: [UInt8] = []
        func flush() {
            if !bytes.isEmpty { out += String(decoding: bytes, as: UTF8.self); bytes.removeAll(keepingCapacity: true) }
        }
        for id in ids {
            if let added = addedByID[id] {
                if skipSpecialTokens && added.special { continue }
                flush()
                out += added.content
            } else if let t = idToToken[id] {
                for ch in t { if let b = charToByte[ch] { bytes.append(b) } }
            }
        }
        flush()
        return out
    }
}

/// Qwen ChatML prompt rendering (the chat_template.jinja behaviour for text-only
/// system/user/assistant messages, no tools).
public enum QwenChatTemplate {
    public struct Message: Sendable {
        public var role: String
        public var content: String
        public init(role: String, content: String) { self.role = role; self.content = content }
    }

    public enum TemplateError: Error { case systemNotFirst, unknownRole(String), noUserMessage }

    public static func render(_ messages: [Message], addGenerationPrompt: Bool = true, enableThinking: Bool = false) throws -> String {
        guard messages.contains(where: { $0.role == "user" }) else { throw TemplateError.noUserMessage }
        var lastQuery = messages.count - 1
        for (i, m) in messages.enumerated().reversed() where m.role == "user" { lastQuery = i; break }
        var s = ""
        for (i, m) in messages.enumerated() {
            let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.role {
            case "system":
                guard i == 0 else { throw TemplateError.systemNotFirst }
                s += "<|im_start|>system\n" + content + "<|im_end|>\n"
            case "user":
                s += "<|im_start|>user\n" + content + "<|im_end|>\n"
            case "assistant":
                var body = content, reasoning = ""
                if let close = body.range(of: "</think>") {
                    reasoning = String(body[..<close.lowerBound])
                    if let open = reasoning.range(of: "<think>", options: .backwards) { reasoning = String(reasoning[open.upperBound...]) }
                    reasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    body = String(body[close.upperBound...]).replacing(/^\n+/, with: "")
                }
                if i > lastQuery {
                    s += "<|im_start|>assistant\n<think>\n" + reasoning + "\n</think>\n\n" + body
                } else {
                    s += "<|im_start|>assistant\n" + body
                }
                s += "<|im_end|>\n"
            default:
                throw TemplateError.unknownRole(m.role)
            }
        }
        if addGenerationPrompt {
            s += "<|im_start|>assistant\n" + (enableThinking ? "<think>\n" : "<think>\n\n</think>\n\n")
        }
        return s
    }
}
