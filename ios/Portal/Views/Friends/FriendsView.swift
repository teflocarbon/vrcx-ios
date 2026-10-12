import SwiftUI

/// Who's online and where: favourites, joinable, private, not in game,
/// offline, as on the wrist
struct FriendsView: View {
    @Environment(FriendsStore.self) private var store
    @Environment(SessionStore.self) private var session
    @Environment(Actions.self) private var actions
    @State private var path: [Route] = Demo.isOn ? Demo.friendsPath : []
    @State private var filter: FriendFilter = .all
    @State private var search = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    FilterChips(options: FriendFilter.allCases, selection: $filter, title: \.title) { option in
                        count(for: option)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                .listSectionSpacing(.compact)

                ConnectionBanner()

                let sections = store.sections(filter: filter, search: search)
                ForEach(sections) { section in
                    Section {
                        ForEach(section.friends) { friend in
                            NavigationLink(value: Route.user(friend.id)) {
                                FriendRow(friend: friend)
                            }
                            .contextMenu {
                                FriendMenu(friend: friend) { path.append($0) }
                            }
                            .swipeActions(edge: .leading) {
                                if store.access(for: friend) == .canJoin {
                                    Button {
                                        Task { await actions.inviteMyself(to: friend.location, worldName: store.world(for: friend.place)?.name) }
                                    } label: {
                                        Label("Join", systemImage: "paperplane.fill")
                                    }
                                    .tint(Palette.canJoin)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if store.access(for: friend) != .cannotJoin {
                                    Button {
                                        Task { await actions.requestInvite(from: friend) }
                                    } label: {
                                        Label("Request", systemImage: "hand.raised.fill")
                                    }
                                    .tint(Palette.canRequest)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(section.title)
                            Spacer()
                            Text("\(section.friends.count)")
                        }
                    }
                }
            }
            .overlay {
                if store.friends.isEmpty && store.isLoading {
                    ProgressView("Loading Friends…")
                } else if store.friends.isEmpty, let error = store.error {
                    ContentUnavailableView {
                        Label("Couldn't Load Friends", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await store.refresh() } }
                    }
                } else if !store.friends.isEmpty && store.sections(filter: filter, search: search).isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "person.2.slash", description: Text(emptyDescription))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a Friend")
            .refreshable { await store.refresh() }
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        FavouritesGroupPicker()
                        Toggle(isOn: Bindable(store).showOfflineFavourites) {
                            Label("Show Offline Favourites", systemImage: "moon.zzz")
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
        // A tapped notification about someone opens their profile
        .onChange(of: DeepLinks.shared.pending) { _, destination in
            if case .user(let id) = destination {
                path = [.user(id)]
                DeepLinks.shared.pending = nil
            }
        }
    }

    private func count(for filter: FriendFilter) -> Int? {
        switch filter {
        case .online: store.friends.values.filter { $0.state != .offline }.count
        case .joinable: store.joinableCount
        default: nil
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .joinable: "No One to Join"
        case .favourites: "No Favourites"
        case .offline: "Everyone's Online"
        default: "No Friends Here"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .joinable: "When a friend is somewhere you can join, they'll show here."
        case .favourites: "Friends you favourite in VRChat or VRCX show here."
        case .offline: "Friends who are offline show here."
        default: "Friends who are online show here."
        }
    }
}

/// Where a route goes, shared by every tab
struct RouteView: View {
    let route: Route
    @Binding var path: [Route]

    var body: some View {
        switch route {
        case .user(let id):
            UserView(userId: id) { path.append($0) }
        case .world(let id):
            WorldView(worldId: id) { path.append($0) }
        case .instance(let location):
            InstanceView(location: location) { path.append($0) }
        }
    }
}

extension Demo {
    static var friendsPath: [Route] {
        switch screen {
        case .friend: [.user(userId(1))]
        case .world: [.world(worldId(1))]
        default: []
        }
    }
}

/// Which favourite group sits at the top of Friends, as on the wrist: one
/// you choose, or every favourite
struct FavouritesGroupPicker: View {
    @Environment(FriendsStore.self) private var store

    var body: some View {
        Picker(selection: Bindable(store).favouritesGroup) {
            Label("All Favourites", systemImage: "star.fill").tag(String?.none)
            ForEach(store.favouriteGroupList) { group in
                Label(group.displayName ?? group.name, systemImage: "star")
                    .tag(Optional(group.name))
            }
        } label: {
            Label("Favourites at the Top", systemImage: "star")
        }
        .pickerStyle(.menu)
    }
}
