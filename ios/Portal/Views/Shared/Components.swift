import SwiftUI

/// A small coloured capsule for state: "Can Join", "Favourite", "Unread"
struct Badge: View {
    let text: String
    let color: Color
    var symbol: String?

    init(_ text: String, color: Color, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: .capsule)
        .fixedSize()
    }
}

/// A message about something that went wrong
struct ErrorRow: View {
    let message: String

    var body: some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
    }
}

/// A picture from VRChat or the relay, loaded and cached by `ImageLoader`
struct RemoteImage<Placeholder: View>: View {
    /// Tried in order until one loads
    let urls: [String]
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: String?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        urls = url.map { [$0] } ?? []
        self.placeholder = placeholder
    }

    init(urls: [String], @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.urls = urls.filter { !$0.isEmpty }
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: urls) {
            if let cached = urls.lazy.compactMap({ ImageLoader.shared.cached($0) }).first {
                image = cached
                return
            }
            // A picture already showing stays until another has loaded:
            // swapping to links that then fail mustn't blank it
            if let loaded = await ImageLoader.shared.image(urls) {
                image = loaded
            }
        }
    }
}

/// Someone's picture as a rounded square, as on the wrist, or their initial
/// on their colour when there's no picture
struct AvatarView: View {
    let id: String
    let name: String
    let urls: [String]
    var size: CGFloat = 48
    var status: UserStatus?

    init(id: String, name: String, url: String?, size: CGFloat = 48, status: UserStatus? = nil) {
        self.init(id: id, name: name, urls: url.map { [$0] } ?? [], size: size, status: status)
    }

    init(id: String, name: String, urls: [String], size: CGFloat = 48, status: UserStatus? = nil) {
        self.id = id
        self.name = name
        self.urls = urls
        self.size = size
        self.status = status
    }

    /// Someone's own pictures, at a size to suit
    init(user: VRCUser, size: CGFloat = 48, status: UserStatus? = nil) {
        self.init(id: user.id, name: user.name, urls: user.imageURLs(size: size > 64 ? 512 : 256), size: size, status: status)
    }

    var body: some View {
        RemoteImage(urls: urls) {
            ZStack {
                Palette.tone(for: id)
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.29, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .overlay(alignment: .bottomTrailing) {
            if let status {
                StatusDot(status: status, size: max(10, size * 0.26))
                    .padding(2)
                    .background(Color(uiColor: .systemBackground), in: .circle)
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A world's picture, landscape, or a globe while there isn't one
struct WorldImage: View {
    let url: String?
    var cornerRadius: CGFloat = 12

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.15)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "globe.americas.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A presence dot: filled for in the game, a ring for online elsewhere
/// (website or app), as the wrist draws "active"
struct StatusDot: View {
    let status: UserStatus
    var hollow = false
    var size: CGFloat = 9

    var body: some View {
        Group {
            if hollow {
                Circle().strokeBorder(status.color, lineWidth: max(1.5, size * 0.22))
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// "Can Join", "Can Request", "Cannot Join"
struct AccessBadge: View {
    let access: Access

    var body: some View {
        Badge(access.label, color: access.color, symbol: access.symbol)
    }
}

/// A list's filters as a row of chips, as in WarpSign's library: a symbol,
/// a name and how many each has, filled with the accent when chosen, and
/// quieter when empty
struct FilterChips<Value: Hashable & Identifiable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String
    var count: ((Value) -> Int?)?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                chips
            }
            .scrollClipDisabled()
            // The chosen chip is always in view, even one far along the row
            .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
            .onChange(of: selection) { _, chosen in
                withAnimation(.snappy) { proxy.scrollTo(chosen.id, anchor: .center) }
            }
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                let selected = option == selection
                let number = count?(option)
                Button {
                    withAnimation(.snappy) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(option))
                        Text(title(option))
                        if let number {
                            Text("\(number)")
                                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: Capsule())
                }
                .buttonStyle(.plain)
                // An empty filter is still choosable, just quieter
                .opacity(number == 0 && !selected ? 0.5 : 1)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .id(option.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

/// An icon and some text, for a row inside `LabeledContent` (a `Label`
/// there leaves an odd gap)
struct IconText: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text)
        }
    }
}

extension Date {
    /// "Just Now", "5m Ago", "3h Ago", "2d Ago", as on the wrist
    var shortAgo: String {
        let seconds = max(0, Date().timeIntervalSince(self))
        switch seconds {
        case ..<60: return "Just Now"
        case ..<3_600: return "\(Int(seconds / 60))m Ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h Ago"
        case ..<604_800: return "\(Int(seconds / 86_400))d Ago"
        default: return "\(Int(seconds / 604_800))w Ago"
        }
    }

    /// "1h 20m", "12m", for how long someone's been somewhere
    var durationSince: String {
        let minutes = max(0, Int(Date().timeIntervalSince(self) / 60))
        if minutes < 1 { return "Just Arrived" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// VRChat's timestamps: ISO 8601, with or without fractional seconds
    init?(vrchat string: String?) {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            self = date
            return
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { return nil }
        self = date
    }
}

extension Error {
    /// What went wrong, in words for the UI rather than a debug description
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
