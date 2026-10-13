import SwiftUI
import UniformTypeIdentifiers
import NPCKit

extension UTType {
    static let npcProject = UTType(exportedAs: "dev.npcvoice.project", conformingTo: .package)
}

/// A `.npcproj` package: a folder of JSON files, loaded and validated by the core.
struct ProjectDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.npcProject]

    var project: NPCProject
    /// Character portraits (PNG) by character id, stored as `portraits/<id>.png`.
    var portraits: [String: Data] = [:]

    init() {
        project = (try? NPCProject.sample()) ?? NPCProject(name: "Untitled")
    }

    init(configuration: ReadConfiguration) throws {
        project = try NPCProject.load(from: configuration.file)
        for (name, file) in configuration.file.fileWrappers?["portraits"]?.fileWrappers ?? [:] {
            if let data = file.regularFileContents { portraits[(name as NSString).deletingPathExtension] = data }
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = try project.fileWrapper()
        let ids = Set(project.characters.map(\.id))   // portraits of deleted characters are dropped
        var files: [String: FileWrapper] = [:]
        for (id, data) in portraits where ids.contains(id) {
            files["\(id).png"] = FileWrapper(regularFileWithContents: data)
        }
        if !files.isEmpty {
            let folder = FileWrapper(directoryWithFileWrappers: files)
            folder.preferredFilename = "portraits"
            wrapper.addFileWrapper(folder)
        }
        return wrapper
    }
}
