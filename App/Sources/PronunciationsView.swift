import NPCKit
import NPCSpeech
import SwiftUI

/// Author pronunciations for names and invented words, plus suggestions for words the
/// English G2P doesn't know (it would otherwise guess them from lexicon pieces).
struct PronunciationsView: View {
    @Binding var pronunciations: [Pronunciation]
    let project: NPCProject
    let runtime: ModelRuntime
    @State private var suggestions: [Suggestion] = []
    @State private var scanning = true

    struct Suggestion: Identifiable, Hashable { let word: String; let guess: String; var id: String { word } }

    var body: some View {
        Form {
            Section {
                EditorHeader(title: "Pronunciations",
                             subtitle: "How speech says names and invented words, in Kokoro's phoneme alphabet",
                             systemImage: "character.phonetic", tint: .pink)
            }
            Section {
                if pronunciations.isEmpty {
                    Text("No overrides yet. Add one below or from the suggestions.").foregroundStyle(.secondary)
                }
                if !pronunciations.isEmpty {
                    HStack(spacing: 10) {
                        Text("Word").frame(width: 150, alignment: .leading)
                        Text("Pronunciation")
                        Spacer()
                        Text("Language")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                ForEach($pronunciations) { $p in
                    HStack(spacing: 10) {
                        TextField("Word", text: $p.word, prompt: Text("Name"))
                            .labelsHidden().frame(width: 150)
                        // System font, not monospaced: it draws IPA stress marks (ˈ ˌ) clearly.
                        TextField("Pronunciation", text: $p.phonemes, prompt: Text("e.g. Okˈɑfɔɹ"))
                            .labelsHidden()
                        Picker("", selection: $p.language) {
                            ForEach(Language.allCases) { Text($0 == .english ? "EN" : "JA").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        listenButton(p.word, language: p.language, id: p.id)
                    }
                }
                .onDelete { pronunciations.remove(atOffsets: $0) }
                Button {
                    pronunciations.append(Pronunciation(word: "", phonemes: ""))
                } label: { Label("Add Pronunciation", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderless)
            } header: {
                Text("Overrides")
            } footer: {
                Text("Stress marks: ˈ primary, ˌ secondary. Diphthongs are single letters: A (day), I (my), O (go), W (now), Y (boy). Example: Okafor → Okˈɑfɔɹ.")
            }
            Section {
                if scanning {
                    // No ProgressView here: an indeterminate spinner inside a grouped Form row
                    // looped AppKit's update-constraints pass (crash).
                    Label("Checking names in this project…", systemImage: "hourglass").foregroundStyle(.secondary)
                } else if suggestions.isEmpty {
                    Label("Every English word in this project has a known pronunciation.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                ForEach(suggestions) { s in
                    HStack(spacing: 10) {
                        Text(s.word).frame(width: 150, alignment: .leading)
                        Text(s.guess).foregroundStyle(.secondary)
                        Spacer()
                        listenButton(s.word, language: .english, id: "suggest:" + s.word)
                        Button("Add") {
                            pronunciations.append(Pronunciation(word: s.word, phonemes: s.guess))
                            suggestions.removeAll { $0 == s }
                        }
                    }
                }
            } header: {
                Text("Suggested")
            } footer: {
                Text("Names that aren't in the English lexicon. Speech currently guesses them from known word pieces (shown); add one to fix it.")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle("Pronunciations")
        .task(id: scanKey) { await scan() }
    }

    private func listenButton(_ word: String, language: Language, id: String) -> some View {
        Button {
            Task { await runtime.speakText(word, voice: language == .japanese ? "jf_alpha" : "af_heart",
                                           overrides: project.pronunciationMap(language), id: id) }
        } label: {
            Image(systemName: runtime.speakingKey == id ? "speaker.wave.2.fill" : "speaker.wave.2")
                .symbolEffect(.variableColor.iterative, isActive: runtime.speakingKey == id)
        }
        .buttonStyle(.borderless)
        .disabled(word.isEmpty)
        .help("Listen")
        .accessibilityLabel("Listen to \(word)")
    }

    /// Re-scan when text that could contain names changes.
    private var scanKey: String {
        project.characters.map { $0.displayName + $0.role + $0.persona }.joined() + project.facts.map(\.text).joined()
            + project.world.setting + pronunciations.map(\.word).joined()
    }

    private func scan() async {
        scanning = true
        let english = project.characters.filter { $0.language == .english }
        var text = english.map { "\($0.displayName). \($0.role). \($0.persona)." }.joined(separator: " ")
        text += " " + project.facts.map(\.text).filter { $0.unicodeScalars.allSatisfy(\.isASCII) }.joined(separator: " ")
        text += " " + project.world.name + ". " + project.world.setting
        let known = Set(pronunciations.map { $0.word.lowercased() })
        let found = await runtime.unknownEnglishWords(in: text)
        // Only real words: Latin letters (apostrophes/hyphens inside), two or more letters.
        suggestions = found.filter { w in
            !known.contains(w.word.lowercased()) && w.word.count >= 2
                && w.word.allSatisfy { ($0.isLetter && $0.isASCII) || $0 == "'" || $0 == "-" }
        }.map { Suggestion(word: $0.word, guess: $0.guess) }
        scanning = false
    }
}
