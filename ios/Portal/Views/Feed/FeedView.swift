import SwiftUI

/// What your friends have been doing, newest first, grouped by day
struct FeedView: View {
    @Environment(FeedStore.self) private var feed
    @Environment(FriendsStore.self) private var friends
    @Environment(SessionStore.self) private var session
    @State private var path: [Route] = []
    @State private var filter: FeedFilter = .all
    @State private var search = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FilterChips(options: FeedFilter.allCases, selection: $filter, title: \.title)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)

                ConnectionBanner()

                let items = feed.filtered(filter, favourites: friends.favouriteIds, search: search)
                ForEach(days(items), id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            FeedRow(item: item) { path.append($0) }
                                .contextMenu {
                                    FeedMenu(item: item) { path.append($0) }
                                }
                        }
                    }
                }

                if feed.hasMore && !items.isEmpty {
                    Section {
                        Button {
                            Task { await feed.loadEarlier() }
                        } label: {
                            HStack {
                                Text("Load Earlier")
                                Spacer()
                                if feed.isLoading { ProgressView() }
                            }
                        }
                    }
                }

                if !items.isEmpty {
                    Section {
                    } footer: {
                        Text(footer)
                    }
                }
            }
            .overlay {
                if feed.filtered(filter, favourites: friends.favouriteIds, search: search).isEmpty {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else if feed.isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            "No Activity Yet",
                            systemImage: "list.bullet.rectangle.portrait",
                            description: Text(footer)
                        )
                    }
                }
            }
            .searchable(text: $search, prompt: "People or Worlds")
            .refreshable { await feed.refresh() }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle(isOn: Bindable(feed).favouritesOnly) {
                            Label("Favourites Only", systemImage: "star")
                        }
                    } label: {
                        Label("Options", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                RouteView(route: route, path: $path)
            }
        }
    }

    private var footer: String {
        if feed.historyAvailable {
            return "Your relay records what happens while Portal is closed, so the feed fills in when you come back."
        }
        if session.connection?.isRelay == true {
            return "When friends come online, move or change status while Portal is open, it shows here. A relay with history fills in what happens while Portal is closed."
        }
        return "When friends come online, move or change status while Portal is open, it shows here. Connect to a VRCX relay to see what happens while Portal is closed."
    }

    private struct Day {
        let day: Date
        let title: String
        let items: [FeedItem]
    }

    private func days(_ items: [FeedItem]) -> [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            }
            return Day(day: day, title: title, items: grouped[day]!.sorted { $0.date > $1.date })
        }
    }
}

struct FeedRow: View {
    let item: FeedItem
    let open: (Route) -> Void
    @Environment(FriendsStore.self) private var friends

    var body: some View {
        Button {
            open(.user(item.userId))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(id: item.userId, name: item.name, url: friends.friends[item.userId]?.user.imageURL ?? item.image, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(item.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: symbol)
                            .foregroundStyle(color)
                            .imageScale(.small)
                        Text(description)
                            .lineLimit(2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .onAppear {
            if let location = item.location { friends.requestWorld(Location(location).worldId) }
        }
    }

    private var place: Location { Location(item.location) }

    private var worldName: String {
        if place.isPrivate { return "a private instance" }
        return friends.worlds[place.worldId]?.name ?? item.worldName ?? (place.isInstance ? "a world" : "the game")
    }

    private var description: String {
        switch item.kind {
        case .online:
            return item.location.map { _ in "Came online in \(worldName)" } ?? "Came online"
        case .offline:
            return "Went offline"
        case .location:
            let access = place.isInstance ? " · \(place.accessName)" : ""
            return "Went to \(worldName)\(access)"
        case .status:
            if let previous = item.previous { return "\(previous) → \(item.text ?? "")" }
            return "Now \(item.text ?? "")"
        case .statusMessage:
            let text = item.text ?? ""
            return text.isEmpty ? "Cleared their status message" : "“\(text)”"
        case .avatar:
            return "Changed avatar"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .online: "circle.fill"
        case .offline: "circle"
        case .location: "mappin.and.ellipse"
        case .status: "circle.lefthalf.filled"
        case .statusMessage: "text.bubble"
        case .avatar: "person.crop.square"
        }
    }

    private var color: Color {
        switch item.kind {
        case .online: Palette.online
        case .offline: .secondary
        case .location: .accentColor
        case .status: UserStatus.allCases.first { $0.label == item.text }?.color ?? .secondary
        case .statusMessage, .avatar: .secondary
        }
    }
}

struct FeedMenu: View {
    let item: FeedItem
    let open: (Route) -> Void

    var body: some View {
        Button {
            open(.user(item.userId))
        } label: {
            Label("Open Profile", systemImage: "person.crop.circle")
        }
        let place = Location(item.location)
        if place.isInstance {
            Section {
                Button {
                    open(.instance(place.tag))
                } label: {
                    Label("View Instance", systemImage: "person.3")
                }
                Button {
                    open(.world(place.worldId))
                } label: {
                    Label("View World", systemImage: "globe")
                }
            }
        }
        Section {
            Button {
                UIPasteboard.general.string = item.name
            } label: {
                Label("Copy Name", systemImage: "textformat")
            }
        }
    }
}
