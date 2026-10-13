import SwiftUI
import NPCKit

/// One exchange in the playground transcript.
struct Turn: Identifiable, Equatable {
    enum Kind: Equatable { case player(String), event(String), npc(DialogueResult, PreparedPrompt?), error(String) }
    let id = UUID()
    let kind: Kind
}

/// Runtime game state the playground passes with every call (what a game would own).
struct PlaygroundState: Equatable {
    var flags: Set<String> = []
    var location = ""
    var objective = ""
    var memories: [String] = []
}

@MainActor @Observable
final class PlaygroundModel {
    var transcripts: [String: [Turn]] = [:]
    var state = PlaygroundState()
    var busy = false
    var autoSpeak = false
    let runtime = ModelRuntime()

    func turns(for id: String) -> [Turn] { transcripts[id] ?? [] }

    func send(_ input: Turn.Kind, to character: CharacterProfile, in project: NPCProject) async {
        transcripts[character.id, default: []].append(Turn(kind: input))
        busy = true
        defer { busy = false }
        do {
            let engine = try await runtime.engine()
            var call: GameCall
            switch input {
            case .player(let line): call = GameCall(character: character.id, playerUtterance: line)
            case .event(let event): call = GameCall(character: character.id, trigger: event)
            default: return
            }
            call.flags = state.flags.sorted()
            call.location = state.location
            call.objective = state.objective
            call.memories = state.memories.filter { !$0.isEmpty }
            call.exchanges = exchanges(for: character.id)
            call.allowCache = false
            // An authoring tool, not a frame budget: give the model room (games default to 2.5 s).
            var budget = Budget(); budget.deadlineMs = Preferences.playgroundDeadlineMs
            call.budget = budget
            let request = try ProjectHandle(project: project).request(for: call)
            let prompt = try? request.preparedPrompt()
            let result = try await engine.respond(to: request)
            let turn = Turn(kind: .npc(result, prompt))
            transcripts[character.id, default: []].append(turn)
            if autoSpeak && result.status == .line { Task { await runtime.speak(result.line, id: turn.id) } }
        } catch {
            transcripts[character.id, default: []].append(Turn(kind: .error("\(error)")))
        }
    }

    func clear(_ id: String) { transcripts[id] = [] }

    /// Conversation history as the game would pass it (excluding the turn just sent).
    private func exchanges(for id: String) -> [Exchange] {
        turns(for: id).dropLast().compactMap { t in
            switch t.kind {
            case .player(let s): Exchange(.player, s)
            case .npc(let r, _): Exchange(.character, r.line.text)
            default: nil
            }
        }
    }
}

struct PlaygroundView: View {
    let project: NPCProject
    @Bindable var model: PlaygroundModel
    @State private var characterID: String?
    @State private var draft = ""
    @State private var showState = true
    @FocusState private var composerFocused: Bool

    private var character: CharacterProfile? {
        project.characters.first { $0.id == characterID } ?? project.characters.first
    }

    var body: some View {
        Group {
            if let character {
                // A plain HStack: HSplitView hosting a grouped Form loops AppKit's
                // constraint passes inside NavigationSplitView (crash on open).
                HStack(spacing: 0) {
                    conversation(with: character)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    if showState {
                        Divider()
                        GameStatePanel(project: project, state: $model.state)
                            .frame(width: 290)
                            .frame(maxHeight: .infinity)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.snappy, value: showState)
            } else {
                ContentUnavailableView("No Characters", systemImage: "person.2", description: Text("Add a character to start a conversation."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Character", selection: Binding(get: { character?.id ?? "" }, set: { characterID = $0 })) {
                    ForEach(project.characters) { c in
                        Text(c.displayName).tag(c.id)
                    }
                }
                .pickerStyle(.menu)
                .help("Who you are talking to")
                .accessibilityLabel("Character")
            }
            ToolbarItem {
                ModelStatusControl(runtime: model.runtime)
            }
            ToolbarItemGroup {
                Toggle(isOn: $model.autoSpeak) {
                    Label("Speak Replies", systemImage: model.autoSpeak ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .help("Speak each reply with the character's voice")
                Button {
                    if let id = character?.id { model.clear(id) }
                } label: {
                    Label("Clear Conversation", systemImage: "trash")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("Clear this conversation (⌘K)")
                Toggle(isOn: $showState) {
                    Label("Game State", systemImage: "slider.horizontal.3")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show the game state sent with each line (⌥⌘I)")
            }
        }
        .navigationSubtitle("Playground")
    }

    // MARK: Conversation

    private func conversation(with c: CharacterProfile) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ConversationHeader(character: c)
                            .padding(.bottom, 8)
                        ForEach(model.turns(for: c.id)) { turn in
                            TurnView(turn: turn, character: c, runtime: model.runtime).id(turn.id)
                        }
                        if model.busy {
                            TypingIndicator(character: c).id("typing")
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.turns(for: c.id).count) {
                    withAnimation(.snappy) { proxy.scrollTo(model.turns(for: c.id).last?.id, anchor: .bottom) }
                }
            }
            Composer(character: c, draft: $draft, busy: model.busy, focused: $composerFocused) { kind in
                Task { await model.send(kind, to: c, in: project) }
            }
        }
        .background(.background)
        .onAppear { composerFocused = true }
    }
}

struct ConversationHeader: View {
    let character: CharacterProfile

    var body: some View {
        VStack(spacing: 8) {
            Avatar(character: character, size: 64)
            Text(character.displayName).font(.title3.weight(.semibold))
            if !character.persona.isEmpty {
                Text(character.persona)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 6) {
                if !character.mood.isEmpty { Badge(text: character.mood, systemImage: "face.smiling") }
                Badge(text: character.language.displayName, systemImage: "character.bubble")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

struct TurnView: View {
    let turn: Turn
    let character: CharacterProfile
    let runtime: ModelRuntime
    @State private var showPrompt = false

    var body: some View {
        switch turn.kind {
        case .player(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor.gradient, in: BubbleShape(fromPlayer: true))
                    .foregroundStyle(.white)
                    .accessibilityLabel("You: \(text)")
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .event(let text):
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(text).italic()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Event: \(text)")
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        case .npc(let result, let prompt):
            HStack(alignment: .top, spacing: 10) {
                Avatar(character: character, size: 30)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(result.line.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.secondary.opacity(0.13), in: BubbleShape(fromPlayer: false))
                            .accessibilityLabel("\(character.displayName): \(result.line.text)")
                        Button {
                            if runtime.speaking == turn.id { runtime.stopSpeaking() }
                            else { Task { await runtime.speak(result.line, id: turn.id) } }
                        } label: {
                            Image(systemName: runtime.speaking == turn.id ? "stop.circle.fill" : "speaker.wave.2.circle")
                                .font(.title3)
                                .symbolEffect(.variableColor.iterative, isActive: runtime.speaking == turn.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(character.tint)
                        .help("Speak this line in \(character.displayName)'s voice")
                        .accessibilityLabel(runtime.speaking == turn.id ? "Stop" : "Speak line")
                    }
                    LineMeta(result: result)
                    if let prompt {
                        DisclosureGroup(isExpanded: $showPrompt) {
                            PromptInspector(prompt: prompt, result: result)
                        } label: {
                            Text("Prompt & grounding").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 60)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct LineMeta: View {
    let result: DialogueResult

    var body: some View {
        FlowLayout(spacing: 5) {
            Badge(text: result.line.emotion.rawValue, systemImage: "theatermasks", tint: .purple)
            Badge(text: result.line.intent.rawValue, systemImage: "arrow.turn.down.right", tint: .teal)
            ForEach(result.line.commands, id: \.self) { c in
                Badge(text: c.target.isEmpty ? c.kind : "\(c.kind) → \(c.target)", systemImage: "bolt.fill", tint: .orange)
            }
            source
            Text("\(Int(result.latencyMs.rounded())) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var source: some View {
        switch result.source {
        case .model: Badge(text: "model", systemImage: "cpu", tint: .green)
        case .cache: Badge(text: "cached", systemImage: "memorychip", tint: .blue)
        case .fallback:
            Badge(text: "fallback · \(result.fallbackReason.replacingOccurrences(of: "_", with: " "))",
                  systemImage: "arrow.uturn.backward", tint: .orange)
                .help(result.diagnostic)
        }
    }
}

struct PromptInspector: View {
    let prompt: PreparedPrompt
    let result: DialogueResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Instructions", prompt.instructions)
            section("Prompt", prompt.prompt)
            HStack(spacing: 16) {
                stat("Facts used", prompt.usedFactIds.isEmpty ? "none" : prompt.usedFactIds.joined(separator: ", "))
                stat("Guarded", prompt.withheldKeywords.isEmpty ? "none" : prompt.withheldKeywords.joined(separator: ", "))
                stat("Tokens", "~\(prompt.estimatedPromptTokens) in")
            }
            if !result.diagnostic.isEmpty { stat("Diagnostic", result.diagnostic) }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 4)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(body).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

struct TypingIndicator: View {
    let character: CharacterProfile
    @State private var phase = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(character: character, size: 30)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 7, height: 7)
                        .opacity(phase ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: phase)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.secondary.opacity(0.13), in: BubbleShape(fromPlayer: false))
        }
        .onAppear { phase = true }
        .accessibilityLabel("\(character.displayName) is replying")
    }
}

/// Message bubble with a flattened corner on the speaker's side.
struct BubbleShape: Shape {
    let fromPlayer: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16, small: CGFloat = 5
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: fromPlayer ? r : small, bottomLeading: r,
            bottomTrailing: r, topTrailing: fromPlayer ? small : r), style: .continuous)
    }
}

// MARK: - Composer

struct Composer: View {
    let character: CharacterProfile
    @Binding var draft: String
    let busy: Bool
    var focused: FocusState<Bool>.Binding
    let send: (Turn.Kind) -> Void
    @State private var showEvent = false
    @State private var eventText = ""

    private static let sampleEvents = [
        "The player walks in, soaked from the rain.",
        "The player drops a heavy coin purse on the counter.",
        "A bell rings eight times across the harbor.",
        "The player draws a knife.",
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Menu {
                ForEach(Self.sampleEvents, id: \.self) { e in
                    Button(e) { send(.event(e)) }
                }
                Divider()
                Button("Custom Event…") { showEvent = true }
            } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel("Trigger Event")
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Trigger a game event instead of speaking")
            .disabled(busy)

            TextField("Say something to \(character.displayName)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .accessibilityLabel("Message to \(character.displayName)")
                .focused(focused)
                .onSubmit(submit)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [])
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .popover(isPresented: $showEvent, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What just happened?").font(.headline)
                TextField("e.g. The player hands over a sealed letter.", text: $eventText, axis: .vertical)
                    .lineLimit(2...4)
                    .frame(width: 320)
                HStack {
                    Spacer()
                    Button("Trigger") {
                        let e = eventText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !e.isEmpty { send(.event(e)) }
                        eventText = ""; showEvent = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }

    private var canSend: Bool { !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit() {
        guard canSend else { return }
        send(.player(draft.trimmingCharacters(in: .whitespacesAndNewlines)))
        draft = ""
    }
}

// MARK: - Game state

struct GameStatePanel: View {
    let project: NPCProject
    @Binding var state: PlaygroundState

    /// Every progress flag the project's facts mention.
    private var knownFlags: [String] {
        Array(Set(project.facts.flatMap(\.requiredFlags))).sorted()
    }

    var body: some View {
        Form {
            Section {
                TextField("Location", text: $state.location, prompt: Text("e.g. The Gull & Lantern"))
                TextField("Objective", text: $state.objective, prompt: Text("The player's current goal"))
            } header: {
                Text("Scene")
            }
            Section {
                if knownFlags.isEmpty {
                    Text("No facts in this project are gated by flags.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(knownFlags, id: \.self) { flag in
                    Toggle(isOn: Binding(get: { state.flags.contains(flag) },
                                         set: { if $0 { state.flags.insert(flag) } else { state.flags.remove(flag) } })) {
                        Text(flag).font(.callout.monospaced())
                    }
                }
            } header: {
                Text("Progress flags")
            } footer: {
                Text("Set flags unlock secret facts for the characters who know them.")
            }
            Section("Memories of the player") {
                LinesEditor(lines: $state.memories, addLabel: "Add Memory", prompt: "e.g. The player paid on time")
            }
        }
        .formStyle(.grouped)
    }
}
