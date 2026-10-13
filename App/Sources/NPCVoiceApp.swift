import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NPCKit

@main
struct NPCVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { file in
            // No explicit minWidth: the split view's own column minimums (sidebar 220 +
            // detail 520 + inspector 260) already bound it; a smaller window minimum
            // conflicts with them and loops AppKit's constraint pass (crash).
            ContentView(document: file.$document)
                .frame(minHeight: 600)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { NPCVoiceCommands() }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.applyAtLaunch()
        // Debug/screenshot hook: `-NPCVoiceAppearance dark|light` forces the app's
        // appearance without touching the system setting.
        switch UserDefaults.standard.string(forKey: "NPCVoiceAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #if DEBUG
        WindowSnapshot.install()
        #endif
    }
}

#if DEBUG
/// Debug/screenshot hook: the app renders its own windows to PNG, so visual checks work
/// while a window sits in Stage Manager's strip, on another Space, or the display sleeps
/// (and without Screen Recording permission).
/// - `-NPCVoiceSnapshot <dir>` writes every visible window once, after
///   `-NPCVoiceSnapshotDelay` seconds (default 6).
/// - The distributed notification `dev.npcvoice.snapshot` (object: a directory) writes again
///   on demand; `dev.npcvoice.screen` (object: a screen name) switches the sidebar. See tools/snap.sh.
enum WindowSnapshot {
    @MainActor static func install() {
        let defaults = UserDefaults.standard
        if let dir = defaults.string(forKey: "NPCVoiceSnapshot"), !dir.isEmpty {
            let delay = defaults.double(forKey: "NPCVoiceSnapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 6)) { write(to: dir) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.npcvoice.snapshot"), object: nil, queue: .main) { note in
            guard let dir = note.object as? String else { return }
            MainActor.assumeIsolated { write(to: dir) }
        }
    }

    /// Glass materials render flat, and the sidebar's vibrant text comes out dimmer than on
    /// screen (SwiftUI styles it for a live backdrop). Use these for layout, text and state.
    @MainActor static func write(to dir: String) {
        let folder = URL(filePath: dir, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            // The theme frame includes the title bar and toolbar; sheets are their own windows.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let all = descendants(of: view)
            func flip(_ r: NSRect) -> NSRect {
                view.isFlipped ? NSRect(x: r.minX, y: view.bounds.height - r.maxY, width: r.width, height: r.height) : r
            }
            // Glass panels draw nothing offscreen: paint the window colour behind whatever
            // was drawn there (destination-over fills only the transparent pixels).
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSGraphicsContext.current?.compositingOperation = .destinationOver
                for glass in all where String(describing: type(of: glass)) == "NSGlassEffectView" && !glass.isHiddenOrHasHiddenAncestor {
                    NSBezierPath(roundedRect: flip(glass.convert(glass.bounds, to: view)), xRadius: 18, yRadius: 18).fill()
                }
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            // Lists are outside the normal drawing pass: draw each one's rows and composite
            // them in place (only the rows, since the list scrolls under the title bar).
            for table in all.compactMap({ $0 as? NSTableView }) where !table.isHiddenOrHasHiddenAncestor && table.numberOfRows > 0 {
                let rows = table.rect(ofRow: 0).union(table.rect(ofRow: table.numberOfRows - 1))
                let visible = table.visibleRect.intersection(rows)
                guard !visible.isEmpty, let tableRep = table.bitmapImageRepForCachingDisplay(in: visible) else { continue }
                table.cacheDisplay(in: visible, to: tableRep)
                tableRep.draw(in: flip(table.convert(visible, to: view)), from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            let title = String((window.title.isEmpty ? (window.isSheet ? "sheet" : "window") : window.title)
                .map { $0.isLetter || $0.isNumber ? $0 : "-" })
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(i)-\(title).png"))
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
#endif
