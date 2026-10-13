import NPCKit
import NPCSpeech
import SwiftUI
import UniformTypeIdentifiers

/// Audition voices on a line: waveform, lip-sync track, loudness and timing; export WAV + JSON.
struct VoiceLabView: View {
    let project: NPCProject
    let runtime: ModelRuntime
    @State private var text = "Evening, love. A room costs three silver marks a night."
    @State private var voice = "af_heart"
    @State private var speed = 1.0
    @State private var result: VoiceLabResult?
    @State private var working = false
    @State private var error: String?
    @State private var exporting = false

    struct VoiceInfo: Identifiable { let id: String; let name: String; let detail: String; let japanese: Bool }
    static let voices: [VoiceInfo] = [
        .init(id: "af_heart", name: "Heart", detail: "Warm female", japanese: false),
        .init(id: "af_bella", name: "Bella", detail: "Bright female", japanese: false),
        .init(id: "am_michael", name: "Michael", detail: "Steady male", japanese: false),
        .init(id: "am_fenrir", name: "Fenrir", detail: "Rough male", japanese: false),
        .init(id: "jf_alpha", name: "Alpha", detail: "女性", japanese: true),
        .init(id: "jf_tebukuro", name: "Tebukuro", detail: "女性 · CC BY", japanese: true),
        .init(id: "jm_kumo", name: "Kumo", detail: "男性 · CC BY", japanese: true),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                EditorHeader(title: "Voice Lab", subtitle: "Audition voices, inspect lip-sync and loudness, export assets",
                             systemImage: "waveform", tint: .indigo)
                lineEditor
                voicePicker
                controls
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let result { ResultPanel(result: result, runtime: runtime, export: { exporting = true }) }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationSubtitle("Voice Lab")
        .task {
            // Debug/screenshot hook: `-NPCVoiceAutoRun 1` synthesizes on appear (never plays).
            if UserDefaults.standard.bool(forKey: "NPCVoiceAutoRun") && result == nil { await synthesize() }
        }
        .fileExporter(isPresented: $exporting, document: result.map(LineAssets.init), contentType: .folder,
                      defaultFilename: "line") { _ in }
    }

    private var japanese: Bool { Self.voices.first { $0.id == voice }?.japanese ?? false }

    private var lineEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line").font(.headline)
            TextEditor(text: $text)
                .font(.title3)
                .frame(minHeight: 70, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            if !project.characters.isEmpty {
                HStack(spacing: 6) {
                    Text("Try a fallback line:").font(.caption).foregroundStyle(.secondary)
                    ForEach(project.characters.prefix(4)) { c in
                        if let line = c.fallbacks.first?.text {
                            Button(c.displayName) { text = line; voice = c.voice }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice").font(.headline)
            ForEach([false, true], id: \.self) { ja in
                HStack(spacing: 10) {
                    Text(ja ? "Japanese" : "English").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    ForEach(Self.voices.filter { $0.japanese == ja }) { v in
                        Button { voice = v.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name).font(.callout.weight(.semibold))
                                Text(v.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 118, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(voice == v.id ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(voice == v.id ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(voice == v.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Label("Speed", systemImage: "speedometer").foregroundStyle(.secondary)
            // No `step:` (it draws a tick per step); round to 0.05 instead.
            Slider(value: Binding(get: { speed }, set: { speed = ($0 * 20).rounded() / 20 }), in: 0.5...2)
                .frame(width: 220)
                .accessibilityLabel("Speed")
                .accessibilityValue(String(format: "%.2f times", speed))
            Text(speed, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 40)
            Spacer()
            Button {
                Task { await synthesize() }
            } label: {
                Label(working ? "Synthesizing…" : "Synthesize", systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Synthesize (⌘↩)")
            .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func synthesize() async {
        working = true; error = nil
        defer { working = false }
        do {
            let lang: Language = japanese ? .japanese : .english
            result = try await runtime.synthesize(text, voice: voice, speed: speed, overrides: project.pronunciationMap(lang))
        } catch { self.error = "\(error)" }
    }
}

struct VoiceLabResult: Sendable {
    let line: SpokenLine
    let voice: String
    let text: String
    let synthesisSeconds: Double
    var rtf: Double { synthesisSeconds / max(line.duration, 0.001) }
}

private struct ResultPanel: View {
    let result: VoiceLabResult
    let runtime: ModelRuntime
    let export: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Result").font(.headline)
                Spacer()
                Button {
                    runtime.play(result.line)
                } label: { Label("Play", systemImage: "play.fill") }
                Button(action: export) { Label("Export…", systemImage: "square.and.arrow.up") }
            }
            WaveformView(samples: result.line.pcm, visemes: result.line.visemes, duration: result.line.duration)
                .frame(height: 150)
            HStack(spacing: 22) {
                stat("Duration", String(format: "%.2f s", result.line.duration))
                stat("Synthesis", String(format: "%.2f s · %.2f× real time", result.synthesisSeconds, result.rtf))
                stat("Loudness", String(format: "%.1f → −23 LUFS", result.line.loudness.integratedLUFS))
                stat("Visemes", "\(result.line.visemes.count)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Phonemes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(result.line.phonemes).textSelection(.enabled)
            }
            if !result.line.unknownWords.isEmpty {
                Label("Guessed (not in lexicon): \(result.line.unknownWords.joined(separator: ", ")). Fix them in Pronunciations.",
                      systemImage: "character.phonetic")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

/// Peak envelope with the viseme track drawn beneath on the same time axis.
struct WaveformView: View {
    let samples: [Float]
    let visemes: [VisemeSegment]
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            let waveHeight = size.height - 30
            let mid = waveHeight / 2
            let columns = max(1, Int(size.width / 2))
            let per = max(1, samples.count / columns)
            var path = Path()
            for c in 0..<columns {
                let start = c * per
                guard start < samples.count else { break }
                var peak: Float = 0
                for i in start..<min(start + per, samples.count) { peak = max(peak, abs(samples[i])) }
                let h = CGFloat(min(1, peak * 2.2)) * mid
                let x = CGFloat(c) * 2 + 1
                path.addRoundedRect(in: CGRect(x: x - 0.75, y: mid - h, width: 1.5, height: max(1, h * 2)), cornerSize: CGSize(width: 0.75, height: 0.75))
            }
            ctx.fill(path, with: .linearGradient(Gradient(colors: [.indigo, .purple]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            // Viseme strip.
            for v in visemes where v.viseme != .silence {
                let x0 = CGFloat(v.start / duration) * size.width, x1 = CGFloat(v.end / duration) * size.width
                let rect = CGRect(x: x0, y: waveHeight + 8, width: max(1, x1 - x0 - 1), height: 18)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color(v.viseme).opacity(Double(0.35 + 0.5 * v.weight))))
                if rect.width > 16 {
                    ctx.draw(Text(v.viseme.rawValue).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white), at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
        }
        .accessibilityLabel("Waveform with \(visemes.count) visemes over \(String(format: "%.1f", duration)) seconds")
    }

    private func color(_ v: Viseme) -> Color {
        switch v {
        case .aa, .E, .ih, .oh, .ou: .indigo
        case .PP, .FF, .TH: .pink
        case .DD, .kk, .SS, .CH: .teal
        case .RR, .Y: .orange
        case .silence: .gray
        }
    }
}

/// Export bundle: line.wav + line.lipsync.json in a folder.
struct LineAssets: FileDocument {
    static let readableContentTypes: [UTType] = [.folder]
    let result: VoiceLabResult
    init(_ r: VoiceLabResult) { result = r }
    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        struct Sidecar: Encodable { let text: String; let voice: String; let phonemes: String; let duration: Double
            let visemes: [VisemeSegment]; let phonemeTrack: [PhonemeSegment] }
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = try e.encode(Sidecar(text: result.text, voice: result.voice, phonemes: result.line.phonemes, duration: result.line.duration,
                                        visemes: result.line.visemes, phonemeTrack: result.line.phonemeTrack))
        return FileWrapper(directoryWithFileWrappers: [
            "line.wav": FileWrapper(regularFileWithContents: WAV.data(result.line.pcm, sampleRate: result.line.sampleRate)),
            "line.lipsync.json": FileWrapper(regularFileWithContents: json),
        ])
    }
}
