import SwiftUI
import NPCKit

enum SidebarItem: Hashable {
    case playground, voiceLab, bake, world, facts, commands, pronunciations
    case character(String)

    /// Debug/screenshot hook names: `playground|voicelab|bake|world|facts|commands|pronunciations|<character id>`.
    init(screen: String?) {
        switch screen {
        case "playground": self = .playground
        case "facts": self = .facts
        case "commands": self = .commands
        case "pronunciations": self = .pronunciations
        case "voicelab": self = .voiceLab
        case "bake": self = .bake
        case nil, "world": self = .world
        case let id?: self = .character(id)
        }
    }
}

struct ContentView: View {
    @Binding var document: ProjectDocument
    // Every window opens on World, with the inspector presented. Opening on a screen that
    // hides the inspector (Playground, Voice Lab, Bake) and presenting it later for the first
    // time loops AppKit's update-constraints pass (crash, macOS 27.0.1). Once it has been
    // presented, hiding and showing it again is fine.
    @State private var selection: SidebarItem? = .world
    @State private var playground = PlaygroundModel()
    @State private var bake = BakeModel()
    @AppStorage(Preferences.onboardedKey) private var onboarded = false
    // Debug/screenshot hook: `-NPCVoiceShowOnboarding 1` shows the welcome sheet again.
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: Preferences.onboardedKey)
        || UserDefaults.standard.bool(forKey: "NPCVoiceShowOnboarding")
    @Environment(\.openSettings) private var openSettings
    @State private var showInspector = true
    @State private var actions = WindowActions()
    @State private var diagnostics: [ProjectDiagnostic] = []
    @State private var decodeError: String?

    @FocusState private var sidebarFocused: Bool

    private var project: NPCProject { document.project }

    /// Writes only real changes: text fields re-commit identical values on focus
    /// changes, which would otherwise mark the document as edited. A character id edited
    /// in place carries its portrait and the sidebar selection along.
    private var model: Binding<NPCProject> {
        Binding(get: { document.project }, set: { edited in
            guard edited != document.project else { return }
            var new = edited
            let old = document.project.characters
            if old.count == new.characters.count {
                for (a, b) in zip(old, new.characters) where a.id != b.id {
                    if let data = document.portraits.removeValue(forKey: a.id) { document.portraits[b.id] = data }
                    if selection == .character(a.id) { selection = .character(b.id) }
                    // References elsewhere in the project follow the rename.
                    for i in new.facts.indices { new.facts[i].knownBy = new.facts[i].knownBy.map { $0 == a.id ? b.id : $0 } }
                    for i in new.characters.indices {
                        for r in new.characters[i].relationships.indices where new.characters[i].relationships[r].target == a.id {
                            new.characters[i].relationships[r].target = b.id
                        }
                    }
                }
            }
            document.project = new
        })
    }

    @State private var portraitImages: [String: NSImage] = [:]
    @State private var pendingDelete: CharacterProfile?

    var body: some View {
        NavigationSplitView {
            Sidebar(project: project, diagnostics: diagnostics, selection: $selection, addCharacter: addCharacter,
                    deleteCharacter: { pendingDelete = $0 })
                .focused($sidebarFocused)
                .task {
                    // After the window picks its first responder (otherwise the first
                    // text field in the detail form grabs focus with its text selected).
                    try? await Task.sleep(for: .milliseconds(80))
                    sidebarFocused = true
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        // The project-checks inspector is for editing; the Playground has its own side panel.
        .inspector(isPresented: Binding(get: { showInspector && selection != .playground && selection != .voiceLab && selection != .bake },
                                        set: { showInspector = $0 })) {
            DiagnosticsInspector(diagnostics: diagnostics, decodeError: decodeError, focus: focusPath, select: { selection = $0 })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
        .toolbar {
            if selection != .playground && selection != .voiceLab && selection != .bake {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the project checks (⌥⌘I)")
            }
            }
        }
        .navigationTitle(project.name.isEmpty ? "Untitled" : project.name)
        .environment(\.portraits, portraitImages)
        .onChange(of: document.portraits, initial: true) {
            portraitImages = document.portraits.compactMapValues { NSImage(data: $0) }
        }
        .confirmationDialog("Delete \(pendingDelete?.displayName ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { c in
            Button("Delete Character", role: .destructive) { delete(c) }
        } message: { _ in
            Text("Their profile, fallback lines and picture are removed from the project. Facts they know stay.")
        }
        .focusedSceneValue(\.windowActions, actions)
        .sheet(isPresented: $showWelcome, onDismiss: { onboarded = true }) {
            OnboardingView(runtime: playground.runtime) {
                showWelcome = false
                selection = .playground
            }
        }
        .onChange(of: onboarded) { if !onboarded { showWelcome = true } }   // Settings › Show Welcome Again
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("dev.npcvoice.screen"))) { note in
            selection = SidebarItem(screen: note.object as? String)
        }
        #endif
        .onAppear {
            actions.select = { selection = $0 }
            actions.newCharacter = addCharacter
        }
        .task {
            // Debug/screenshot hook: `-NPCVoiceScreen <screen>` (see SidebarItem.init(screen:)),
            // applied after the first layout so the inspector has been presented once.
            if let screen = UserDefaults.standard.string(forKey: "NPCVoiceScreen") {
                try? await Task.sleep(for: .milliseconds(300))
                selection = SidebarItem(screen: screen)
            }
        }
        #if DEBUG
        .task {
            // Debug hook: `-NPCVoicePortrait <character id>=<image path>` imports a picture the
            // way the character editor's picker does (for testing without the file panel).
            if let spec = UserDefaults.standard.string(forKey: "NPCVoicePortrait"), let eq = spec.firstIndex(of: "=") {
                let id = String(spec[..<eq]), path = String(spec[spec.index(after: eq)...])
                document.portraits[id] = try? Portrait.normalize(contentsOf: URL(filePath: path))
            }
        }
        #endif
        .task {
            // Debug/screenshot hook: `-NPCVoiceOpenSettings 1`.
            if UserDefaults.standard.bool(forKey: "NPCVoiceOpenSettings") { openSettings() }
        }
        .task(id: project) {
            try? await Task.sleep(for: .milliseconds(150))
            do {
                diagnostics = try project.diagnostics()
                decodeError = nil
            } catch {
                decodeError = "\(error)"
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .playground:
            PlaygroundView(project: project, model: playground)
        case .world, .none:
            WorldEditor(world: model.world, projectName: model.name)
        case .facts:
            FactsView(facts: model.facts, characters: project.characters)
        case .commands:
            CommandsView(commands: model.commands)
        case .voiceLab:
            VoiceLabView(project: project, runtime: playground.runtime)
        case .bake:
            BakeView(project: model, runtime: playground.runtime, model: bake)
        case .pronunciations:
            PronunciationsView(pronunciations: model.pronunciations, project: project, runtime: playground.runtime)
        case .character(let id):
            if let i = project.characters.firstIndex(where: { $0.id == id }) {
                CharacterEditor(character: model.characters[i],
                                portrait: Binding(get: { document.portraits[id] }, set: { document.portraits[id] = $0 }),
                                project: project,
                                diagnostics: diagnostics.filter { $0.path.hasPrefix("characters/\(id).json") })
                    .id(id)
            } else {
                ContentUnavailableView("No Character", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
    }

    /// Path prefix of the diagnostics that belong to the current selection.
    private var focusPath: String? {
        switch selection {
        case .character(let id): "characters/\(id).json"
        case .facts: "facts.json"
        case .commands: "commands.json"
        case .pronunciations: "project.json: pronunciations"
        default: nil
        }
    }

    private func delete(_ c: CharacterProfile) {
        if selection == .character(c.id) { selection = .world }
        document.project.characters.removeAll { $0.id == c.id }
        document.portraits[c.id] = nil
    }

    private func addCharacter() {
        var n = 1
        while project.characters.contains(where: { $0.id == "character\(n)" }) { n += 1 }
        var c = CharacterProfile(id: "character\(n)", displayName: "New Character", voice: "af_heart", language: .english)
        c.fallbacks = [FallbackLine(text: "Not now.", intent: .deflect)]
        document.project.characters.append(c)
        selection = .character(c.id)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    let project: NPCProject
    let diagnostics: [ProjectDiagnostic]
    @Binding var selection: SidebarItem?
    let addCharacter: () -> Void
    let deleteCharacter: (CharacterProfile) -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Playground", systemImage: "bubble.left.and.text.bubble.right").tag(SidebarItem.playground)
                Label("Voice Lab", systemImage: "waveform").tag(SidebarItem.voiceLab)
                Label("Bake Lines", systemImage: "rectangle.stack.badge.plus").tag(SidebarItem.bake)
            }
            Section("Project") {
                Label("World", systemImage: "globe.europe.africa").tag(SidebarItem.world)
                Label {
                    HStack { Text("Facts & Lore"); Spacer(); count(project.facts.count) }
                } icon: { Image(systemName: "book.closed") }
                .tag(SidebarItem.facts)
                Label {
                    HStack { Text("Commands"); Spacer(); count(project.commands.count) }
                } icon: { Image(systemName: "bolt") }
                .tag(SidebarItem.commands)
                Label {
                    HStack { Text("Pronunciations"); Spacer(); count(project.pronunciations.count) }
                } icon: { Image(systemName: "character.phonetic") }
                .tag(SidebarItem.pronunciations)
            }
            Section("Characters") {
                ForEach(project.characters) { c in
                    CharacterRow(character: c, issues: issues(for: c))
                        .tag(SidebarItem.character(c.id))
                        .contextMenu {
                            Button("Delete Character…", role: .destructive) { deleteCharacter(c) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .character(let id)? = selection, let c = project.characters.first(where: { $0.id == id }) { deleteCharacter(c) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: addCharacter) {
                    Label("New Character", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a character (⌥⌘N)")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func issues(for c: CharacterProfile) -> ProjectDiagnostic.Severity? {
        let mine = diagnostics.filter { $0.path.hasPrefix("characters/\(c.id).json") }
        if mine.contains(where: { $0.severity == .error }) { return .error }
        return mine.isEmpty ? nil : .warning
    }
}

struct CharacterRow: View {
    let character: CharacterProfile
    let issues: ProjectDiagnostic.Severity?

    var body: some View {
        HStack(spacing: 10) {
            Avatar(character: character, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(character.displayName).lineLimit(1)
                if !character.role.isEmpty {
                    Text(character.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if character.language == .japanese {
                Text("JA").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let issues {
                Image(systemName: issues == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issues == .error ? .red : .orange)
                    .font(.caption)
                    .accessibilityLabel(issues == .error ? "Has errors" : "Has warnings")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
