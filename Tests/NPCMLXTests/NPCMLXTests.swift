import Foundation
import Testing
import NPCKit
@testable import NPCMLX

/// Model-in-the-loop: runs only where the vendored Qwen folder is present.
@Suite(.enabled(if: MLXBackend.defaultModelDirectory() != nil, "Qwen model folder not present"), .serialized)
struct MLXBackendTests {
    @Test func generatesValidatedLinesInBothLanguages() async throws {
        let handle = try ProjectHandle(project: try NPCProject.sample())
        let backend = MLXBackend(modelDirectory: MLXBackend.defaultModelDirectory()!)
        try await backend.preload()
        let engine = try DialogueEngine(backend: backend)
        for (npc, line) in [("marta", "Evening. Got a room?"), ("aiko", "こんばんは。"), ("rhys", "Open the gate.")] {
            var call = GameCall(character: npc, playerUtterance: line)
            var budget = Budget(); budget.deadlineMs = 60_000     // debug builds of MLX are slow
            call.budget = budget
            let r = try await engine.respond(to: try handle.request(for: call))
            #expect(r.source == .model, "\(npc): \(r.fallbackReason) \(r.diagnostic)")
        }
    }

    /// Unload frees the weights; the next request reloads them transparently.
    @Test func unloadThenGenerateReloads() async throws {
        let backend = MLXBackend(modelDirectory: MLXBackend.defaultModelDirectory()!, cacheMB: 128)
        try await backend.preload()
        let request = BackendRequest(instructions: "You greet people briefly.", prompt: "Say hello.",
                                     schema: OutputSchema(emotions: [.neutral], intents: [.greet]), language: .english, maxOutputTokens: 16)
        #expect(await backend.generate(request).status == .ok)
        backend.unload()
        try await Task.sleep(for: .milliseconds(200))
        let again = await backend.generate(request)
        #expect(again.status == .ok, "\(again.diagnostic)")
    }

    @Test func schemaKeepsTextFirstAndCommandsOptional() {
        let s = OutputSchemaFixture.make(commands: true)
        let json = DialogueJSONSchema.make(s)
        #expect(json.range(of: "\"text\"")!.lowerBound < json.range(of: "\"emotion\"")!.lowerBound)
        #expect(json.contains(#""maxItems":2"#) && json.contains(#""const":"give_item""#))
        #expect(!DialogueJSONSchema.make(OutputSchemaFixture.make(commands: false)).contains("commands"))
    }
}

enum OutputSchemaFixture {
    static func make(commands: Bool) -> OutputSchema {
        let json = """
        {"emotions":["neutral","happy"],"intents":["inform"],"commands":\(commands ? #"[{"kind":"give_item","description":"Give","targets":["room_key"]}]"# : "[]"),
         "maxCommands":\(commands ? 2 : 0),"maxCharacters":220}
        """
        return try! JSONDecoder().decode(OutputSchema.self, from: Data(json.utf8))
    }
}
