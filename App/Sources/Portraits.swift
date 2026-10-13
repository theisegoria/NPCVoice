import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import NPCKit

/// Character portraits: any image the author picks, stored in the project package as
/// `portraits/<character id>.png` (the core ignores the folder; it is authoring art only).
enum Portrait {
    static let maxPixels = 512

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file isn't an image NPCVoice can read." }
    }

    /// Any image file → PNG, at most 512 px on its longer side, orientation applied.
    static func normalize(contentsOf url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }
}

extension EnvironmentValues {
    /// Decoded portraits by character id, for `Avatar`.
    @Entry var portraits: [String: NSImage] = [:]
}

/// The character editor's avatar: click to choose a picture, drop an image file on it,
/// or use the context menu to remove it.
struct PortraitPicker: View {
    let character: CharacterProfile
    @Binding var portrait: Data?
    var size: CGFloat = 64
    @State private var importing = false
    @State private var hovering = false
    @State private var targeted = false
    @State private var failure: String?

    var body: some View {
        Button { importing = true } label: {
            Avatar(character: character, size: size)
                .overlay {
                    if hovering || targeted {
                        ZStack {
                            Circle().fill(.black.opacity(0.42))
                            Image(systemName: portrait == nil ? "photo.badge.plus" : "photo")
                                .font(.system(size: size * 0.28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity)
                    }
                }
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: targeted ? 3 : 0))
                .animation(.easeOut(duration: 0.15), value: hovering || targeted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(portrait == nil ? "Add a picture: click, or drop an image here" : "Change the picture")
        .accessibilityLabel(portrait == nil ? "Add picture" : "Change picture")
        .accessibilityAction(named: "Remove Picture") { portrait = nil }
        .contextMenu {
            Button("Choose Picture…") { importing = true }
            if portrait != nil { Button("Remove Picture", role: .destructive) { portrait = nil } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { load(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { targeted = $0 }
        .alert("Couldn't use that picture", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { portrait = try Portrait.normalize(contentsOf: url) } catch { failure = error.localizedDescription }
    }
}
