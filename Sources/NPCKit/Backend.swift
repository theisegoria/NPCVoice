// Swift model backends plug into the core through npc_backend_callbacks. The core
// assembles prompts, validates and falls back; a backend only turns a
// BackendRequest into schema-constrained JSON.
import Foundation
import NPCCore

public protocol DialogueModelBackend: AnyObject, Sendable {
    var name: String { get }
    var contextTokens: Int { get }
    /// True if output is constrained to `request.schema` during decoding.
    var guidedGeneration: Bool { get }
    func availability() -> BackendAvailability
    func supports(_ language: Language) -> Bool
    /// Must honour task cancellation (return `.cancelled` promptly).
    func generate(_ request: BackendRequest) async -> BackendResponse
    func prewarm(instructions: String)
    /// Frees model memory until the next request (or prewarm) loads it again.
    func unload()
}

public extension DialogueModelBackend {
    func prewarm(instructions: String) {}
    func unload() {}
}

/// Messages to the game's logger through the core's sink (npc_set_log_callback).
public enum NPCLog {
    public static func debug(_ message: String) { npc_log_message(Int32(NPC_LOG_DEBUG), message) }
    public static func info(_ message: String) { npc_log_message(Int32(NPC_LOG_INFO), message) }
    public static func warning(_ message: String) { npc_log_message(Int32(NPC_LOG_WARNING), message) }
    public static func error(_ message: String) { npc_log_message(Int32(NPC_LOG_ERROR), message) }
}

/// Owns the Swift backend and its in-flight tasks for the lifetime of the core backend.
final class BackendBridge: @unchecked Sendable {
    let backend: any DialogueModelBackend
    private let lock = NSLock()
    private var tasks: [UInt64: Task<Void, Never>] = [:]

    init(_ backend: any DialogueModelBackend) { self.backend = backend }

    func track(_ job: UInt64, _ task: Task<Void, Never>) { lock.withLock { tasks[job] = task } }
    func finish(_ job: UInt64) { _ = lock.withLock { tasks.removeValue(forKey: job) } }
    func cancel(_ job: UInt64) { lock.withLock { tasks[job] }?.cancel() }

    static func from(_ ctx: UnsafeMutableRawPointer?) -> BackendBridge {
        Unmanaged<BackendBridge>.fromOpaque(ctx!).takeUnretainedValue()
    }

    static func make(_ backend: any DialogueModelBackend) -> OpaquePointer {
        let bridge = BackendBridge(backend)
        let ctx = Unmanaged.passRetained(bridge).toOpaque()
        return backend.name.withCString { name in
            var cb = npc_backend_callbacks()
            cb.struct_size = UInt32(MemoryLayout<npc_backend_callbacks>.size)
            cb.context = ctx
            cb.name = name                       // copied by the core
            cb.context_tokens = UInt32(clamping: backend.contextTokens)
            cb.guided_generation = backend.guidedGeneration ? 1 : 0
            cb.availability = { ctx in BackendBridge.from(ctx).backend.availability().rawValue }
            cb.supports_language = { ctx, tag in
                guard let tag, let l = Language(rawValue: String(cString: tag)) else { return 0 }
                return BackendBridge.from(ctx).backend.supports(l) ? 1 : 0
            }
            cb.generate = { ctx, requestJSON, job, done, doneContext in
                let bridge = BackendBridge.from(ctx)
                let json = requestJSON.map { String(cString: $0) } ?? ""
                let doneBox = DoneBox(done: done, context: doneContext)
                let task = Task.detached(priority: .userInitiated) {
                    let response: BackendResponse
                    do {
                        let request = try Core.decode(BackendRequest.self, json)
                        response = await bridge.backend.generate(request)
                    } catch {
                        response = BackendResponse(status: .error, diagnostic: "\(error)")
                    }
                    bridge.finish(job)
                    let out = (try? Core.encode(Task.isCancelled && response.status == .ok ? BackendResponse(status: .cancelled) : response))
                        ?? #"{"status":"error","diagnostic":"encode failed"}"#
                    doneBox.call(out)
                }
                bridge.track(job, task)
            }
            cb.cancel = { ctx, job in BackendBridge.from(ctx).cancel(job) }
            cb.prewarm = { ctx, instructions in
                guard let instructions else { return }
                BackendBridge.from(ctx).backend.prewarm(instructions: String(cString: instructions))
            }
            cb.unload = { ctx in BackendBridge.from(ctx).backend.unload() }
            cb.destroy = { ctx in Unmanaged<BackendBridge>.fromOpaque(ctx!).release() }
            return npc_backend_create(&cb)!
        }
    }
}

/// The core's completion callback, carried across the task boundary.
private struct DoneBox: @unchecked Sendable {
    let done: npc_backend_done_fn?
    let context: UnsafeMutableRawPointer?
    func call(_ json: String) { json.withCString { done?(context, $0) } }
}

/// The core backend handle for a Swift backend, for the C SDK (npc_sdk.h). The caller
/// owns the returned `npc_backend*` and releases it with npc_backend_release.
public func _makeCoreBackend(_ backend: some DialogueModelBackend) -> OpaquePointer {
    BackendBridge.make(backend)
}
