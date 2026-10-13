import SwiftUI

/// Ways the Inbox can look, to try side by side (Developer → Inbox Style)
enum InboxStyle: String, CaseIterable, Identifiable {
    case current, activity, cards, mail, sections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current"
        case .activity: "A · Activity List"
        case .cards: "B · Notification Cards"
        case .mail: "C · Mail Style"
        case .sections: "D · Needs You First"
        }
    }
}

/// The one obvious answer to a notification, and clearing it, shared by
/// every style
@MainActor
struct InboxQuickAction {
    let item: InboxItem
    let inbox: InboxStore
    let actions: Actions
    let session: SessionStore
    let friends: FriendsStore

    private var friend: Friend? { item.senderId.flatMap { friends.friends[$0] } }

    var title: String? {
        switch item.kind {
        case .invite: item.location == nil ? nil : "Join"
        case .inviteRequest: session.me?.location == nil || friend == nil ? nil : "Invite"
        case .friendRequest: "Accept"
        default: nil
        }
    }

    var symbol: String {
        switch item.kind {
        case .invite: "paperplane.fill"
        case .inviteRequest: "envelope.fill"
        default: "checkmark"
        }
    }

    func perform() async {
        switch item.kind {
        case .invite:
            guard let location = item.location else { return }
            await actions.inviteMyself(to: location, worldName: nil)
            await inbox.markSeen(item)
        case .inviteRequest:
            guard let location = session.me?.location, let friend else { return }
            await actions.invite(friend, to: location)
            try? await inbox.dismiss(item)
        case .friendRequest:
            do {
                try await inbox.acceptFriendRequest(item)
                actions.show("You're now friends with \(item.senderName ?? "them")")
            } catch {
                actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
            }
        default:
            break
        }
    }

    func clear() async {
        do {
            try await inbox.dismiss(item)
        } catch {
            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }
}

/// A notification's picture and words, shared by the styles below
@MainActor
private struct InboxParts {
    let item: InboxItem
    let friends: FriendsStore

    var friend: Friend? { item.senderId.flatMap { friends.friends[$0] } }

    var isGroup: Bool {
        if case .v2 = item.source { return true }
        return false
    }

    var name: String {
        item.displayName ?? friend?.name ?? (isGroup ? "Group Notice" : "VRChat")
    }

    var worldName: String? {
        item.location.flatMap { friends.world(for: Location($0))?.name }
    }

    /// "invited you to Pixel Arcade", to follow a name in a sentence
    var action: String {
        let line = isGroup ? (item.note ?? "") : item.headline(worldName: worldName)
        guard let first = line.first, !isGroup else { return line }
        return first.lowercased() + line.dropFirst()
    }

    /// "Invite · Pixel Arcade", for a summary line
    var kindName: String {
        switch item.kind {
        case .invite: "Invite"
        case .inviteRequest: "Invite request"
        case .friendRequest: "Friend request"
        case .inviteResponse, .requestResponse: "Reply"
        case .message: "Message"
        case .group: "Group"
        case .other: "Notice"
        }
    }

    var shortTime: String {
        guard let date = item.date else { return "" }
        return date.shortAgo.replacingOccurrences(of: " Ago", with: "").replacingOccurrences(of: "Just Now", with: "now")
    }

    @ViewBuilder
    func picture(size: CGFloat) -> some View {
        if let id = item.senderId {
            AvatarView(id: id, name: name, urls: friend?.user.imageURLs(size: 256) ?? [], size: size)
        } else {
            RemoteImage(url: groupImage.map { VRChatImage.sized($0, 256) }) {
                ZStack {
                    Color.accentColor.opacity(0.2)
                    Image(systemName: isGroup ? "person.3.fill" : "bell.fill").foregroundStyle(.tint)
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.29, style: .continuous))
        }
    }

    var groupImage: String? {
        if case .v2(let n) = item.source { return n.imageUrl }
        return nil
    }
}

private struct UnreadDot: View {
    let visible: Bool

    var body: some View {
        Circle()
            .fill(visible ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
            .accessibilityHidden(!visible)
            .accessibilityLabel("Unread")
    }
}

// MARK: A · Activity list

/// One line like a sentence, and one button: like Instagram's activity
struct ActivityInboxRow: View {
    let item: InboxItem
    let openDetail: (InboxItem) -> Void
    @Environment(InboxStore.self) private var inbox
    @Environment(FriendsStore.self) private var friends
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions

    var body: some View {
        let parts = InboxParts(item: item, friends: friends)
        let quick = InboxQuickAction(item: item, inbox: inbox, actions: actions, session: session, friends: friends)
        HStack(alignment: .center, spacing: 12) {
            parts.picture(size: 42)
            VStack(alignment: .leading, spacing: 2) {
                (Text(parts.name).fontWeight(.semibold)
                    + Text(parts.isGroup ? "  " : " ")
                    + Text(parts.isGroup ? "" : parts.action)
                    + Text("  \(parts.shortTime)").foregroundStyle(.secondary))
                    .font(.subheadline)
                    .lineLimit(2)
                if let note = parts.isGroup ? item.note : item.note.map({ "“\($0)”" }), !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(parts.isGroup ? 2 : 1)
                }
            }
            Spacer(minLength: 4)
            if let title = quick.title {
                Button(title) { Task { await quick.perform() } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else if !item.seen {
                UnreadDot(visible: true)
            }
        }
        .contentShape(.rect)
        .onTapGesture { openDetail(item) }
    }
}

// MARK: B · Notification cards

/// Like Notification Centre: what it is and when, then the content, then
/// the buttons along the bottom
struct CardInboxRow: View {
    let item: InboxItem
    let openDetail: (InboxItem) -> Void
    @Environment(InboxStore.self) private var inbox
    @Environment(FriendsStore.self) private var friends
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions

    var body: some View {
        let parts = InboxParts(item: item, friends: friends)
        let quick = InboxQuickAction(item: item, inbox: inbox, actions: actions, session: session, friends: friends)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(parts.kindName.uppercased())
                Text("·")
                Text(parts.shortTime)
                Spacer()
                UnreadDot(visible: !item.seen)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            HStack(alignment: .top, spacing: 10) {
                parts.picture(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parts.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(parts.isGroup ? (item.note ?? "") : [item.headline(worldName: parts.worldName), item.note.map { "“\($0)”" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .contentShape(.rect)
            .onTapGesture { openDetail(item) }
            Divider().padding(.top, 10)
            HStack(spacing: 0) {
                if let title = quick.title {
                    Button(title) { Task { await quick.perform() } }
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                    Divider()
                }
                Button(parts.isGroup ? "More…" : "Clear") {
                    if parts.isGroup { openDetail(item) } else { Task { await quick.clear() } }
                }
                .frame(maxWidth: .infinity)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .frame(height: 40)
        }
    }
}

// MARK: C · Mail style

/// Calm two-line rows; tap one for everything and its buttons
struct MailInboxRow: View {
    let item: InboxItem
    let openDetail: (InboxItem) -> Void
    @Environment(FriendsStore.self) private var friends

    var body: some View {
        let parts = InboxParts(item: item, friends: friends)
        HStack(spacing: 10) {
            UnreadDot(visible: !item.seen)
            parts.picture(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(parts.name).font(.body.weight(item.seen ? .regular : .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(parts.shortTime).font(.caption).foregroundStyle(.secondary)
                }
                Text(summary(parts))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(.rect)
        .onTapGesture { openDetail(item) }
    }

    private func summary(_ parts: InboxParts) -> String {
        if parts.isGroup { return item.note ?? "" }
        return [parts.kindName, parts.worldName ?? item.location.map { _ in "an instance" }, item.note.map { "“\($0)”" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: D · Needs you first

/// Something to answer, with round buttons: clear, and the answer
struct NeedsYouInboxRow: View {
    let item: InboxItem
    let openDetail: (InboxItem) -> Void
    @Environment(InboxStore.self) private var inbox
    @Environment(FriendsStore.self) private var friends
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions

    var body: some View {
        let parts = InboxParts(item: item, friends: friends)
        let quick = InboxQuickAction(item: item, inbox: inbox, actions: actions, session: session, friends: friends)
        HStack(spacing: 12) {
            parts.picture(size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(parts.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(parts.shortTime).font(.caption).foregroundStyle(.secondary)
                }
                Text([item.headline(worldName: parts.worldName), item.note.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .contentShape(.rect)
            .onTapGesture { openDetail(item) }
            Spacer(minLength: 4)
            Button {
                Task { await quick.clear() }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.fill.tertiary, in: .circle)
            }
            .accessibilityLabel(item.kind == .invite ? "Clear" : "Decline")
            if quick.title != nil {
                Button {
                    Task { await quick.perform() }
                } label: {
                    Image(systemName: quick.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: .circle)
                }
                .accessibilityLabel(quick.title ?? "")
            }
        }
        .buttonStyle(.plain)
    }
}

/// Everything about one notification, with all its answers: what the
/// calmer styles open on a tap
struct InboxDetailSheet: View {
    let item: InboxItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                InboxRow(item: item) { _ in dismiss() }
            }
            .navigationTitle(item.displayName ?? "Notification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
