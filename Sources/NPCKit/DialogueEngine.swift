// The dialogue service: one worker in the core, one backend job in flight, a cache
// and deterministic fallbacks. `respond` never throws for model problems; it
// returns a fallback line with `fallbackReason` set.
import Foundation
import NPCCore

public struct ServiceConfig: Codable, Equatable, Sendable {
    public var queueCapacity = 16
    public var cacheCapacity = 256
    public var cancelGraceMs = 300
    public init() {}
}

public final class DialogueEngine: @unchecked Sendable {
    private let backend: OpaquePointer
    private let service: OpaquePointer
    private static let waitQueue = DispatchQueue(label: "npcvoice.dialogue.wait", attributes: .concurrent)

    /// Uses a Swift model backend (MLX, FoundationModels, or your own).
    public convenience init(backend: some DialogueModelBackend, config: ServiceConfig = .init()) throws {
        try self.init(rawBackend: BackendBridge.make(backend), config: config)
    }

    /// Deterministic stub backend for tests and offline previews. With no fixed
    /// response it speaks the highest-ranked grounded fact.
    public static func stub(delayMs: Int = 0, fixedResponse: String? = nil, config: ServiceConfig = .init()) throws -> DialogueEngine {
        struct StubConfig: Encodable { let delayMs: Int; let fixedResponse: String? }
        let json = try Core.encode(StubConfig(delayMs: delayMs, fixedResponse: fixedResponse))
        let raw: OpaquePointer = try Core.call { err in npc_backend_create_stub(json, err) }
        return try DialogueEngine(rawBackend: raw, config: config)
    }

    init(rawBackend: OpaquePointer, config: ServiceConfig) throws {
        backend = rawBackend
        do {
            let json = try Core.encode(config)
            service = try Core.call { err in npc_service_create(rawBackend, json, err) }
        } catch {
            npc_backend_release(rawBackend)
            throw error
        }
    }

    deinit {
        npc_service_destroy(service)
        npc_backend_release(backend)
    }

    public struct BackendInfo: Codable, Sendable {
        public var name: String
        public var contextTokens: Int
        public var guidedGeneration: Bool
        public var availability: String
    }

    public var backendInfo: BackendInfo? {
        (Core.take(npc_backend_info(backend))).flatMap { try? Core.decode(BackendInfo.self, $0) }
    }

    /// Queues a request; the result arrives via `wait`/`drain`.
    public func submit(_ request: DialogueRequest) throws -> UInt64 {
        try Core.call { err in
            let t = npc_service_submit(service, request.json, err)
            return t == 0 ? nil : t
        }
    }

    @discardableResult
    public func cancel(_ ticket: UInt64) -> Bool { npc_service_cancel(service, ticket) != 0 }

    /// Blocks the calling thread up to `timeoutMs`; nil if not complete.
    public func wait(_ ticket: UInt64, timeoutMs: UInt32) -> DialogueResult? {
        Core.take(npc_service_wait(service, ticket, timeoutMs)).flatMap { try? Core.decode(DialogueResult.self, $0) }
    }

    /// Completed results in ticket order (non-blocking; call once per frame from a game loop).
    public func drain() -> [DialogueResult] {
        (Core.take(npc_service_drain(service))).flatMap { try? Core.decode([DialogueResult].self, $0) } ?? []
    }

    public var stats: ServiceStats? {
        Core.take(npc_service_stats(service)).flatMap { try? Core.decode(ServiceStats.self, $0) }
    }

    public func clearCache() { npc_service_clear_cache(service) }

    /// Submits and awaits one line. Cancelling the task cancels the request.
    public func respond(to request: DialogueRequest, timeoutMs: UInt32 = 60_000) async throws -> DialogueResult {
        let ticket = try submit(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<DialogueResult, Error>) in
                Self.waitQueue.async { [self] in
                    if let r = wait(ticket, timeoutMs: timeoutMs) { c.resume(returning: r) }
                    else { cancel(ticket); c.resume(throwing: NPCError.timedOut) }
                }
            }
        } onCancel: { [self] in
            cancel(ticket)
        }
    }
}
