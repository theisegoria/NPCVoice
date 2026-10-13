import Foundation
import Testing
@testable import NPCTokenizer

/// Parity with Hugging Face `tokenizers` + chat_template.jinja (fixtures from
/// tools/make_tokenizer_golden.py). Needs the vendored model folder.
private let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let modelDir = root.appending(path: "third_party/models/qwen3.5-2b-4bit")
private let haveModel = FileManager.default.fileExists(atPath: modelDir.appending(path: "tokenizer.json").path)

struct Golden: Decodable {
    struct Encoding: Decodable { let text: String; let ids: [Int]; let decoded: String }
    struct Message: Decodable { let role: String; let content: String }
    struct Chat: Decodable { let messages: [Message]; let text: String; let ids: [Int] }
    let encodings: [Encoding]
    let chat: [Chat]
}

@Suite(.enabled(if: haveModel, "Qwen model folder not present"), .serialized)
struct QwenTokenizerParity {
    static let tokenizer = try! BPETokenizer(directory: modelDir)
    static let golden = try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "Fixtures/qwen3.5-golden.json")))

    @Test func encodingsMatchHuggingFace() {
        for e in Self.golden.encodings {
            #expect(Self.tokenizer.encode(e.text) == e.ids, "\(e.text.debugDescription)")
        }
    }

    @Test func decodingRoundTrips() {
        for e in Self.golden.encodings {
            #expect(Self.tokenizer.decode(e.ids) == e.decoded, "\(e.text.debugDescription)")
        }
    }

    @Test func chatTemplateMatchesJinja() throws {
        for c in Self.golden.chat {
            let text = try QwenChatTemplate.render(c.messages.map { .init(role: $0.role, content: $0.content) })
            #expect(text == c.text)
            #expect(Self.tokenizer.encode(text) == c.ids)
        }
    }

    @Test func specialTokens() {
        let t = Self.tokenizer
        #expect(t.tokenID("<|im_end|>") != nil && t.isSpecial(t.tokenID("<|im_end|>")!))
        #expect(t.decode(t.encode("<|im_start|>user\nhi<|im_end|>"), skipSpecialTokens: true) == "user\nhi")
    }
}
