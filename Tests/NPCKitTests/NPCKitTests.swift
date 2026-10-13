import Foundation
import Testing
@testable import NPCKit

@Test func abiVersion() { #expect(npcCoreABIVersion == 1) }

@Suite struct ProjectTests {
    @Test func sampleLoadsWithoutErrors() throws {
        let p = try NPCProject.sample()
        #expect(p.name == "Harbor Town")
        #expect(p.characters.map(\.id) == ["aiko", "marta", "rhys", "tamsin"])
        #expect(p.character("aiko")?.language == .japanese)
        #expect(try p.diagnostics().filter { $0.severity == .error }.isEmpty)
    }

    @Test func saveAndReloadRoundTrips() throws {
        var p = try NPCProject.sample()
        p.characters[1].traits.append("never forgets a face")
        let dir = FileManager.default.temporaryDirectory.appending(path: "rt-\(UUID().uuidString).npcproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try p.write(to: dir)
        #expect(try NPCProject.load(from: dir) == p)
        #expect(try NPCProject.load(from: FileWrapper(url: dir)) == p)
    }

    @Test func diagnosticsCatchAuthoringMistakes() throws {
        var p = try NPCProject.sample()
        let i = p.characters.firstIndex { $0.id == "rhys" }!
        p.characters[i].voice = "jf_alpha"
        p.characters[i].commands.append("teleport")
        let errors = try p.diagnostics().filter { $0.severity == .error }
        #expect(errors.count == 2)
        #expect(errors.contains { $0.message.contains("teleport") })
    }

    @Test func strictDecodeReportsPath() throws {
        let h = try ProjectHandle(project: try NPCProject.sample())
        #expect(throws: NPCError.self) { try h.request(for: GameCall(character: "nobody", playerUtterance: "hi")) }
    }
}

@Suite struct EngineTests {
    let handle: ProjectHandle
    init() throws { handle = try ProjectHandle(project: try NPCProject.sample()) }

    @Test func stubSpeaksGroundedFact() async throws {
        let engine = try DialogueEngine.stub()
        var call = GameCall(character: "marta", playerUtterance: "How much for a room?")
        call.topics = ["room"]
        let r = try await engine.respond(to: try handle.request(for: call))
        #expect(r.source == .model)
        #expect(r.line.text == "A room at the Gull & Lantern costs three silver marks a night.")
        #expect(r.line.voice == "af_heart")
        let again = try await engine.respond(to: try handle.request(for: call))
        #expect(again.source == .cache)
    }

    @Test func promptInspection() throws {
        var call = GameCall(character: "tamsin", playerUtterance: "Where's the cargo?")
        call.memories = ["The player tipped her off about a patrol."]
        let p = try handle.request(for: call).preparedPrompt()
        #expect(p.instructions.contains("Tamsin Reed, the smuggler, a character in Harbor Town."))
        #expect(p.prompt.contains("tipped her off"))
        #expect(p.withheldKeywords.contains("sea cave"))
        #expect(p.schema.commands.map(\.kind) == ["follow_player"])
    }

    @Test func validatorRejectsSpoiler() throws {
        let req = try handle.request(for: GameCall(character: "tamsin", playerUtterance: "Where's the cargo?"))
        let v = try req.validate(modelOutput: #"{"text":"Try the sea cave.","emotion":"happy","intent":"inform"}"#)
        #expect(!v.ok && v.reason == "guardrail_rejected")
    }

    @Test func swiftBackendThroughBridge() async throws {
        let backend = EchoBackend()
        let engine = try DialogueEngine(backend: backend)
        #expect(engine.backendInfo?.name == "echo")
        let r = try await engine.respond(to: try handle.request(for: GameCall(character: "rhys", trigger: "The player walks up to the gate at midnight.")))
        #expect(r.source == .model, "\(r.diagnostic)")
        #expect(r.line.text == "Halt. State your business.")
        #expect(r.line.commands == [Command(kind: "call_guards", target: "")])
        #expect(backend.lastRequest?.schema.emotions.contains(.angry) == true)
    }

    @Test func slowBackendTimesOutToFallback() async throws {
        let engine = try DialogueEngine(backend: EchoBackend(delay: .seconds(5)))
        var call = GameCall(character: "rhys", playerUtterance: "Open up.")
        var budget = Budget(); budget.deadlineMs = 100
        call.budget = budget
        let start = ContinuousClock.now
        let r = try await engine.respond(to: try handle.request(for: call))
        #expect(r.source == .fallback && r.fallbackReason == "timeout")
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(engine.stats?.abandoned == 0, "Swift task honoured cancellation")
    }
}

final class EchoBackend: DialogueModelBackend, @unchecked Sendable {
    let name = "echo"
    let contextTokens = 4096
    let guidedGeneration = true
    let delay: Duration
    private(set) var lastRequest: BackendRequest?
    init(delay: Duration = .zero) { self.delay = delay }
    func availability() -> BackendAvailability { .available }
    func supports(_ language: Language) -> Bool { true }
    func generate(_ request: BackendRequest) async -> BackendResponse {
        lastRequest = request
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { return BackendResponse(status: .cancelled) }
        }
        return BackendResponse(status: .ok, json: #"{"text":"Halt. State your business.","emotion":"angry","intent":"warn","commands":[{"kind":"call_guards","target":"none"}]}"#)
    }
}

/// Model-in-the-loop: runs only where Apple Intelligence is available.
@Suite(.enabled(if: FoundationModelsBackend().availability() == .available, "Apple Intelligence unavailable"))
struct FoundationModelsTests {
    @Test func generatesValidatedLinesInBothLanguages() async throws {
        let handle = try ProjectHandle(project: try NPCProject.sample())
        let engine = try DialogueEngine(backend: FoundationModelsBackend())
        for (npc, line) in [("marta", "Evening. Got a room?"), ("aiko", "この祠について教えてください。")] {
            var call = GameCall(character: npc, playerUtterance: line)
            var budget = Budget(); budget.deadlineMs = 20_000
            call.budget = budget
            let r = try await engine.respond(to: try handle.request(for: call))
            #expect(r.source == .model, "\(npc): \(r.fallbackReason) \(r.diagnostic)")
            #expect(!r.line.text.isEmpty)
        }
    }
}
