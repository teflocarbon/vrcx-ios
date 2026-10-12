import SwiftUI

/// The App Store's strip of small facts under a header: a label, a value,
/// and a detail, in calm columns divided by thin rules
struct StatsStrip: View {
    struct Item: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        var detail: String?
        var color: Color?
    }

    let items: [Item]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().frame(height: 40).padding(.top, 6)
                    }
                    // Every column the same shape, detail or not, so they line up
                    VStack(spacing: 4) {
                        Text(item.label.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.headline)
                            .foregroundStyle(item.color ?? .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(item.detail ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 104)
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

/// Text cut to a few lines, with "more" only when it's actually cut
struct ExpandableText: View {
    let text: String
    var lineLimit = 4
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(expanded ? nil : lineLimit)
                .background {
                    // Measure the text both ways to know whether it's cut
                    ZStack {
                        Text(text).fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                        Text(text).lineLimit(lineLimit)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                    }
                    .hidden()
                }
                .textSelection(.enabled)
            if !expanded && fullHeight > limitedHeight + 1 {
                Button("more") {
                    withAnimation(.snappy) { expanded = true }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

/// A row for copying an ID: shown short, copied whole
struct CopyRow: View {
    let label: String
    let value: String

    var body: some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            LabeledContent(label) {
                HStack(spacing: 6) {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc")
                        .imageScale(.small)
                }
                .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }
}

/// The trust rank VRChat shows, from someone's tags
struct TrustRank {
    let name: String
    let color: Color

    init(tags: [String]?) {
        let tags = Set(tags ?? [])
        let rank: (String, Color)
        if tags.contains("system_trust_veteran") {
            rank = ("Trusted User", Color(light: 0x7A4FB8, dark: 0xB18FFF))
        } else if tags.contains("system_trust_trusted") {
            rank = ("Known User", Color(light: 0xD0702F, dark: 0xFF7B42))
        } else if tags.contains("system_trust_known") {
            rank = ("User", Color(light: 0x2E9466, dark: 0x2BCF5C))
        } else if tags.contains("system_trust_basic") {
            rank = ("New User", Color(light: 0x2F7FD0, dark: 0x1778FF))
        } else {
            rank = ("Visitor", .secondary)
        }
        name = rank.0
        color = rank.1
    }
}

/// Spoken languages from someone's tags ("language_eng")
func languages(from tags: [String]?) -> [String] {
    let signed = ["ase": "American Sign Language", "bfi": "British Sign Language", "dse": "Dutch Sign Language",
                  "fsl": "French Sign Language", "kvk": "Korean Sign Language"]
    return (tags ?? []).compactMap { tag in
        guard tag.hasPrefix("language_") else { return nil }
        let code = String(tag.dropFirst("language_".count))
        return signed[code] ?? Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}

/// Small things side by side, wrapping onto the next line when they run
/// out of room: badges under a name
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
