// Apple FoundationModels backend (the on-device system model, macOS 27).
//
// One LanguageModelSession per request: game memory arrives as grounded context, so
// sessions stay stateless and deterministic under greedy sampling. Output is
// constrained with a DynamicGenerationSchema built from the request's emotions,
// intents and game-registered commands (per-command target enums).
import Foundation
import FoundationModels

public final class FoundationModelsBackend: DialogueModelBackend, @unchecked Sendable {
    public init() {}

    public var name: String { "apple-foundation-models:\(SystemLanguageModel.default.variant.displayName)" }
    public var contextTokens: Int { SystemLanguageModel.default.contextSize }
    public var guidedGeneration: Bool { true }

    public func availability() -> BackendAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .notEnabled
            case .modelNotReady: .modelNotReady
            @unknown default: .unsupported
            }
        }
    }

    public func supports(_ language: Language) -> Bool {
        let code = Locale.Language(identifier: language.rawValue).languageCode
        return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode == code }
    }

    public func prewarm(instructions: String) {
        LanguageModelSession(model: .default, instructions: instructions).prewarm()
    }

    public func generate(_ request: BackendRequest) async -> BackendResponse {
        guard SystemLanguageModel.default.isAvailable else {
            return BackendResponse(status: .unavailable, diagnostic: "system language model unavailable")
        }
        return await Self.generate(request, with: SystemLanguageModel.default)
    }

    /// Schema-constrained generation with any FoundationModels `LanguageModel`
    /// (the system model, or an MLX model through MLXFoundationModels).
    public static func generate(_ request: BackendRequest, with model: some LanguageModel) async -> BackendResponse {
        let schema: GenerationSchema
        do { schema = try Self.schema(for: request.schema) }
        catch { return BackendResponse(status: .error, diagnostic: "schema: \(error)") }
        let s = request.sampling
        let options = s.greedy
            ? GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxOutputTokens)
            : GenerationOptions(samplingMode: .random(probabilityThreshold: 0.9, seed: s.seed), temperature: s.temperature,
                                maximumResponseTokens: request.maxOutputTokens)
        let session = LanguageModelSession(model: model, instructions: Instructions(request.instructions))
        do {
            let response = try await session.respond(to: request.prompt, schema: schema, includeSchemaInPrompt: true, options: options)
            if Task.isCancelled { return BackendResponse(status: .cancelled) }
            if ProcessInfo.processInfo.environment["NPCVOICE_DEBUG"] != nil {
                FileHandle.standardError.write(Data("[npcvoice] raw: \(response.rawContent.jsonString)\n".utf8))
            }
            return BackendResponse(status: .ok, json: response.rawContent.jsonString,
                                   promptTokens: response.usage.input.totalTokenCount,
                                   outputTokens: response.usage.output.totalTokenCount)
        } catch {
            let (status, diagnostic) = Self.classify(error)
            return BackendResponse(status: Task.isCancelled ? .cancelled : status, diagnostic: diagnostic)
        }
    }

    static func schema(for spec: OutputSchema) throws -> GenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = [
            .init(name: "text",
                  description: "The one line the character speaks aloud, at most \(spec.maxCharacters) characters",
                  schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "emotion", description: "The character's emotion while speaking",
                  schema: DynamicGenerationSchema(name: "Emotion", anyOf: spec.emotions.map(\.rawValue))),
            .init(name: "intent", description: "What the line does in the conversation",
                  schema: DynamicGenerationSchema(name: "Intent", anyOf: spec.intents.map(\.rawValue))),
        ]
        if !spec.commands.isEmpty && spec.maxCommands > 0 {
            let variants: [DynamicGenerationSchema] = spec.commands.enumerated().map { index, c in
                let targets = c.targets.isEmpty ? ["none"] : c.targets
                return DynamicGenerationSchema(name: "Command\(index)", description: c.description, properties: [
                    .init(name: "kind", schema: DynamicGenerationSchema(name: "Command\(index)Kind", anyOf: [c.kind])),
                    .init(name: "target", schema: DynamicGenerationSchema(name: "Command\(index)Target", anyOf: targets)),
                ])
            }
            // An explicit "none" action: without it the model tends to fill the array
            // with some action on every line. The core's validator drops it silently.
            let noAction = DynamicGenerationSchema(name: "NoAction", description: "No game action (the usual case)", properties: [
                .init(name: "kind", schema: DynamicGenerationSchema(name: "NoActionKind", anyOf: ["none"])),
                .init(name: "target", schema: DynamicGenerationSchema(name: "NoActionTarget", anyOf: ["none"])),
            ])
            let command = DynamicGenerationSchema(name: "Command", anyOf: [noAction] + variants)
            // macOS 27.0: arrayOf with maximumElements 1 fails generation with
            // ModelManagerError 1032; 2+ works. The core's validator enforces maxCommands.
            properties.append(.init(name: "commands", description: "Game actions the character takes; usually empty",
                                    schema: DynamicGenerationSchema(arrayOf: command, minimumElements: 0,
                                                                    maximumElements: max(2, spec.maxCommands))))
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: "DialogueLine", properties: properties), dependencies: [])
    }

    static func classify(_ error: Error) -> (BackendResponse.Status, String) {
        if error is CancellationError { return (.cancelled, "cancelled") }
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded(let c): return (.contextExceeded, c.debugDescription)
            case .rateLimited(let c): return (.rateLimited, c.debugDescription)
            case .guardrailViolation(let c): return (.guardrail, c.debugDescription)
            case .refusal: return (.refusal, String(describing: e))
            case .unsupportedLanguageOrLocale(let c): return (.unsupportedLanguage, c.debugDescription)
            case .unsupportedGenerationGuide, .unsupportedCapability, .unsupportedTranscriptContent:
                return (.decodingFailure, String(describing: e))
            case .timeout: return (.error, "timeout: \(e)")
            @unknown default: return (.error, String(describing: e))
            }
        }
        if let e = error as? SystemLanguageModel.Error {
            switch e {
            case .assetsUnavailable: return (.unavailable, String(describing: e))
            @unknown default: return (.error, String(describing: e))
            }
        }
        if error is GeneratedContent.ParsingError { return (.decodingFailure, String(describing: error)) }
        return (.error, String(describing: error))
    }
}
