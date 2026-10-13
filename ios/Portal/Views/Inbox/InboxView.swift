import SwiftUI

/// Invites, invite requests, friend requests and group notices, each with
/// its answers right in the row, as the wrist expands them; and, with a
/// relay that keeps it, everything that came before
struct InboxView: View {
    @Environment(InboxStore.self) private var inbox
    @Environment(NotificationHistoryStore.self) private var history
    @Environment(FriendsStore.self) private var friends
    @State private var path: [Route] = []
    @State private var filter: InboxFilter = Demo.isOn && Demo.screen == .history ? .history : .all

    /// History only when the relay keeps it
    private var filters: [InboxFilter] {
        InboxFilter.allCases.filter { $0 != .history || history.available }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FilterChips(options: filters, selection: $filter, title: \.title, symbol: \.symbol) { option in
                        option == .history ? nil : inbox.filtered(option).count
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)

                ConnectionBanner()

                if filter == .history {
                    historySections
                } else {
                    liveSection
                }
            }
            .overlay { emptyState }
            .refreshable {
                async let live: Void = inbox.refresh()
                async let past: Void = history.refresh()
                _ = await (live, past)
            }
            .navigationTitle("Inbox")
            .toolbar {
                if inbox.unreadCount > 0 && filter != .history {
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
            .task { await history.refresh() }
        }
    }

    @ViewBuilder
    private var liveSection: some View {
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

    /// Past notifications by day, as they ended up: answered, cleared, seen
    @ViewBuilder
    private var historySections: some View {
        let calendar = Calendar.current
        let days = Dictionary(grouping: history.entries) { calendar.startOfDay(for: $0.date) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Section(Self.dayTitle(day)) {
                ForEach(days[day]!.sorted { $0.date > $1.date }) { entry in
                    InboxRow(item: entry.item, history: entry) { path.append($0) }
                        .contextMenu {
                            InboxMenu(item: entry.item, past: true) { path.append($0) }
                        }
                }
            }
        }
        if history.hasMore && !history.entries.isEmpty {
            Section {
                Button {
                    Task { await history.loadEarlier() }
                } label: {
                    HStack {
                        Text("Load Earlier")
                        Spacer()
                        if history.isLoading { ProgressView() }
                    }
                }
            } footer: {
                Text("Your relay keeps every notification, including ones VRChat no longer has, and VRCX's own history once it's imported.")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if filter == .history {
            if history.entries.isEmpty && history.isLoading {
                ProgressView()
            } else if history.entries.isEmpty, let error = history.error {
                ContentUnavailableView {
                    Label("Couldn't Load History", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await history.refresh() } }
                }
            } else if history.entries.isEmpty {
                ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Notifications your relay sees, and VRCX's once they're imported, will show here."))
            }
        } else {
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
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(date: .long, time: .omitted)
    }
}

/// One notification: who, what, when, their message, and the answers
struct InboxRow: View {
    let item: InboxItem
    /// Set for a past notification: shows what became of it, not answers
    var history: HistoryEntry? = nil
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
                        // A group notice's title carries the group and the
                        // subject: give it room
                        .lineLimit(item.senderId == nil ? 2 : 1)
                    if let friend, friends.isFavourite(friend) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                    if !item.seen && history == nil {
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
        if let history {
            if let outcome = history.outcome {
                Badge(outcome.text, color: outcome.text == "Answered" ? Palette.canJoin : .secondary, symbol: outcome.symbol)
            }
        } else {
            liveAnswers
        }
    }

    @ViewBuilder
    private var liveAnswers: some View {
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
                    let responses = n.responses ?? []
                    // VRChat labels these with whole sentences ("Acknowledge
                    // and dismiss this notification"): the common ones get a
                    // short name as buttons, the rest go in a menu
                    ForEach(responses.filter { Self.shortName($0) != nil }, id: \.self) { response in
                        if response.type == "accept" {
                            Button(Self.shortName(response) ?? "") { respond(response) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(Self.shortName(response) ?? "") { respond(response) }
                                .buttonStyle(.bordered)
                        }
                    }
                    let link = n.link.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                    let others = responses.filter { Self.shortName($0) == nil }
                    if !others.isEmpty || link != nil {
                        Menu {
                            if let link {
                                Link(destination: link) {
                                    Label(n.linkText ?? "Open Link", systemImage: "safari")
                                }
                            }
                            ForEach(others, id: \.self) { response in
                                Button(role: Self.isDestructive(response) ? .destructive : nil) {
                                    respond(response)
                                } label: {
                                    Label(response.text ?? response.type.capitalized, systemImage: Self.symbol(response))
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(minHeight: 18)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("More Choices")
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

    private func respond(_ response: VRCNotificationV2.Response) {
        Task {
            do {
                try await inbox.respond(item, with: response)
            } catch {
                actions.show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
            }
        }
    }

    /// A button-sized name for VRChat's common choices; nil for the rest,
    /// which go in the menu with VRChat's own words
    static func shortName(_ response: VRCNotificationV2.Response) -> String? {
        switch response.type {
        case "accept": return "Accept"
        case "decline", "reject", "deny": return "Decline"
        case "delete", "dismiss", "acknowledge": return "Dismiss"
        case "unsubscribe", "block", "report": return nil
        default:
            guard let text = response.text, text.count <= 14 else { return nil }
            return text
        }
    }

    static func isDestructive(_ response: VRCNotificationV2.Response) -> Bool {
        ["unsubscribe", "block", "report", "decline", "reject", "deny"].contains(response.type)
    }

    static func symbol(_ response: VRCNotificationV2.Response) -> String {
        switch response.type {
        case "unsubscribe": "bell.slash"
        case "block": "hand.raised"
        case "report": "exclamationmark.bubble"
        case "accept": "checkmark"
        case "decline", "reject", "deny": "xmark"
        default: "arrow.turn.up.right"
        }
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
    /// A past notification: nothing left to mark or clear
    var past = false
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
            if !item.seen && !past {
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
        if !past {
            Section {
                Button(role: .destructive) {
                    Task { try? await inbox.dismiss(item) }
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
            }
        }
    }
}
