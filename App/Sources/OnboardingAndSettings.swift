import AppKit
import NPCKit
import NPCMLX
import NPCSpeech
import SwiftUI

// MARK: - Preferences (read at launch, before any model loads)

enum Preferences {
    static let modelsFolderKey = "NPCVoiceModelsFolder"
    static let mlxCacheKey = "NPCVoiceMLXCacheMB"
    static let defaultBackendKey = "NPCVoiceDefaultBackend"
    static let playgroundDeadlineKey = "NPCVoicePlaygroundDeadline"
    static let onboardedKey = "NPCVoiceOnboarded"

    /// Model lookups read these environment variables; set them from preferences first.
    static func applyAtLaunch() {
        let d = UserDefaults.standard
        if let folder = d.string(forKey: modelsFolderKey), !folder.isEmpty { setenv("NPCVOICE_MODELS", folder, 1) }
        let mb = d.integer(forKey: mlxCacheKey)
        if mb > 0 { setenv("NPCVOICE_MLX_CACHE_MB", String(mb), 1) }
    }

    static var playgroundDeadlineMs: Int {
        let s = UserDefaults.standard.double(forKey: playgroundDeadlineKey)
        return Int((s > 0 ? s : 15) * 1000)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    let runtime: ModelRuntime
    let done: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to NPCVoice").font(.largeTitle.weight(.semibold))
                Text("Characters that react, talk and lip-sync — all on this Mac.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("person.text.rectangle", .teal, "Write who they are",
                        "Personalities, goals, secrets and hard limits. Every line is checked against them before it's spoken.")
                feature("bubble.left.and.text.bubble.right", .indigo, "Talk to them",
                        "The Playground runs the bundled model on-device. Change game flags and memories and watch them react.")
                feature("waveform", .pink, "Give them a voice",
                        "Natural speech with a lip-sync track, in English and Japanese. Bake approved lines into game assets.")
            }
            .frame(maxWidth: 460)
            modelStatus
            Button(action: done) {
                Text("Get Started").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(36)
        .frame(width: 560)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelStatus: some View {
        HStack(spacing: 8) {
            switch runtime.status {
            case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .loading: Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .unavailable: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
            Text("\(runtime.backend.title): \(runtime.status.label)").foregroundStyle(.secondary)
        }
        .font(.callout)
        .task { await runtime.prepare() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    // Debug/screenshot hook: `-NPCVoiceSettingsTab general|models`.
    @State private var tab = UserDefaults.standard.string(forKey: "NPCVoiceSettingsTab") ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ModelSettings().tabItem { Label("Models", systemImage: "shippingbox") }.tag("models")
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Preferences.defaultBackendKey) private var backend = DialogueBackendChoice.mlx.rawValue
    @AppStorage(Preferences.playgroundDeadlineKey) private var deadline = 15.0
    @AppStorage(Preferences.onboardedKey) private var onboarded = false

    var body: some View {
        Form {
            Section {
                Picker("Default dialogue model", selection: $backend) {
                    ForEach(DialogueBackendChoice.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                LabeledContent("Playground reply deadline") {
                    HStack {
                        // No `step:` — it draws a tick for every half second.
                        Slider(value: Binding(get: { deadline }, set: { deadline = ($0 * 2).rounded() / 2 }), in: 2.5...30)
                            .frame(width: 180)
                            .accessibilityValue("\(deadline, specifier: "%.1f") seconds")
                        Text("\(deadline, specifier: "%.1f") s").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Games default to 2.5 s so a slow line falls back instead of stalling a frame; the Playground can wait longer.")
            }
            Section {
                LabeledContent("Welcome screen") {
                    Button("Show Again") { onboarded = false }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)   // size the Settings window to the form
    }
}

private struct ModelSettings: View {
    @AppStorage(Preferences.modelsFolderKey) private var folder = ""
    @AppStorage(Preferences.mlxCacheKey) private var cacheMB = 256

    private static let required = ["qwen3.5-2b-4bit", "kokoro-82m-coreml", "misaki-en", "misaki-ja"]

    private var resolved: String {
        if !folder.isEmpty { return folder }
        return SpeechSynthesizer.defaultModelsDirectory()?.path ?? "Not found"
    }

    private func present(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(filePath: resolved).appending(path: name).path)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models folder")
                    Text((resolved as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(resolved)
                }
                ForEach(Self.required, id: \.self) { name in
                    LabeledContent {
                        Text(present(name) ? "Found" : "Missing").foregroundStyle(present(name) ? Color.secondary : Color.orange)
                    } label: {
                        Label {
                            Text(name).font(.callout.monospaced())
                        } icon: {
                            Image(systemName: present(name) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(present(name) ? Color.green : Color.orange)
                        }
                    }
                }
                HStack {
                    Button("Choose…") { choose() }
                    if !folder.isEmpty { Button("Use Bundled") { folder = "" } }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: resolved)])
                    }
                    .disabled(resolved == "Not found")
                }
            } footer: {
                Text("Changes apply on next launch.")
            }
            Section {
                Picker("MLX buffer cache", selection: $cacheMB) {
                    ForEach([128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) MB").tag($0) }
                }
            } footer: {
                Text("The dialogue model shares unified memory with your game. A small cache keeps the model near 2.5 GB; larger caches can be slightly faster. Applies on next launch.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
