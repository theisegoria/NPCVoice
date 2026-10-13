// C exports for npc_sdk.h: Swift backends and speech behind the stable C ABI.
import Foundation
import NPCCore
import NPCKit
import NPCMLX
import NPCSpeech

private func setError(_ out: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ message: String) {
    guard let out else { return }
    out.pointee = strdup(message)
}

private func string(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

/// Runs async work from a synchronous C call (never called on the main thread by games).
private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached { do { result = .success(try await work()) } catch { result = .failure(error) }; sem.signal() }
    sem.wait()
    return try result.get()
}

nonisolated(unsafe) private let versionString = strdup("0.1.0")!   // immutable after init
@_cdecl("npc_sdk_version")
public func npcSDKVersion() -> UnsafePointer<CChar> { UnsafePointer(versionString) }

private struct MLXConfig: Decodable {
    var modelDir: String?
    var cacheMB: Int?
    var warmUp: Bool?
}

@_cdecl("npc_backend_create_mlx")
public func npcBackendCreateMLX(_ configJSON: UnsafePointer<CChar>?, _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer? {
    errorOut?.pointee = nil
    var config = MLXConfig()
    if let json = string(configJSON), !json.isEmpty {
        do { config = try JSONDecoder().decode(MLXConfig.self, from: Data(json.utf8)) }
        catch { setError(errorOut, "config: \(error)"); return nil }
    }
    guard let url = config.modelDir.map({ URL(filePath: $0) }) ?? MLXBackend.defaultModelDirectory() else {
        setError(errorOut, "bundled model not found; pass modelDir"); return nil
    }
    let backend = MLXBackend(modelDirectory: url, cacheMB: config.cacheMB)
    guard backend.availability() == .available else { setError(errorOut, "model files missing in \(url.path)"); return nil }
    if config.warmUp ?? true {
        do { try blocking { try await backend.warmUp() } } catch { setError(errorOut, "\(error)"); return nil }
    }
    return _makeCoreBackend(backend)
}

@_cdecl("npc_backend_create_apple")
public func npcBackendCreateApple(_ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer? {
    errorOut?.pointee = nil
    let fm = FoundationModelsBackend()
    guard fm.availability() == .available else { setError(errorOut, "Apple Intelligence is unavailable (\(fm.availability()))"); return nil }
    return _makeCoreBackend(fm)
}

// MARK: - Speech

private final class SpeechBox: @unchecked Sendable {
    let synth: SpeechSynthesizer
    let queue = DispatchQueue(label: "npcvoice.speech", qos: .userInitiated)
    private let lock = NSLock()
    private var nextTicket: UInt64 = 0
    private var live: Set<UInt64> = []
    private var cancelled: Set<UInt64> = []
    private var overrides: [Language: [String: String]] = [:]
    init(_ s: SpeechSynthesizer) { synth = s }

    func issue() -> UInt64 { lock.withLock { nextTicket += 1; live.insert(nextTicket); return nextTicket } }
    func cancel(_ t: UInt64) -> Bool { lock.withLock { guard live.contains(t) else { return false }; cancelled.insert(t); return true } }
    func isCancelled(_ t: UInt64) -> Bool { lock.withLock { cancelled.contains(t) } }
    func finish(_ t: UInt64) { lock.withLock { live.remove(t); cancelled.remove(t) } }
    func setOverrides(_ o: [Language: [String: String]]) { lock.withLock { overrides = o } }
    func pronunciations(forVoice voice: String) -> [String: String] {
        lock.withLock { overrides[SpeechSynthesizer.language(ofVoice: voice) == .japanese ? .japanese : .english] ?? [:] }
    }
}

@_cdecl("npc_speech_create")
public func npcSpeechCreate(_ dir: UnsafePointer<CChar>?, _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OpaquePointer? {
    errorOut?.pointee = nil
    guard let url = string(dir).map({ URL(filePath: $0) }) ?? SpeechSynthesizer.defaultModelsDirectory() else {
        setError(errorOut, "bundled speech models not found; pass models_dir"); return nil
    }
    do {
        let start = ContinuousClock.now
        let synth = try SpeechSynthesizer(models: url)
        let d = ContinuousClock.now - start
        NPCLog.info("speech: models loaded in \(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) ms")
        return OpaquePointer(Unmanaged.passRetained(SpeechBox(synth)).toOpaque())
    } catch { NPCLog.error("speech: \(error)"); setError(errorOut, "\(error)"); return nil }
}

@_cdecl("npc_speech_release")
public func npcSpeechRelease(_ speech: OpaquePointer?) {
    guard let speech else { return }
    Unmanaged<SpeechBox>.fromOpaque(UnsafeRawPointer(speech)).release()
}

struct AudioInfo: Encodable {
    let phonemes: String, duration: Double, sourceLUFS: Double, gainDB: Double, unknownWords: [String]
    let visemes: [VisemeSegment], phonemeTrack: [PhonemeSegment]
}

@_cdecl("npc_speech_speak")
public func npcSpeechSpeak(_ speech: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ voice: UnsafePointer<CChar>?, _ speed: Double,
                           _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutablePointer<npc_audio>? {
    errorOut?.pointee = nil
    guard let speech, let text = string(text), let voice = string(voice) else { setError(errorOut, "null argument"); return nil }
    guard speed >= 0.5 && speed <= 2 else { setError(errorOut, "speed outside [0.5, 2]"); return nil }
    let box = Unmanaged<SpeechBox>.fromOpaque(UnsafeRawPointer(speech)).takeUnretainedValue()
    do {
        let line = try box.synth.speak(text, voice: voice, speed: speed, pronunciations: box.pronunciations(forVoice: voice))
        let info = AudioInfo(phonemes: line.phonemes, duration: line.duration, sourceLUFS: line.loudness.integratedLUFS,
                             gainDB: line.gainDB, unknownWords: line.unknownWords, visemes: line.visemes, phonemeTrack: line.phonemeTrack)
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        let pcm = UnsafeMutablePointer<Float>.allocate(capacity: max(1, line.pcm.count))
        line.pcm.withUnsafeBufferPointer { pcm.initialize(from: $0.baseAddress!, count: line.pcm.count) }
        let audio = UnsafeMutablePointer<npc_audio>.allocate(capacity: 1)
        audio.initialize(to: npc_audio(pcm: pcm, sample_count: UInt64(line.pcm.count), sample_rate: line.sampleRate, info_json: strdup(json)))
        return audio
    } catch { setError(errorOut, "\(error)"); return nil }
}

@_cdecl("npc_audio_free")
public func npcAudioFree(_ audio: UnsafeMutablePointer<npc_audio>?) {
    guard let audio else { return }
    audio.pointee.pcm.deallocate()
    free(audio.pointee.info_json)
    audio.deallocate()
}

@_cdecl("npc_speech_set_project")
public func npcSpeechSetProject(_ speech: OpaquePointer?, _ project: OpaquePointer?,
                                _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    errorOut?.pointee = nil
    guard let speech else { setError(errorOut, "null speech"); return 0 }
    let box = Unmanaged<SpeechBox>.fromOpaque(UnsafeRawPointer(speech)).takeUnretainedValue()
    guard let project else { box.setOverrides([:]); return 1 }
    guard let raw = npc_project_json(project) else { setError(errorOut, "could not read the project"); return 0 }
    defer { npc_string_free(raw) }
    do {
        let p = try JSONDecoder().decode(NPCProject.self, from: Data(String(cString: raw).utf8))
        box.setOverrides([.english: p.pronunciationMap(.english), .japanese: p.pronunciationMap(.japanese)])
        return 1
    } catch { setError(errorOut, "\(error)"); return 0 }
}

private struct ChunkInfo: Encodable {
    let phonemes: String, gainDB: Double, visemes: [VisemeSegment], phonemeTrack: [PhonemeSegment]
}

@_cdecl("npc_speech_submit")
public func npcSpeechSubmit(_ speech: OpaquePointer?, _ text: UnsafePointer<CChar>?, _ voice: UnsafePointer<CChar>?, _ speed: Double,
                            _ onChunk: npc_speech_chunk_fn?, _ onDone: npc_speech_done_fn?, _ context: UnsafeMutableRawPointer?,
                            _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UInt64 {
    errorOut?.pointee = nil
    guard let speech, let text = string(text), let voice = string(voice) else { setError(errorOut, "null argument"); return 0 }
    guard speed >= 0.5 && speed <= 2 else { setError(errorOut, "speed outside [0.5, 2]"); return 0 }
    // The queued work holds its own reference, so a release during a request is safe.
    let box = Unmanaged<SpeechBox>.fromOpaque(UnsafeRawPointer(speech)).takeUnretainedValue()
    let ticket = box.issue()
    nonisolated(unsafe) let ctx = context
    box.queue.async { [box] in
        defer { box.finish(ticket) }
        var status = Int32(NPC_SPEECH_DONE), failure: String?
        do {
            try box.synth.stream(text, voice: voice, speed: speed, pronunciations: box.pronunciations(forVoice: voice),
                                 isCancelled: { box.isCancelled(ticket) }) { chunk in
                guard let onChunk else { return }
                let info = String(decoding: try JSONEncoder().encode(
                    ChunkInfo(phonemes: chunk.phonemes, gainDB: chunk.gainDB, visemes: chunk.visemes, phonemeTrack: chunk.phonemeTrack)), as: UTF8.self)
                chunk.pcm.withUnsafeBufferPointer { samples in
                    info.withCString { json in
                        var c = npc_speech_chunk(pcm: samples.baseAddress, sample_count: UInt64(samples.count), sample_rate: chunk.sampleRate,
                                                 start_time: chunk.startTime, index: UInt32(chunk.index), is_last: chunk.isLast ? 1 : 0,
                                                 info_json: json)
                        onChunk(ctx, ticket, &c)
                    }
                }
            }
            if box.isCancelled(ticket) { status = Int32(NPC_SPEECH_CANCELLED) }
        } catch { status = Int32(NPC_SPEECH_FAILED); failure = "\(error)" }
        if let onDone {
            if let failure { failure.withCString { onDone(ctx, ticket, status, $0) } } else { onDone(ctx, ticket, status, nil) }
        }
    }
    return ticket
}

@_cdecl("npc_speech_cancel")
public func npcSpeechCancel(_ speech: OpaquePointer?, _ ticket: UInt64) -> Int32 {
    guard let speech else { return 0 }
    return Unmanaged<SpeechBox>.fromOpaque(UnsafeRawPointer(speech)).takeUnretainedValue().cancel(ticket) ? 1 : 0
}
