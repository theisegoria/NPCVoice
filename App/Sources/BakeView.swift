import NPCKit
import NPCSpeech
import SwiftUI
import UniformTypeIdentifiers

/// One situation to write lines for.
struct BakeSituation: Identifiable, Hashable {
    let id: String
    var name: String
    var trigger: String
    var intent: Intent
    static let defaults: [BakeSituation] = [
        .init(id: "greeting", name: "Greeting", trigger: "The player walks up to you for the first time.", intent: .greet),
        .init(id: "farewell", name: "Farewell", trigger: "The player says goodbye and turns to leave.", intent: .farewell),
        .init(id: "refusal", name: "Refusal", trigger: "The player asks for something you will not give them.", intent: .refuse),
        .init(id: "smalltalk", name: "Small talk", trigger: "The player asks how things are going.", intent: .inform),
        .init(id: "busy", name: "Busy", trigger: "The player interrupts you while you are busy.", intent: .deflect),
    ]
}

struct BakeRow: Identifiable, Equatable {
    let id = UUID()
    let character: String
    let situation: String
    let take: Int
    var text: String
    var emotion: Emotion
    var intent: Intent
    var source: LineSource
    var approved: Bool
}

/// Batch generation of authored lines: write takes per character × situation, review,
/// then add approved lines to fallbacks or export them as voiced assets.
@MainActor @Observable
final class BakeModel {
    var selectedCharacters: Set<String> = []
    var situations = BakeSituation.defaults
    var enabledSituations: Set<String> = ["greeting", "farewell", "refusal"]
    var takes = 2
    var rows: [BakeRow] = []
    var running = false
    var progress = 0.0
    var status = ""
    private var task: Task<Void, Never>?

    func run(project: NPCProject, runtime: ModelRuntime) {
        task?.cancel()
        let chars = project.characters.filter { selectedCharacters.contains($0.id) }
        let sits = situations.filter { enabledSituations.contains($0.id) }
        let total = max(1, chars.count * sits.count * takes)
        rows.removeAll()
        running = true; progress = 0
        task = Task {
            defer { running = false; status = "Generated \(rows.count) lines" }
            do {
                let engine = try await runtime.engine()
                let handle = try ProjectHandle(project: project)
                var done = 0
                for c in chars {
                    for s in sits {
                        var earlier: [String] = []
                        for take in 1...takes {
                            if Task.isCancelled { return }
                            status = "\(c.displayName) · \(s.name) · take \(take)"
                            var call = GameCall(character: c.id, trigger: earlier.isEmpty ? s.trigger
                                : s.trigger + " (Say it differently from your earlier lines.)")
                            call.exchanges = earlier.map { Exchange(.character, $0) }
                            call.allowCache = false
                            var budget = Budget(); budget.deadlineMs = 15_000
                            call.budget = budget
                            let r = try await engine.respond(to: try handle.request(for: call))
                            earlier.append(r.line.text)
                            rows.append(BakeRow(character: c.id, situation: s.name, take: take, text: r.line.text,
                                                emotion: r.line.emotion, intent: r.line.intent, source: r.source,
                                                approved: r.source == .model))
                            done += 1
                            progress = Double(done) / Double(total)
                        }
                    }
                }
            } catch { status = "Stopped: \(error)" }
        }
    }

    func cancel() { task?.cancel() }
}

struct BakeView: View {
    @Binding var project: NPCProject
    let runtime: ModelRuntime
    @Bindable var model: BakeModel
    @State private var exporting = false
    @State private var exportStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            setup
                .padding(20)
            Divider()
            if model.rows.isEmpty && !model.running {
                ContentUnavailableView("No Lines Yet", systemImage: "rectangle.stack.badge.plus",
                                       description: Text("Pick characters and situations, then Generate. Approved lines can become fallback lines or exported voice assets."))
            } else {
                table
            }
        }
        .navigationSubtitle("Bake")
        .onAppear {
            if model.selectedCharacters.isEmpty { model.selectedCharacters = Set(project.characters.prefix(2).map(\.id)) }
            if UserDefaults.standard.bool(forKey: "NPCVoiceAutoRun") && model.rows.isEmpty && !model.running {
                model.takes = 1
                model.run(project: project, runtime: runtime)
            }
        }
        .fileExporter(isPresented: $exporting, document: BakeAssets(rows: approved, project: project, runtime: runtime),
                      contentType: .folder, defaultFilename: "\(project.name) lines") { result in
            if case .success(let url) = result { exportStatus = "Exported to \(url.lastPathComponent)" }
        }
    }

    private var approved: [BakeRow] { model.rows.filter(\.approved) }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditorHeader(title: "Bake Lines", subtitle: "Write authored lines in bulk, review them, and ship them as fallbacks or voiced assets",
                         systemImage: "rectangle.stack.badge.plus", tint: .orange)
            StackedRow(title: "Characters") {
                ChipPicker(all: project.characters.map(\.id), selection: Binding(
                    get: { project.characters.map(\.id).filter(model.selectedCharacters.contains) },
                    set: { model.selectedCharacters = Set($0.isEmpty ? project.characters.map(\.id) : $0) })) { id in
                        project.characters.first { $0.id == id }?.displayName ?? id
                    }
            }
            StackedRow(title: "Situations") {
                ChipPicker(all: model.situations.map(\.id), selection: Binding(
                    get: { model.situations.map(\.id).filter(model.enabledSituations.contains) },
                    set: { model.enabledSituations = Set($0.isEmpty ? model.situations.map(\.id) : $0) })) { id in
                        model.situations.first { $0.id == id }?.name ?? id
                    }
            }
            HStack(spacing: 14) {
                Stepper("Takes per situation: \(model.takes)", value: $model.takes, in: 1...5)
                    .fixedSize()
                Text("\(model.selectedCharacters.count * model.enabledSituations.count * model.takes) lines")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if model.running {
                    ProgressView(value: model.progress).frame(width: 160)
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    if !model.status.isEmpty { Text(exportStatus.isEmpty ? model.status : exportStatus).font(.caption).foregroundStyle(.secondary) }
                    Button { model.run(project: project, runtime: runtime) } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Generate lines (⌘↩)")
                    .disabled(model.selectedCharacters.isEmpty || model.enabledSituations.isEmpty)
                }
            }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table($model.rows) {
                TableColumn("") { $row in
                    Toggle("", isOn: $row.approved).labelsHidden().toggleStyle(.checkbox)
                        .accessibilityLabel("Approve \(row.situation) line")
                }
                .width(24)
                TableColumn("Character") { $row in
                    if let c = project.characters.first(where: { $0.id == row.character }) {
                        HStack(spacing: 6) { Avatar(character: c, size: 18); Text(c.displayName).lineLimit(1) }
                    }
                }
                .width(min: 110, ideal: 140)
                TableColumn("Situation") { $row in
                    Text(row.take > 1 ? "\(row.situation) · \(row.take)" : row.situation).foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Line") { $row in
                    TextField("", text: $row.text).labelsHidden()
                        .help(row.text)   // rows are one line tall; the full line shows on hover and when editing
                }
                .width(min: 320, ideal: 560)
                TableColumn("Emotion") { $row in
                    Text(row.emotion.rawValue).foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Source") { $row in
                    Text(row.source == .model ? "model" : "fallback").foregroundStyle(row.source == .model ? .secondary : Color.orange)
                }
                .width(64)
            }
            HStack {
                Text("\(approved.count) of \(model.rows.count) approved").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    addToFallbacks()
                } label: { Label("Add to Fallback Lines", systemImage: "text.badge.plus") }
                .disabled(approved.isEmpty)
                .help("Append approved lines to each character's fallback lines")
                Button {
                    exporting = true
                } label: { Label("Export Voiced Assets…", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .disabled(approved.isEmpty || model.running)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func addToFallbacks() {
        for row in approved {
            guard let i = project.characters.firstIndex(where: { $0.id == row.character }) else { continue }
            let line = FallbackLine(text: row.text, intent: row.intent, emotion: row.emotion)
            if !project.characters[i].fallbacks.contains(where: { $0.text == line.text }) {
                project.characters[i].fallbacks.append(line)
            }
        }
        exportStatus = "Added \(approved.count) lines to fallbacks"
    }
}

/// Export: per character, voiced lines (wav + lipsync.json) and a lines.json manifest.
struct BakeAssets: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let rows: [BakeRow]
    let project: NPCProject
    let runtime: ModelRuntime
    init(rows: [BakeRow], project: NPCProject, runtime: ModelRuntime) { self.rows = rows; self.project = project; self.runtime = runtime }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let models = SpeechSynthesizer.defaultModelsDirectory() else { throw SpeechError.missingModel("speech models") }
        let synth = try SpeechSynthesizer(models: models)
        var folders: [String: FileWrapper] = [:]
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        struct Entry: Encodable { let file: String; let text: String; let situation: String; let emotion: String; let intent: String; let duration: Double }
        struct Sidecar: Encodable { let text: String; let phonemes: String; let duration: Double; let visemes: [VisemeSegment] }
        for (charID, lines) in Dictionary(grouping: rows, by: \.character) {
            guard let c = project.characters.first(where: { $0.id == charID }) else { continue }
            let overrides = project.pronunciationMap(c.language)
            var files: [String: FileWrapper] = [:], entries: [Entry] = []
            for (n, row) in lines.enumerated() {
                let spoken = try synth.speak(row.text, voice: c.voice, pronunciations: overrides)
                let stem = String(format: "%@_%02d", row.situation.lowercased().replacingOccurrences(of: " ", with: "-"), n + 1)
                files["\(stem).wav"] = FileWrapper(regularFileWithContents: WAV.data(spoken.pcm, sampleRate: spoken.sampleRate))
                files["\(stem).lipsync.json"] = FileWrapper(regularFileWithContents: try e.encode(
                    Sidecar(text: row.text, phonemes: spoken.phonemes, duration: spoken.duration, visemes: spoken.visemes)))
                entries.append(Entry(file: "\(stem).wav", text: row.text, situation: row.situation, emotion: row.emotion.rawValue,
                                     intent: row.intent.rawValue, duration: spoken.duration))
            }
            files["lines.json"] = FileWrapper(regularFileWithContents: try e.encode(entries))
            folders[charID] = FileWrapper(directoryWithFileWrappers: files)
        }
        return FileWrapper(directoryWithFileWrappers: folders)
    }
}
