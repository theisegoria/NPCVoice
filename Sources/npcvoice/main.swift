// npcvoice: command-line front end for NPCVoice projects.
import Foundation
import NPCKit
import NPCMLX
import NPCSpeech

let usage = """
usage: npcvoice <command> [options]

commands:
  init <path.npcproj>                 create the "Harbor Town" sample project
  validate <project>                  check a project; exits 1 if it has errors
  say <project> --npc <id> (--player "<line>" | --event "<what happened>") [options]
                                      generate one line (JSON with --json)
  prompt <project> --npc <id> (--player ... | --event ...) [options]
                                      show exactly what the model would see
  characters <project>                list characters
  bundle <project> <out.json>         the whole project as one JSON file (npc_project_load_json)
  speak --voice <id> --text "<line>" --out <file.wav> [--project p] [--speed s] [--json]
                                      synthesize a line (24 kHz float WAV + lip-sync JSON next to it)
  bench <project> [--backend ...] [--runs n]
                                      time warm generation across the project's characters

options for say/prompt:
  --flags a,b,c        progress flags set in the game
  --location <text>    --objective <text>    --mood <text>
  --memory <text>      (repeatable) long-term note about the player
  --topics a,b         topic tags for fact ranking
  --backend stub|fm|mlx  deterministic stub, Apple FoundationModels, or bundled Qwen3.5-2B via MLX
  --seed <n>           sample instead of greedy decoding
  --deadline-ms <n>    give up and use a fallback line after n ms (default 10000)
  --json               machine-readable output
"""

struct CLIError: Error, CustomStringConvertible { let description: String }

struct Options {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var switches: Set<String> = []
    static let flags: Set<String> = ["--json", "--help"]

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                if Self.flags.contains(a) { switches.insert(a); continue }
                guard let v = it.next() else { throw CLIError(description: "\(a) needs a value") }
                values[a, default: []].append(v)
            } else {
                positional.append(a)
            }
        }
    }
    func value(_ k: String) -> String? { values[k]?.last }
    func list(_ k: String) -> [String] {
        (values[k] ?? []).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    }
    var json: Bool { switches.contains("--json") }
}

func projectURL(_ o: Options) throws -> URL {
    guard let p = o.positional.first else { throw CLIError(description: "missing project path") }
    return URL(filePath: p)
}

func gameCall(_ o: Options) throws -> GameCall {
    guard let npc = o.value("--npc") else { throw CLIError(description: "--npc <id> is required") }
    var call: GameCall
    if let line = o.value("--player") { call = GameCall(character: npc, playerUtterance: line) }
    else if let event = o.value("--event") { call = GameCall(character: npc, trigger: event) }
    else { throw CLIError(description: "give --player \"<line>\" or --event \"<what happened>\"") }
    call.flags = o.list("--flags")
    call.topics = o.list("--topics")
    call.location = o.value("--location") ?? ""
    call.objective = o.value("--objective") ?? ""
    call.mood = o.value("--mood")
    call.memories = o.values["--memory"] ?? []
    if let s = o.value("--seed"), let seed = UInt64(s) { call.sampling = Sampling(greedy: false, seed: seed) }
    // Interactive tools allow a cold model start; games keep the 2.5 s frame-budget default.
    var budget = Budget()
    budget.deadlineMs = Int(o.value("--deadline-ms") ?? "") ?? 10_000
    call.budget = budget
    return call
}

func makeEngine(_ o: Options) async throws -> DialogueEngine {
    switch o.value("--backend") ?? "stub" {
    case "stub": return try DialogueEngine.stub()
    case "fm":
        let fm = FoundationModelsBackend()
        guard fm.availability() == .available else {
            throw CLIError(description: "Apple FoundationModels is unavailable here (\(fm.availability())); is Apple Intelligence on?")
        }
        return try DialogueEngine(backend: fm)
    case "mlx":
        guard let dir = MLXBackend.defaultModelDirectory() else {
            throw CLIError(description: "the Qwen model folder was not found (set NPCVOICE_MODELS)")
        }
        let mlx = MLXBackend(modelDirectory: dir)
        try await mlx.warmUp()
        return try DialogueEngine(backend: mlx)
    case let other: throw CLIError(description: "backend '\(other)' is not available in this build (available: stub, fm, mlx)")
    }
}

func printJSON<T: Encodable>(_ v: T) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try e.encode(v), as: UTF8.self))
}

func run() async throws -> Int32 {
    let args = CommandLine.arguments.dropFirst()
    guard let command = args.first, command != "--help", command != "help" else { print(usage); return 0 }
    let o = try Options(args.dropFirst())

    switch command {
    case "init":
        guard let path = o.positional.first else { throw CLIError(description: "usage: npcvoice init <path.npcproj>") }
        try NPCProject.writeSample(to: URL(filePath: path))
        print("created \(path)")
        return 0

    case "validate":
        let project = try NPCProject.load(from: try projectURL(o))
        let diagnostics = try project.diagnostics()
        if o.json { try printJSON(diagnostics) }
        else {
            for d in diagnostics { print("\(d.severity == .error ? "error" : "warning"): \(d.path): \(d.message)") }
            let errors = diagnostics.filter { $0.severity == .error }.count
            print("\(project.name): \(project.characters.count) characters, \(project.facts.count) facts, \(errors) errors, \(diagnostics.count - errors) warnings")
        }
        return diagnostics.contains { $0.severity == .error } ? 1 : 0

    case "bundle":
        // One JSON file for engines that pack their resources (Godot .pck, Unity, Unreal .pak).
        guard o.positional.count >= 2 else { throw CLIError(description: "usage: npcvoice bundle <project> <out.json>") }
        let url = try projectURL(o)
        let errors = try NPCProject.load(from: url).diagnostics().filter { $0.severity == .error }
        if !errors.isEmpty {
            for d in errors { print("error: \(d.path): \(d.message)") }
            return 1
        }
        try Data(ProjectHandle(url: url).json().utf8).write(to: URL(filePath: o.positional[1]))
        print("wrote \(o.positional[1])")
        return 0

    case "characters":
        let project = try NPCProject.load(from: try projectURL(o))
        if o.json { try printJSON(project.characters) }
        else { for c in project.characters { print("\(c.id)\t\(c.displayName)\t\(c.language.rawValue)\t\(c.voice)\t\(c.role)") } }
        return 0

    case "prompt":
        let handle = try ProjectHandle(url: try projectURL(o))
        let p = try handle.request(for: try gameCall(o)).preparedPrompt()
        if o.json { try printJSON(p) }
        else {
            print("── instructions (\(p.estimatedPromptTokens) est. prompt tokens) ──\n\(p.instructions)")
            print("── prompt ──\n\(p.prompt)")
            print("── grounding ──\nfacts: \(p.usedFactIds.joined(separator: ", "))\nguarded keywords: \(p.withheldKeywords.joined(separator: ", "))")
        }
        return 0

    case "say":
        let handle = try ProjectHandle(url: try projectURL(o))
        let request = try handle.request(for: try gameCall(o))
        let engine = try await makeEngine(o)
        let r = try await engine.respond(to: request)
        if o.json { try printJSON(r) }
        else {
            print(r.line.text)
            var meta = "[\(r.line.emotion.rawValue) · \(r.line.intent.rawValue) · \(r.source.rawValue)"
            if r.source == .fallback { meta += ": \(r.fallbackReason)" }
            meta += " · \(String(format: "%.0f", r.latencyMs)) ms]"
            print(meta)
            for c in r.line.commands { print("→ \(c.kind)\(c.target.isEmpty ? "" : "(\(c.target))")") }
            if !r.diagnostic.isEmpty { print("note: \(r.diagnostic)") }
        }
        return 0

    case "speak":
        guard let voice = o.value("--voice"), let text = o.value("--text"), let out = o.value("--out") else {
            throw CLIError(description: "usage: npcvoice speak --voice <id> --text \"<line>\" --out <file.wav>")
        }
        guard let models = SpeechSynthesizer.defaultModelsDirectory() else { throw CLIError(description: "speech models not found (set NPCVOICE_MODELS)") }
        let synth = try SpeechSynthesizer(models: models)
        let start = ContinuousClock.now
        var overrides: [String: String] = [:]
        if let projectPath = o.value("--project") {
            let project = try NPCProject.load(from: URL(filePath: projectPath))
            overrides = project.pronunciationMap(SpeechSynthesizer.language(ofVoice: voice) == .japanese ? .japanese : .english)
        }
        let line = try synth.speak(text, voice: voice, speed: Double(o.value("--speed") ?? "") ?? 1, pronunciations: overrides)
        let elapsed = ContinuousClock.now - start
        let url = URL(filePath: out)
        try WAV.data(line.pcm, sampleRate: line.sampleRate).write(to: url)
        struct Sidecar: Encodable { let text: String; let voice: String; let phonemes: String; let duration: Double
            let sourceLUFS: Double; let gainDB: Double; let unknownWords: [String]; let visemes: [VisemeSegment]; let phonemeTrack: [PhonemeSegment] }
        let sidecar = Sidecar(text: text, voice: voice, phonemes: line.phonemes, duration: line.duration, sourceLUFS: line.loudness.integratedLUFS,
                              gainDB: line.gainDB, unknownWords: line.unknownWords, visemes: line.visemes, phonemeTrack: line.phonemeTrack)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try e.encode(sidecar).write(to: url.deletingPathExtension().appendingPathExtension("lipsync.json"))
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if o.json { try printJSON(sidecar) }
        else {
            print("\(out): \(String(format: "%.2f", line.duration)) s in \(String(format: "%.2f", secs)) s, \(line.visemes.count) visemes, source \(String(format: "%.1f", line.loudness.integratedLUFS)) LUFS → −23")
            print("phonemes: \(line.phonemes)")
            if !line.unknownWords.isEmpty { print("spelled (not in lexicon): \(line.unknownWords.joined(separator: ", "))") }
        }
        return 0

    case "bench":
        let handle = try ProjectHandle(url: try projectURL(o))
        let project = try handle.project()
        let loadStart = ContinuousClock.now
        let engine = try await makeEngine(o)
        let loadTime = ContinuousClock.now - loadStart
        let lines = ["Evening. What's the news?", "What do you want most right now?", "Tell me about the harbor.",
                     "Can you help me?", "Goodbye for now."]
        let runs = Int(o.value("--runs") ?? "") ?? 2
        var latencies: [Double] = [], fallbacks = 0, outTokens = 0
        for round in 0..<runs {
            for c in project.characters {
                let utterance = c.language == .japanese ? "港について教えてください。" : lines[(round + latencies.count) % lines.count]
                var call = GameCall(character: c.id, playerUtterance: utterance)
                call.allowCache = false
                var budget = Budget(); budget.deadlineMs = 60_000
                call.budget = budget
                let r = try await engine.respond(to: try handle.request(for: call))
                latencies.append(r.latencyMs)
                outTokens += r.outputTokens
                if r.source == .fallback { fallbacks += 1 }
                if !o.json { print(String(format: "%7.0f ms  %@  %@", r.latencyMs, c.id, r.line.text)) }
            }
        }
        let sorted = latencies.sorted()
        let p50 = sorted[sorted.count / 2], p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        print(String(format: "backend %@ · load %.1f s · %d lines · p50 %.0f ms · p90 %.0f ms · %d fallbacks · %.1f output tok/line",
                     engine.backendInfo?.name ?? "?", Double(loadTime.components.seconds) + Double(loadTime.components.attoseconds) / 1e18,
                     sorted.count, p50, p90, fallbacks, Double(outTokens) / Double(max(1, sorted.count))))
        return 0

    default:
        throw CLIError(description: "unknown command '\(command)'\n\n\(usage)")
    }
}

do { exit(try await run()) }
catch { fputs("error: \(error)\n", stderr); exit(error is CLIError ? 64 : 1) }
