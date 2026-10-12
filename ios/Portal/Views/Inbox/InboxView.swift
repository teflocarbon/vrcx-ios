import SwiftUI

/// Invites, invite requests, friend requests and group notices, each with
/// its answers right in the row, as the wrist expands them
struct InboxView: View {
    @Environment(InboxStore.self) private var inbox
    @Environment(FriendsStore.self) private var friends
    @State private var path: [Route] = []
    @State private var filter: InboxFilter = .all

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FilterChips(options: InboxFilter.allCases, selection: $filter, title: \.title) { option in
                        option == .unread ? inbox.unreadCount : nil
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)

                ConnectionBanner()

                let items = inbox.filtered(filter)
                Section {
                    ForEach(items) { item in
                        InboxRow(item: item) { path.append($0) }
                            .contextMenu {
                                InboxMenu(item: item) { path.append($0) }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { try? await inbox.dismiss(item) }
                                } label: {
                                    Label("Clear", systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if !item.seen {
                                    Button {
                                        Task { await inbox.markSeen(item) }
                                    } label: {
                                        Label("Read", systemImage: "envelope.open")
                                    }
                                    .tint(.accentColor)
                                }
                            }
                    }
                } footer: {
                    if !items.isEmpty {
                        Text("Clearing something here clears it in VRChat and VRCX too.")
                    }
                }
            }
            .overlay {
                let items = inbox.filtered(filter)
                if items.isEmpty && inbox.isLoading {
                    ProgressView()
                } else if items.isEmpty, let error = inbox.error {
                    ContentUnavailableView {
                        Label("Couldn't Load Your Inbox", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await inbox.refresh() } }
                    }
                } else if items.isEmpty {
                    ContentUnavailableView(
                        filter == .unread ? "All Caught Up" : "Nothing in Your Inbox",
                        systemImage: filter == .unread ? "checkmark.circle" : "tray",
                        description: Text("Invites, requests and group notices will show here.")
                    )
                }
            }
            .refreshable { await inbox.refresh() }
            .navigationTitle("Inbox")
            .toolbar {
                if inbox.unreadCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Mark All Read") {
                            Task { await inbox.markAllSeen() }
                        }
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, path: $path)
            }
        }
    }
}

/// One notification: who, what, when, their message, and the answers
struct InboxRow: View {
    let item: InboxItem
    let open: (Route) -> Void
    @Environment(InboxStore.self) private var inbox
    @Environment(FriendsStore.self) private var friends
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions

    private var friend: Friend? { item.senderId.flatMap { friends.friends[$0] } }
    private var worldName: String? {
        item.location.flatMap { friends.world(for: Location($0))?.name }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            picture
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.senderName ?? friend?.name ?? title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !item.seen {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                            .accessibilityLabel("Unread")
                    }
                    Spacer(minLength: 4)
                    if let date = item.date {
                        Text(date.shortAgo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if case .v1 = item.source {
                    Text(item.headline(worldName: worldName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let note = item.note, !note.isEmpty, item.kind != .group {
                    Text("“\(note)”")
                        .font(.subheadline)
                        .lineLimit(3)
                } else if item.kind == .group, let note = item.note {
                    ExpandableText(text: note, lineLimit: 2)
                        .font(.subheadline)
                }
                answers
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if let location = item.location { friends.requestWorld(Location(location).worldId) }
        }
    }

    /// A group notice leads with its own title ("Test Group posted an
    /// announcement"); anything else from no one is just a notification
    private var title: String {
        if case .v2(let n) = item.source, let title = n.title, !title.isEmpty { return title }
        return item.kind == .group ? "Group" : "Notification"
    }

    @ViewBuilder
    private var picture: some View {
        if let id = item.senderId {
            AvatarView(id: id, name: item.senderName ?? friend?.name ?? "?", urls: friend?.user.imageURLs(size: 256) ?? [], size: 44)
                .onTapGesture { open(.user(id)) }
        } else if case .v2(let n) = item.source {
            RemoteImage(url: n.imageUrl) {
                ZStack {
                    Color.accentColor.opacity(0.2)
                    Image(systemName: "person.3.fill").foregroundStyle(.tint)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var answers: some View {
        let busy = inbox.isBusy(item)
        HStack(spacing: 8) {
            switch item.kind {
            case .invite:
                if let location = item.location {
                    Button("Join") {
                        Task {
                            await actions.inviteMyself(to: location, worldName: item.headline(worldName: worldName))
                            await inbox.markSeen(item)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Clear") { Task { await clear() } }
                    .buttonStyle(.bordered)
            case .inviteRequest:
                if let location = session.me?.location, let friend {
                    Button("Send Invite") {
                        Task {
                            await actions.invite(friend, to: location)
                            try? await inbox.dismiss(item)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Decline") { Task { await clear() } }
                    .buttonStyle(.bordered)
            case .friendRequest:
                Button("Accept") {
                    Task {
                        do {
                            try await inbox.acceptFriendRequest(item)
                            actions.show("You're now friends with \(item.senderName ?? "them")")
                        } catch {
                            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Decline") { Task { await clear() } }
                    .buttonStyle(.bordered)
            case .group, .other:
                if case .v2(let n) = item.source {
                    ForEach(n.responses ?? [], id: \.self) { response in
                        Button(response.text ?? response.type.capitalized) {
                            Task {
                                do {
                                    try await inbox.respond(item, with: response)
                                } catch {
                                    actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if let link = n.link, let url = URL(string: link), url.scheme == "https" {
                        Link(n.linkText ?? "Open", destination: url)
                            .buttonStyle(.bordered)
                    }
                }
            default:
                EmptyView()
            }
            if busy {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        // Several buttons in one row: tapping the row mustn't press them all
        .buttonStyle(.borderless)
        .disabled(busy)
    }

    private func clear() async {
        do {
            try await inbox.dismiss(item)
        } catch {
            actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }
}

/// Press and hold on a notification
struct InboxMenu: View {
    let item: InboxItem
    let open: (Route) -> Void
    @Environment(InboxStore.self) private var inbox

    var body: some View {
        if let id = item.senderId {
            Button {
                open(.user(id))
            } label: {
                Label("Open Profile", systemImage: "person.crop.circle")
            }
        }
        if let location = item.location, Location(location).isInstance {
            Button {
                open(.instance(location))
            } label: {
                Label("View Instance", systemImage: "person.3")
            }
        }
        Section {
            if !item.seen {
                Button {
                    Task { await inbox.markSeen(item) }
                } label: {
                    Label("Mark as Read", systemImage: "envelope.open")
                }
            }
            if let note = item.note, !note.isEmpty {
                Button {
                    UIPasteboard.general.string = note
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
            }
        }
        Section {
            Button(role: .destructive) {
                Task { try? await inbox.dismiss(item) }
            } label: {
                Label("Clear", systemImage: "xmark")
            }
        }
    }
}
