// .npcproj projects (docs/JSON.md, docs/schema). Loading and validation go through the
// C++ core so every surface (games, CLI, app) agrees on what a valid project is;
// saving is plain JSON files written here.
import Foundation
import NPCCore

public struct NPCProject: Codable, Equatable, Sendable {
    public var name: String
    public var world: WorldProfile
    public var defaults: ProjectDefaults
    public var characters: [CharacterProfile]
    public var facts: [Fact]
    public var commands: [CommandSpec]
    public var pronunciations: [Pronunciation]

    public init(name: String) {
        self.name = name
        world = WorldProfile()
        world.name = name
        defaults = ProjectDefaults()
        characters = []
        facts = []
        commands = []
        pronunciations = []
    }

    /// Overrides for one language, keyed by word (as the G2P consumes them).
    public func pronunciationMap(_ language: Language) -> [String: String] {
        Dictionary(pronunciations.filter { $0.language == language }.map { ($0.word, $0.phonemes) }, uniquingKeysWith: { a, _ in a })
    }

    public static let fileExtension = "npcproj"

    /// Loads and strictly validates a project folder.
    public static func load(from url: URL) throws -> NPCProject {
        let handle = try ProjectHandle(url: url)
        return try handle.project()
    }

    /// Writes the "Harbor Town" sample to `url`, which must not exist.
    public static func writeSample(to url: URL) throws {
        _ = try Core.call { err in npc_project_write_sample(url.path, err) == 1 ? true : nil }
        var url = url
        var values = URLResourceValues()
        values.hasHiddenExtension = true            // Finder and window titles show "Harbor Town"
        try? url.setResourceValues(values)
    }

    public static func sample() throws -> NPCProject {
        let dir = FileManager.default.temporaryDirectory.appending(path: "npcvoice-sample-\(UUID().uuidString).npcproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSample(to: dir)
        return try load(from: dir)
    }

    public func character(_ id: String) -> CharacterProfile? { characters.first { $0.id == id } }

    /// Static checks (voice/language mismatches, unknown commands, prompt budget...).
    /// Throws if the project cannot be decoded at all.
    public func diagnostics() throws -> [ProjectDiagnostic] {
        try ProjectHandle(project: self).diagnostics()
    }

    // MARK: Saving

    struct ProjectFile: Encodable {
        let format = "npcvoice-project"
        let version = 1
        let name: String
        let world: WorldProfile
        let defaults: ProjectDefaults
        let pronunciations: [Pronunciation]
    }
    struct FactsFile: Encodable { let facts: [Fact] }
    struct CommandsFile: Encodable { let commands: [CommandSpec] }

    /// The project as a folder of pretty-printed JSON files (diff-friendly).
    public func fileWrapper() throws -> FileWrapper {
        let e = Core.prettyEncoder
        var characterFiles: [String: FileWrapper] = [:]
        for c in characters {
            characterFiles["\(c.id).json"] = FileWrapper(regularFileWithContents: try e.encode(c) + Data("\n".utf8))
        }
        return FileWrapper(directoryWithFileWrappers: [
            "project.json": FileWrapper(regularFileWithContents: try e.encode(ProjectFile(name: name, world: world, defaults: defaults, pronunciations: pronunciations)) + Data("\n".utf8)),
            "facts.json": FileWrapper(regularFileWithContents: try e.encode(FactsFile(facts: facts)) + Data("\n".utf8)),
            "commands.json": FileWrapper(regularFileWithContents: try e.encode(CommandsFile(commands: commands)) + Data("\n".utf8)),
            "characters": FileWrapper(directoryWithFileWrappers: characterFiles),
        ])
    }

    public func write(to url: URL) throws {
        try fileWrapper().write(to: url, options: [.atomic], originalContentsURL: nil)
    }

    /// Reads a project from a document file wrapper (via a temporary folder, so the
    /// core performs the same strict load as for files on disk).
    public static func load(from wrapper: FileWrapper) throws -> NPCProject {
        let dir = FileManager.default.temporaryDirectory.appending(path: "npcvoice-open-\(UUID().uuidString).npcproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try wrapper.write(to: dir, options: [], originalContentsURL: nil)
        var project = try load(from: dir)
        if let name = wrapper.filename, project.name.isEmpty {
            project.name = (name as NSString).deletingPathExtension
        }
        return project
    }
}

/// A project loaded into the core, for building requests.
public final class ProjectHandle: @unchecked Sendable {
    let raw: OpaquePointer

    public init(url: URL) throws {
        raw = try Core.call { err in npc_project_load(url.path, err) }
    }

    public init(project: NPCProject) throws {
        let json = try Core.encode(project)
        raw = try Core.call { err in npc_project_load_json(json, err) }
    }

    deinit { npc_project_release(raw) }

    /// The whole project as one JSON document (`npc_project_json`); load it with
    /// `npc_project_load_json` where a folder can't be read (e.g. inside a game's archive).
    public func json() -> String { Core.take(npc_project_json(raw)) ?? "" }

    public func project() throws -> NPCProject {
        try Core.decode(NPCProject.self, Core.take(npc_project_json(raw)) ?? "")
    }

    public func diagnostics() throws -> [ProjectDiagnostic] {
        try Core.decode([ProjectDiagnostic].self, Core.take(npc_project_diagnostics(raw)) ?? "[]")
    }

    /// Builds a full dialogue request for a game call.
    public func request(for call: GameCall) throws -> DialogueRequest {
        let json = try Core.encode(call)
        let request: String = try Core.call { err in Core.take(npc_project_request(raw, json, err)) }
        return DialogueRequest(json: request)
    }
}

/// A complete, validated dialogue request in the core's JSON form.
public struct DialogueRequest: Sendable, Equatable {
    public let json: String
    public init(json: String) { self.json = json }

    /// What the model will see for this request.
    public func preparedPrompt() throws -> PreparedPrompt {
        let s: String = try Core.call { err in Core.take(npc_prepare_prompt(json, err)) }
        return try Core.decode(PreparedPrompt.self, s)
    }

    /// Runs the validator on a raw model response (debugging and tests).
    public func validate(modelOutput: String) throws -> (ok: Bool, reason: String, diagnostic: String) {
        struct V: Decodable { let ok: Bool; let reason: String; let diagnostic: String }
        let s: String = try Core.call { err in Core.take(npc_validate_response(json, modelOutput, err)) }
        let v = try Core.decode(V.self, s)
        return (v.ok, v.reason, v.diagnostic)
    }
}
