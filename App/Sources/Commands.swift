import SwiftUI

/// What the menu bar can do in the focused project window. One instance per window, never
/// replaced: a focused value that changes on every render (a struct of closures) made the
/// toolbar re-vend its items on each render until AppKit aborted the layout loop (crash).
@MainActor final class WindowActions {
    var select: (SidebarItem) -> Void = { _ in }
    var newCharacter: () -> Void = {}
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// Menu commands: New Character, and ⌘1–⌘7 to jump between the sidebar's sections.
struct NPCVoiceCommands: Commands {
    @FocusedValue(\.windowActions) private var actions

    private static let sections: [(String, SidebarItem)] = [
        ("Playground", .playground), ("Voice Lab", .voiceLab), ("Bake Lines", .bake),
        ("World", .world), ("Facts & Lore", .facts), ("Commands", .commands), ("Pronunciations", .pronunciations),
    ]

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .newItem) {
            Button("New Character") { actions?.newCharacter() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(actions == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(Self.sections.enumerated()), id: \.offset) { n, section in
                Button(section.0) { actions?.select(section.1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n + 1))), modifiers: .command)
                    .disabled(actions == nil)
            }
            Divider()
        }
    }
}
