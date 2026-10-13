import SwiftUI
import NPCKit

// MARK: - World

struct WorldEditor: View {
    @Binding var world: WorldProfile
    @Binding var projectName: String

    var body: some View {
        Form {
            Section {
                EditorHeader(title: world.name.isEmpty ? "World" : world.name,
                             subtitle: "Shared by every character in this project",
                             systemImage: "globe.europe.africa", tint: .teal)
            }
            Section("World") {
                TextField("Name", text: $world.name, prompt: Text("Harbor Town"))
                ProseField(title: "Setting", text: $world.setting, prompt: "Where and when, in a sentence or two")
                TextField("Tone", text: $world.tone, prompt: Text("e.g. wry, grounded low fantasy"))
                TextField("Content rating", text: $world.contentRating, prompt: Text("e.g. Teen: no profanity"))
            }
            Section {
                LinesEditor(lines: $world.rules, addLabel: "Add Rule", prompt: "A rule every character follows")
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules are added to every character's instructions.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("World")
    }
}

struct EditorHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Character

struct CharacterEditor: View {
    @Binding var character: CharacterProfile
    @Binding var portrait: Data?
    let project: NPCProject
    let diagnostics: [ProjectDiagnostic]
    @State private var idDraft = ""
    @FocusState private var idFocused: Bool

    private static let voices: [(id: String, name: String, language: Language)] = [
        ("af_heart", "Heart (female)", .english), ("af_bella", "Bella (female)", .english),
        ("am_michael", "Michael (male)", .english), ("am_fenrir", "Fenrir (male)", .english),
        ("jf_alpha", "Alpha (female)", .japanese), ("jf_tebukuro", "Tebukuro (female)", .japanese),
        ("jm_kumo", "Kumo (male)", .japanese),
    ]

    var body: some View {
        Form {
            Section {
                header
            }
            Section("Identity") {
                TextField("Name", text: $character.displayName)
                TextField("Role", text: $character.role, prompt: Text("e.g. innkeeper"))
                ProseField(title: "Persona", text: $character.persona, prompt: "Who they are, in a sentence or two")
                // Committed on Return or when the field loses focus: the window finds this
                // editor (and the portrait) by id, so renaming per keystroke lost the editor.
                TextField("ID", text: $idDraft)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .focused($idFocused)
                    .onSubmit(commitID)
                    .onChange(of: idFocused) { if !idFocused { commitID() } }
                    .onAppear { idDraft = character.id }
                    .onChange(of: character.id) { if !idFocused { idDraft = character.id } }
            }
            Section("Personality") {
                StackedRow(title: "Traits") {
                    TagEditor(tags: $character.traits, placeholder: "Add a trait and press Return", tint: character.tint)
                }
                TextField("Current mood", text: $character.mood, prompt: Text("Set by the game at runtime, or a default"))
                ProseField(title: "Speech style", text: $character.speechStyle, prompt: "Register, verbal tics, sentence length")
            }
            Section("Goals") {
                LinesEditor(lines: $character.goals, addLabel: "Add Goal", prompt: "Something they want right now")
            }
            Section("Relationships") {
                ForEach($character.relationships, id: \.self) { $rel in
                    HStack(alignment: .firstTextBaseline) {
                        Picker("", selection: $rel.target) {
                            Text("The player").tag("player")
                            ForEach(project.characters.filter { $0.id != character.id }) { other in
                                Text(other.displayName).tag(other.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .frame(width: 180, alignment: .leading)
                        TextField("", text: $rel.description, prompt: Text("How they see them"), axis: .vertical)
                            .labelsHidden()
                    }
                }
                .onDelete { character.relationships.remove(atOffsets: $0) }
                Button {
                    character.relationships.append(Relationship(target: "player", description: ""))
                } label: {
                    Label("Add Relationship", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            Section("Voice") {
                Picker("Language", selection: $character.language) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: character.language) { _, lang in
                    if !Self.voices.contains(where: { $0.id == character.voice && $0.language == lang }) {
                        character.voice = Self.voices.first { $0.language == lang }?.id ?? character.voice
                    }
                }
                Picker("Voice", selection: $character.voice) {
                    ForEach(Self.voices.filter { $0.language == character.language }, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
            }
            Section {
                StackedRow(title: "Emotions", caption: character.allowedEmotions.isEmpty ? "All allowed" : "\(character.allowedEmotions.count) of \(Emotion.allCases.count)") {
                    ChipPicker(all: Emotion.allCases, selection: $character.allowedEmotions) { $0.rawValue }
                }
                StackedRow(title: "Intents", caption: character.allowedIntents.isEmpty ? "All allowed" : "\(character.allowedIntents.count) of \(Intent.allCases.count)") {
                    ChipPicker(all: Intent.allCases, selection: $character.allowedIntents) { $0.rawValue }
                }
                StackedRow(title: "Never discuss", caption: "The model is told to deflect") {
                    TagEditor(tags: $character.forbiddenTopics, placeholder: "Add a topic", tint: .orange)
                }
                StackedRow(title: "Never say", caption: "Lines containing these are rejected") {
                    TagEditor(tags: $character.forbiddenTerms, placeholder: "Add a word or phrase", tint: .pink)
                }
                LabeledContent("Max line length") {
                    HStack(spacing: 8) {
                        Text(character.maxLineCharacters == 0 ? "Default (\(character.language == .japanese ? 90 : 220))" : "\(character.maxLineCharacters) characters")
                            .monospacedDigit()
                        Stepper("Max line length", value: $character.maxLineCharacters, in: 0...400, step: 10).labelsHidden()
                    }
                }
            } header: {
                Text("Constraints")
            } footer: {
                Text("Constraints are enforced after generation. A line that breaks one is replaced by a fallback line.")
            }
            Section {
                ForEach($character.fallbacks, id: \.self) { $f in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField("", text: $f.text, prompt: Text("Line"), axis: .vertical).labelsHidden()
                        Picker("", selection: $f.intent) {
                            ForEach(Intent.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Picker("", selection: $f.emotion) {
                            ForEach(Emotion.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .onDelete { character.fallbacks.remove(atOffsets: $0) }
                Button {
                    character.fallbacks.append(FallbackLine(text: ""))
                } label: {
                    Label("Add Fallback Line", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Fallback lines")
            } footer: {
                Text("Hand-written lines used when the model is unavailable, too slow, or its line is rejected.")
            }
            if !project.commands.isEmpty {
                Section("Game commands") {
                    ForEach(project.commands) { cmd in
                        Toggle(isOn: Binding(
                            get: { character.commands.contains(cmd.kind) },
                            set: { on in
                                if on { character.commands.append(cmd.kind) } else { character.commands.removeAll { $0 == cmd.kind } }
                            })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cmd.kind).font(.body.monospaced())
                                Text(cmd.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(character.displayName)
    }

    private func commitID() {
        let id = idDraft.trimmingCharacters(in: .whitespaces)
        if id.isEmpty || project.characters.contains(where: { $0.id == id && $0.id != character.id }) {
            idDraft = character.id   // empty or taken: keep the old id
        } else if id != character.id {
            character.id = id
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PortraitPicker(character: character, portrait: $portrait, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(character.displayName).font(.title2.weight(.semibold))
                if !character.role.isEmpty {
                    Text(character.role).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Badge(text: character.language.displayName, systemImage: "character.bubble")
                    Badge(text: Self.voices.first { $0.id == character.voice }?.name ?? character.voice, systemImage: "waveform", tint: character.tint)
                    let errors = diagnostics.filter { $0.severity == .error }.count
                    if errors > 0 {
                        Badge(text: "\(errors) issue\(errors == 1 ? "" : "s")", systemImage: "exclamationmark.octagon.fill", tint: .red)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Facts

struct FactsView: View {
    @Binding var facts: [Fact]
    let characters: [CharacterProfile]
    @State private var selection: Fact.ID?

    var body: some View {
        VSplitView {
            Table(facts, selection: $selection) {
                TableColumn("Fact") { f in
                    Text(f.text).lineLimit(2).help(f.text)
                }
                .width(min: 200)
                TableColumn("Known by") { f in
                    Text(f.knownBy.isEmpty ? "Everyone" : f.knownBy.map(name).joined(separator: ", "))
                        .foregroundStyle(f.knownBy.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                }
                .width(min: 90, ideal: 130, max: 220)
                TableColumn("Unlocked by") { f in
                    Text(f.requiredFlags.isEmpty ? "Always" : f.requiredFlags.joined(separator: ", "))
                        .font(f.requiredFlags.isEmpty ? .body : .callout.monospaced())
                        .foregroundStyle(f.requiredFlags.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(f.requiredFlags.joined(separator: ", "))
                }
                .width(min: 80, ideal: 120, max: 200)
                TableColumn("Salience") { f in
                    Gauge(value: f.salience) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(.accentColor)
                        .accessibilityLabel("Salience \(Int(f.salience * 100)) percent")
                }
                .width(60)
            }
            .contextMenu(forSelectionType: Fact.ID.self) { ids in
                Button("Delete", role: .destructive) { facts.removeAll { ids.contains($0.id) } }
            }
            .onDeleteCommand { if let selection { facts.removeAll { $0.id == selection } } }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240, maxHeight: 340)

            Group {
                if let i = facts.firstIndex(where: { $0.id == selection }) {
                    FactDetail(fact: $facts[i], characters: characters)
                } else {
                    ContentUnavailableView("No Fact Selected", systemImage: "book.closed",
                                           description: Text("Select a fact to edit who knows it and when it unlocks."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button(action: addFact) { Label("Add Fact", systemImage: "plus") }
                    .help("Add a fact")
            }
        }
        .navigationSubtitle("Facts & Lore")
    }

    private func addFact() {
        var n = facts.count + 1
        while facts.contains(where: { $0.id == "fact\(n)" }) { n += 1 }
        facts.append(Fact(id: "fact\(n)", text: "Something characters might know."))
        selection = "fact\(n)"
    }

    private func name(_ id: String) -> String { characters.first { $0.id == id }?.displayName ?? id }
}

struct FactDetail: View {
    @Binding var fact: Fact
    let characters: [CharacterProfile]

    var body: some View {
        Form {
            Section {
                ProseField(title: "Fact", text: $fact.text, prompt: "Written in the language of the characters who know it")
                TextField("ID", text: $fact.id).font(.body.monospaced()).foregroundStyle(.secondary)
                LabeledContent("Salience") {
                    HStack {
                        Slider(value: $fact.salience, in: 0...1)
                        Text(fact.salience, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section {
                StackedRow(title: "Known by", caption: fact.knownBy.isEmpty ? "Everyone (common knowledge)" : nil) {
                    ChipPicker(all: characters.map(\.id), selection: $fact.knownBy) { id in
                        characters.first { $0.id == id }?.displayName ?? id
                    }
                }
                StackedRow(title: "Unlocked by flags", caption: "All must be set by the game; until then the fact is a secret") {
                    TagEditor(tags: $fact.requiredFlags, placeholder: "Add a progress flag", tint: .purple)
                }
                StackedRow(title: "Leak keywords", caption: "Lines that mention these are rejected while the fact is secret") {
                    TagEditor(tags: $fact.leakKeywords, placeholder: "Add a revealing word or phrase", tint: .pink)
                }
                StackedRow(title: "Topic tags", caption: "Match player topics to rank this fact higher") {
                    TagEditor(tags: $fact.tags, placeholder: "Add a tag", tint: .teal)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Commands

struct CommandsView: View {
    @Binding var commands: [CommandSpec]

    var body: some View {
        Form {
            Section {
                EditorHeader(title: "Game Commands",
                             subtitle: "Actions characters may propose. Your game validates and runs them.",
                             systemImage: "bolt.fill", tint: .orange)
            }
            ForEach($commands) { $cmd in
                Section {
                    TextField("Kind", text: $cmd.kind).font(.body.monospaced())
                    TextField("Description", text: $cmd.description, prompt: Text("Shown to the model"))
                    StackedRow(title: "Targets", caption: cmd.targets.isEmpty ? "No target" : nil) {
                        TagEditor(tags: $cmd.targets, placeholder: "Add a target id", tint: .orange)
                    }
                }
            }
            Section {
                Button {
                    commands.append(CommandSpec(kind: "new_command", description: ""))
                } label: {
                    Label("Add Command", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Commands")
    }
}

// MARK: - Inspector

struct DiagnosticsInspector: View {
    let diagnostics: [ProjectDiagnostic]
    let decodeError: String?
    let focus: String?
    let select: (SidebarItem) -> Void

    private var shown: [ProjectDiagnostic] {
        guard let focus else { return diagnostics }
        return diagnostics.filter { $0.path.hasPrefix(focus) }
    }

    var body: some View {
        List {
            Section {
                if let decodeError {
                    Label(decodeError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                } else if shown.isEmpty {
                    Label(focus == nil ? "No issues in this project" : "No issues here", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(shown, id: \.self) { d in
                        Button {
                            if let item = item(for: d.path) { select(item) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: d.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(d.severity == .error ? .red : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.message)
                                    Text(d.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Checks")
            }
            if focus != nil && diagnostics.count != shown.count {
                Section {
                    Text("\(diagnostics.count - shown.count) more elsewhere in the project")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func item(for path: String) -> SidebarItem? {
        if path.hasPrefix("characters/"), let id = path.dropFirst("characters/".count).split(separator: ".").first {
            return .character(String(id))
        }
        if path.hasPrefix("facts.json") { return .facts }
        if path.hasPrefix("commands.json") { return .commands }
        return nil
    }
}
