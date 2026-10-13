// MLX open-weight dialogue backend: Qwen3.5-2B 4-bit, in process on the GPU.
//
// Drives MLXGuidedGeneration (xgrammar) directly with NPCVoice's own JSON Schema
// rather than going through the FoundationModels adapter: property order is fixed
// (text first, so the line is written before its labels), and the closing reserves
// are sized for short spoken lines. Decoding is greedy (the guided loop samples by
// argmax), so seeds and temperature are ignored and identical prompts give
// identical lines.
import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import NPCKit
import NPCTokenizer

public final class MLXBackend: DialogueModelBackend, @unchecked Sendable {
    public let modelDirectory: URL
    public let name: String
    public let contextTokens = 8192          // what NPCVoice budgets for; Qwen3.5 supports far more
    public let guidedGeneration = true

    private let loader: ModelLoader

    /// `cacheMB`: MLX's reusable-buffer cache (process-wide). Small keeps the model near
    /// 2.5 GB beside a game; default `$NPCVOICE_MLX_CACHE_MB` or 256.
    public init(modelDirectory: URL, cacheMB: Int? = nil) {
        self.modelDirectory = modelDirectory
        name = "mlx:\(modelDirectory.lastPathComponent)"
        let mb = cacheMB ?? Int(ProcessInfo.processInfo.environment["NPCVOICE_MLX_CACHE_MB"] ?? "") ?? 256
        loader = ModelLoader(directory: modelDirectory, cacheMB: mb)
    }

    /// Drops the weights and MLX's buffer cache; the next request reloads them (~1-2 s).
    public func unload() {
        let loader = loader
        Task.detached { await loader.unload() }
    }

    /// The bundled model: inside the app/framework bundle, `$NPCVOICE_MODELS`, or the
    /// repository's third_party folder during development.
    public static func defaultModelDirectory() -> URL? {
        let name = "qwen3.5-2b-4bit"
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NPCVOICE_MODELS"] { candidates.append(URL(filePath: env).appending(path: name)) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appending(path: "Models/\(name)")) }
        // The CLI: a Models folder beside the executable, then the installed app's models.
        if let exe = Bundle.main.executableURL { candidates.append(exe.deletingLastPathComponent().appending(path: "Models/\(name)")) }
        candidates.append(URL(filePath: "/Applications/NPCVoice.app/Contents/Resources/Models/\(name)"))
        #if DEBUG
        // Development checkouts only; release binaries must not embed source paths.
        var dir = URL(filePath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }   // Sources/NPCMLX/MLXBackend.swift -> repo
        candidates.append(dir.appending(path: "third_party/models/\(name)"))
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0.appending(path: "config.json").path) }
    }

    /// Weights are local, so the model is available whenever its files are present.
    public func availability() -> BackendAvailability {
        let fm = FileManager.default
        let ok = ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
            fm.fileExists(atPath: modelDirectory.appending(path: $0).path)
        }
        return ok ? .available : .modelNotReady
    }

    public func supports(_ language: Language) -> Bool { true }

    /// Loads the weights (about 1.7 GB) and builds the grammar vocabulary ahead of the first line.
    public func preload() async throws { _ = try await loader.load() }

    /// Loads the weights and runs one tiny constrained generation, so the first real line
    /// doesn't pay MLX's one-time Metal shader compilation (~3-5 s).
    public func warmUp() async throws {
        try await preload()
        let start = ContinuousClock.now
        let req = BackendRequest(instructions: "You greet people briefly.", prompt: "Say hello.",
                                 schema: OutputSchema(emotions: [.neutral], intents: [.greet]), language: .english, maxOutputTokens: 8)
        _ = await generate(req)
        NPCLog.info("\(name): warmed up in \(Self.ms(ContinuousClock.now - start)) ms")
    }

    static func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }

    public func prewarm(instructions: String) {
        let loader = loader
        Task.detached(priority: .utility) { _ = try? await loader.load() }
    }

    /// Tells the model what the constrained JSON fields mean (the system model gets
    /// this from FoundationModels' includeSchemaInPrompt).
    static func formatInstructions(_ r: BackendRequest) -> String {
        let ja = r.language == .japanese
        var s = "Answer only with JSON: {\"text\": " + (ja ? "the line you speak, in Japanese" : "the line you speak") +
            ", \"emotion\": one of " + r.schema.emotions.map(\.rawValue).joined(separator: "/") +
            ", \"intent\": one of " + r.schema.intents.map(\.rawValue).joined(separator: "/")
        if !r.schema.commands.isEmpty && r.schema.maxCommands > 0 {
            s += ", \"commands\": usually [], or actions from: " + r.schema.commands.map { c in
                c.kind + (c.targets.isEmpty ? "" : " (target: " + c.targets.joined(separator: "/") + ")") + " = " + c.description
            }.joined(separator: "; ")
        }
        return s + "}"
    }

    public func generate(_ request: BackendRequest) async -> BackendResponse {
        let loaded: Loaded
        do { loaded = try await loader.load() }
        catch { return BackendResponse(status: .unavailable, diagnostic: "model load failed: \(error)") }
        if Task.isCancelled { return BackendResponse(status: .cancelled) }

        let schemaJSON = DialogueJSONSchema.make(request.schema)
        let prompt: String
        do {
            prompt = try QwenChatTemplate.render([
                .init(role: "system", content: request.instructions + "\n" + Self.formatInstructions(request)),
                .init(role: "user", content: request.prompt),
            ])
        } catch { return BackendResponse(status: .error, diagnostic: "template: \(error)") }
        let promptIDs = loaded.bpe.encode(prompt)
        if ProcessInfo.processInfo.environment["NPCVOICE_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[npcvoice] schema: \(schemaJSON)\n[npcvoice] prompt tokens: \(promptIDs.count)\n".utf8))
        }

        let maxOutput = request.maxOutputTokens
        do {
            let result: (String, Int) = try await loaded.container.perform { context in
                let constraint = try GrammarConstraint(
                    tokenizer: loaded.grammarTokenizer, jsonSchema: schemaJSON,
                    fastForward: true, hostTokenizer: context.tokenizer)
                let structural = CompletionReserve.estimate(schemaJSON: schemaJSON, tokenizer: context.tokenizer)
                var output = ""
                // One generation at a time on the GPU.
                let count = try loaded.runLock.withLock { try GuidedGenerationLoop.run(
                    input: LMInput(tokens: MLXArray(promptIDs.map(Int32.init))),
                    context: context,
                    constraint: constraint,
                    maxTokens: maxOutput + structural * 2,
                    vocabSize: Int(loaded.grammarTokenizer.vocabSize),
                    completionReserve: structural * 2,
                    hardReserve: structural,
                    closingBias: loaded.closingBias,
                    whitespaceBias: loaded.whitespaceBias,
                    whitespaceTokenIDs: loaded.whitespaceTokenIDs
                ) { text in
                    output += text
                    return !Task.isCancelled
                } }
                return (output, count)
            }
            if Task.isCancelled { return BackendResponse(status: .cancelled) }
            if ProcessInfo.processInfo.environment["NPCVOICE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[npcvoice] raw: \(result.0)\n".utf8))
            }
            return BackendResponse(status: .ok, json: result.0, promptTokens: promptIDs.count, outputTokens: result.1)
        } catch GuidedGenerationError.incompleteOutput {
            return BackendResponse(status: .decodingFailure, diagnostic: "ran out of tokens before the JSON closed")
        } catch {
            return BackendResponse(status: Task.isCancelled ? .cancelled : .error, diagnostic: "\(error)")
        }
    }
}

// MARK: - Loading

/// Everything built once per model: weights, tokenizer, grammar vocabulary, biases.
final class Loaded: @unchecked Sendable {
    let container: ModelContainer
    let bpe: BPETokenizer
    let grammarTokenizer: GrammarTokenizer
    let closingBias: MLXArray
    let whitespaceBias: MLXArray
    let whitespaceTokenIDs: Set<Int>
    let runLock = NSLock()

    init(container: ModelContainer, bpe: BPETokenizer, grammarTokenizer: GrammarTokenizer,
         closingBias: MLXArray, whitespaceBias: MLXArray, whitespaceTokenIDs: Set<Int>) {
        self.container = container; self.bpe = bpe; self.grammarTokenizer = grammarTokenizer
        self.closingBias = closingBias; self.whitespaceBias = whitespaceBias; self.whitespaceTokenIDs = whitespaceTokenIDs
    }
}

actor ModelLoader {
    let directory: URL
    let cacheMB: Int
    private var task: Task<Loaded, Error>?

    init(directory: URL, cacheMB: Int) { self.directory = directory; self.cacheMB = cacheMB }

    /// Inside a plugin bundle (e.g. Unity's NPCVoiceKit.bundle: Contents/MacOS/<binary>), the
    /// metallib lives in Contents/Resources, because code signing allows only code beside the
    /// binary. MLX's own lookup checks next to the binary, so point it there. Apps, the CLI and
    /// the framework keep MLX's default search (the file doesn't exist at this path for them).
    static func useBundleMetallib() {
        var info = Dl_info()
        guard GPU.metallib == nil, dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return }
        let binary = URL(filePath: String(cString: name))
        guard binary.deletingLastPathComponent().lastPathComponent == "MacOS" else { return }
        let candidate = binary.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/mlx.metallib")
        if FileManager.default.fileExists(atPath: candidate.path) { GPU.metallib = candidate }
    }

    func unload() {
        guard task != nil else { return }
        task = nil                       // in-flight generations keep their reference until done
        Memory.clearCache()
        NPCLog.info("mlx:\(directory.lastPathComponent): unloaded")
    }

    func load() async throws -> Loaded {
        if let task { return try await task.value }
        let dir = directory, mb = cacheMB
        let t = Task<Loaded, Error> {
            let start = ContinuousClock.now
            Self.useBundleMetallib()
            _ = LLMModelFactory.shared                      // registers the LLM model types
            // Bound MLX's reusable-buffer cache: it otherwise grows to several GB, and
            // this runs beside a game sharing unified memory.
            Memory.cacheLimit = mb * 1024 * 1024
            let bpe = try BPETokenizer(directory: dir)
            let container = try await loadModelContainer(from: dir, using: LocalTokenizerLoader(bpe: bpe))
            let tokenizer = QwenMLXTokenizer(bpe: bpe)
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                                                        eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let closing = ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId)
            let (whitespace, whitespaceIDs) = WhitespaceTokenBias.compute(tokenizer: tokenizer)
            NPCLog.info("mlx:\(dir.lastPathComponent): loaded in \(MLXBackend.ms(ContinuousClock.now - start)) ms (cache \(mb) MB)")
            return Loaded(container: container, bpe: bpe, grammarTokenizer: grammarTokenizer,
                          closingBias: closing, whitespaceBias: whitespace, whitespaceTokenIDs: whitespaceIDs)
        }
        task = t
        do { return try await t.value } catch { task = nil; NPCLog.error("mlx: load failed: \(error)"); throw error }
    }
}

// MARK: - Schema

/// JSON Schema for one dialogue line. xgrammar emits properties in schema order, so
/// text comes first (the line is written before its labels). The vendored shim
/// compiles schemas without optional whitespace, so all structure is fast-forwarded.
/// No string length bounds: they made grammar compilation ~40 s; the core validator
/// enforces length. (A hand-written EBNF was ~5x slower per token than xgrammar's
/// JSON string matcher.)
enum DialogueJSONSchema {
    static func make(_ s: OutputSchema) -> String {
        func q(_ v: String) -> String {
            String(decoding: (try? JSONEncoder().encode(v)) ?? Data("\"\"".utf8), as: UTF8.self)
        }
        func list(_ v: [String]) -> String { "[" + v.map(q).joined(separator: ",") + "]" }
        var props = [
            // minLength 1: a 2B model sometimes closed the string at once (mostly in
            // Japanese). Regex patterns are avoided: `.` also matches the closing quote,
            // so the string never ends, and non-ASCII classes are clamped.
            #""text":{"type":"string","minLength":1}"#,
            #""emotion":{"enum":\#(list(s.emotions.map(\.rawValue)))}"#,
            #""intent":{"enum":\#(list(s.intents.map(\.rawValue)))}"#,
        ]
        var required = ["text", "emotion", "intent"]
        if !s.commands.isEmpty && s.maxCommands > 0 {
            let variants = s.commands.map { c -> String in
                let target = c.targets.isEmpty ? #"{"const":""}"# : #"{"enum":\#(list(c.targets))}"#
                return #"{"type":"object","properties":{"kind":{"const":\#(q(c.kind))},"target":\#(target)},"required":["kind","target"],"additionalProperties":false}"#
            }
            props.append(#""commands":{"type":"array","maxItems":\#(s.maxCommands),"items":{"anyOf":[\#(variants.joined(separator: ","))]}}"#)
            required.append("commands")
        }
        return #"{"type":"object","properties":{\#(props.joined(separator: ","))},"required":\#(list(required)),"additionalProperties":false}"#
    }
}

// MARK: - Tokenizer

struct LocalTokenizerLoader: TokenizerLoader {
    let bpe: BPETokenizer
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { QwenMLXTokenizer(bpe: bpe) }
}

/// NPCVoice's native byte-level BPE behind MLX's tokenizer protocol.
struct QwenMLXTokenizer: MLXLMCommon.Tokenizer {
    let bpe: BPETokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { bpe.encode(text) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { bpe.decode(tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { bpe.tokenID(token) }
    func convertIdToToken(_ id: Int) -> String? { bpe.token(id) }

    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        if let tools, !tools.isEmpty { throw TokenizerError.missingChatTemplate }   // tool calling is not used
        let msgs = messages.map { m in
            QwenChatTemplate.Message(role: m["role"] as? String ?? "user", content: m["content"] as? String ?? "")
        }
        let thinking = additionalContext?["enable_thinking"] as? Bool ?? false
        return bpe.encode(try QwenChatTemplate.render(msgs, addGenerationPrompt: true, enableThinking: thinking))
    }
}
