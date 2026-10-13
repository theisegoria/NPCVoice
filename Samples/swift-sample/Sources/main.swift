// Uses only the binary NPCVoiceKit.xcframework (no NPCVoice sources).
// Usage: swift-sample <project.npcproj> <models folder>
import Foundation
import NPCVoiceKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: swift-sample <project.npcproj> <models folder>"); exit(64) }
let runtime = try await NPCVoiceRuntime(project: URL(filePath: args[1]), model: .bundled(modelsFolder: URL(filePath: args[2])))

var state = NPCGameState()
state.location = "The Gull & Lantern, common room"
let line = try await runtime.respond(character: "marta", playerSays: "Evening. Got a room for the night?", state: state, deadline: .seconds(10))
print("\(line.character): \(line.text)")
print("  [\(line.emotion) · \(line.intent) · \(line.source) · \(line.latency)]")
for c in line.commands { print("  → \(c.kind)(\(c.target))") }

let speech = try runtime.speak(line)
print("speech: \(String(format: "%.2f", Double(speech.samples.count) / speech.sampleRate)) s, \(speech.visemes.count) visemes; first: \(speech.visemes.prefix(4).map(\.name))")
