import SwiftUI
import NPCKit

// MARK: - Character identity

extension CharacterProfile {
    /// Stable tint per character, so an NPC keeps its colour across every screen.
    var tint: Color {
        // No red: it reads as an error state next to validation badges.
        let palette: [Color] = [.blue, .purple, .orange, .teal, .indigo, .green, .mint, .cyan, .brown]
        let hash = id.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }

    var monogram: String {
        let words = displayName.split(separator: " ").filter { $0.first?.isUppercase ?? true }
        let letters = words.count >= 2 ? [words.first!, words.last!].compactMap(\.first) : Array(displayName.prefix(1))
        return String(letters).uppercased()
    }
}

struct Avatar: View {
    let character: CharacterProfile
    var size: CGFloat = 28
    @Environment(\.portraits) private var portraits

    var body: some View {
        Group {
            if let portrait = portraits[character.id] {
                Image(nsImage: portrait)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                Text(character.monogram)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(character.tint.gradient, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tags

/// Editable list of short strings shown as chips (traits, flags, forbidden terms...).
struct TagEditor: View {
    @Binding var tags: [String]
    var placeholder: String
    var tint: Color = .accentColor
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                HStack(spacing: 4) {
                    Text(tag).lineLimit(1)
                    Button {
                        tags.remove(at: index)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(tag)")
                }
                .font(.callout)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                // Primary text on a tinted fill stays legible in light and dark.
                .background(tint.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.5))
                .foregroundStyle(.primary)
                // One VoiceOver stop per tag, with Remove as an action.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tag)
                .accessibilityAction(named: "Remove") { tags.remove(at: index) }
            }
            // A prompt, not a title: in a grouped Form a title renders as a row label.
            TextField(placeholder, text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .frame(minWidth: 170)
                .focused($focused)
                .onSubmit(commit)
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts where !tags.contains(p) { tags.append(p) }
        draft = ""
        focused = true
    }
}

/// Multi-select of a fixed vocabulary; an empty selection means "all allowed".
struct ChipPicker<Item: Hashable>: View {
    let all: [Item]
    @Binding var selection: [Item]
    let label: (Item) -> String

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(all, id: \.self) { item in
                let on = selection.isEmpty || selection.contains(item)
                Button {
                    toggle(item)
                } label: {
                    Text(label(item))
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(on ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: Capsule())
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.35) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func toggle(_ item: Item) {
        var current = selection.isEmpty ? all : selection
        if let i = current.firstIndex(of: item) { current.remove(at: i) } else { current.append(item) }
        // Keep vocabulary order; "everything selected" is stored as empty (= all).
        current = all.filter(current.contains)
        selection = current.count == all.count ? [] : current
    }
}

// MARK: - Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > maxWidth {
                let y = rows[rows.count - 1].y + rows[rows.count - 1].height + spacing
                rows.append(Row(y: y))
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

// MARK: - Rows

/// A form row with its label above full-width content (chips, long lists).
struct StackedRow<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Misc

struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// Multi-line prose: label above, full-width left-aligned text below.
struct ProseField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...8)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Edits a list of sentences (rules, goals) one per row.
struct LinesEditor: View {
    @Binding var lines: [String]
    var addLabel: String
    var prompt: String

    var body: some View {
        ForEach(lines.indices, id: \.self) { i in
            HStack(alignment: .firstTextBaseline) {
                TextField("", text: Binding(get: { lines[i] }, set: { lines[i] = $0 }), prompt: Text(prompt), axis: .vertical)
                    .labelsHidden()
                Button(role: .destructive) {
                    lines.remove(at: i)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        Button {
            lines.append("")
        } label: {
            Label(addLabel, systemImage: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
    }
}
