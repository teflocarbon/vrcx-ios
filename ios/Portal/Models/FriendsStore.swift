import Foundation
import Observation

/// Your friends and where they are: loaded over REST, then kept up to date
/// from the pipeline. Placing and sorting follow the wrist (and VRCX), so a
/// friend sits in the same section on the phone as in VR.
@MainActor
@Observable
final class FriendsStore {
    private(set) var friends: [String: Friend] = [:]
    private(set) var favouriteIds: Set<String> = []
    /// Favourite group display names by user ID
    private(set) var favouriteGroups: [String: [String]] = [:]
    /// Your friend favourite groups, in VRChat's order
    private(set) var favouriteGroupList: [VRCFavoriteGroup] = []
    /// Who's in each favourite group, by its name ("group_0")
    private(set) var groupMembers: [String: Set<String>] = [:]

    /// The favourite group shown at the top of Friends, as the wrist lets
    /// you choose; nil for every favourite
    var favouritesGroup: String? {
        didSet { UserDefaults.standard.set(favouritesGroup, forKey: "favouritesGroup") }
    }
    private(set) var worlds: [String: VRCWorld] = [:]
    /// Groups that own instances friends are in, fetched as they're needed
    private(set) var groups: [String: VRCGroup] = [:]
    @ObservationIgnored private var groupsLoading: Set<String> = []
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    var error: String?

    /// Show offline favourites in Favourites, as the wrist's popover does
    var showOfflineFavourites: Bool {
        didSet { UserDefaults.standard.set(showOfflineFavourites, forKey: "showOfflineFavourites") }
    }

    /// Where changes go to become feed items
    @ObservationIgnored var onFeed: ((FeedItem) -> Void)?
    @ObservationIgnored private var api: VRChatAPI?
    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private var pendingOffline: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var worldQueue: [String] = []
    @ObservationIgnored private var worldsLoading: Set<String> = []
    @ObservationIgnored private var worldWorker: Task<Void, Never>?
    private let isDemo: Bool

    /// VRChat sends offline then online when someone switches platform or
    /// their game restarts; VRCX waits this long before believing it
    static let offlineDelay: TimeInterval = 170

    init() {
        isDemo = false
        showOfflineFavourites = UserDefaults.standard.bool(forKey: "showOfflineFavourites")
        favouritesGroup = UserDefaults.standard.string(forKey: "favouritesGroup")
        worlds = WorldCache.load()
    }

    init(demoFriends: [Friend], groups: [VRCFavoriteGroup], members: [String: Set<String>], worlds: [VRCWorld]) {
        isDemo = true
        showOfflineFavourites = true
        favouritesGroup = groups.first?.name
        friends = Dictionary(uniqueKeysWithValues: demoFriends.map { ($0.id, $0) })
        self.worlds = Dictionary(uniqueKeysWithValues: worlds.map { ($0.id, $0) })
        loadedAt = Date()
        setFavourites(groups: groups, members: members)
    }

    private func setFavourites(groups: [VRCFavoriteGroup], members: [String: Set<String>]) {
        favouriteGroupList = groups
        groupMembers = members
        favouriteIds = members.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var byUser: [String: [String]] = [:]
        for group in groups {
            for id in members[group.name] ?? [] {
                byUser[id, default: []].append(group.displayName ?? group.name)
            }
        }
        favouriteGroups = byUser
    }

    /// Who a feed audience covers: nil for everyone, every favourite, or one
    /// favourite group's members
    func people(in audience: String?) -> Set<String>? {
        guard let audience else { return nil }
        if audience == FeedStore.allFavourites { return favouriteIds }
        return groupMembers[audience] ?? []
    }

    /// "favourites", or a group's name, for "Showing … only"
    func audienceName(_ audience: String?) -> String {
        guard let audience, audience != FeedStore.allFavourites else { return "favourites" }
        return favouriteGroupList.first { $0.name == audience }.map { $0.displayName ?? $0.name } ?? "one favourite group"
    }

    /// The chosen group, if it still exists
    var chosenFavouritesGroup: VRCFavoriteGroup? {
        favouriteGroupList.first { $0.name == favouritesGroup }
    }

    /// Who goes at the top of Friends: the chosen group, or every favourite
    func isInFavouritesSection(_ friend: Friend) -> Bool {
        if let group = chosenFavouritesGroup {
            return groupMembers[group.name]?.contains(friend.id) ?? false
        }
        return isFavourite(friend)
    }

    func attach(api: VRChatAPI?, session: SessionStore) {
        self.api = api
        self.session = session
        if api == nil && !isDemo { reset() }
    }

    func reset() {
        friends = [:]
        favouriteIds = []
        favouriteGroups = [:]
        favouriteGroupList = []
        groupMembers = [:]
        loadedAt = nil
        error = nil
        pendingOffline.values.forEach { $0.cancel() }
        pendingOffline = [:]
    }

    // MARK: Loading

    /// Everything, from REST: online and offline friends, then favourites
    func refresh() async {
        guard !isDemo, let api, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let me: CurrentUser = try await api.get("auth/user")
            session?.updateMe(me)
            let online = Set(me.onlineFriends ?? [])
            let active = Set(me.activeFriends ?? [])

            var loaded: [String: Friend] = [:]
            for offline in [false, true] {
                var offset = 0
                while true {
                    let page: [VRCUser] = try await api.get("auth/user/friends", query: [
                        URLQueryItem(name: "offline", value: String(offline)),
                        URLQueryItem(name: "n", value: "100"),
                        URLQueryItem(name: "offset", value: String(offset)),
                    ])
                    for user in page {
                        loaded[user.id] = makeFriend(user, online: online, active: active, offlineList: offline)
                    }
                    if page.count < 100 { break }
                    offset += page.count
                }
            }
            // Keep when we first saw them arrive, if they haven't moved since
            for (id, var friend) in loaded {
                if let old = friends[id], old.location == friend.location {
                    friend.locationSince = old.locationSince
                    friend.stateSince = old.stateSince
                    loaded[id] = friend
                }
            }
            friends = loaded
            loadedAt = Date()
            error = nil
            await loadFavourites(api)
            requestWorlds(for: Array(friends.values))
            if let location = me.location { requestWorld(Location(location).worldId) }
        } catch {
            handle(error)
        }
    }

    /// Refresh if it's been a while, as when Portal comes back on screen
    func refreshIfStale() async {
        guard let loadedAt, Date().timeIntervalSince(loadedAt) < 60 else {
            await refresh()
            return
        }
    }

    private func loadFavourites(_ api: VRChatAPI) async {
        do {
            let favourites: [VRCFavorite] = try await api.get("favorites", query: [
                URLQueryItem(name: "type", value: "friend"),
                URLQueryItem(name: "n", value: "300"),
            ])
            let groups: [VRCFavoriteGroup] = (try? await api.get("favorite/groups", query: [
                URLQueryItem(name: "type", value: "friend"),
                URLQueryItem(name: "n", value: "50"),
            ])) ?? []
            var members: [String: Set<String>] = [:]
            for favourite in favourites {
                for tag in favourite.tags ?? [] {
                    members[tag, default: []].insert(favourite.favoriteId)
                }
            }
            // A favourite whose group the list didn't include still counts
            var known = groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for tag in members.keys where !known.contains(where: { $0.name == tag }) {
                known.append(VRCFavoriteGroup(id: tag, name: tag))
            }
            setFavourites(groups: known, members: members)
        } catch {
            // Favourites are a nicety: the list works without them
        }
    }

    private func makeFriend(_ user: VRCUser, online: Set<String>, active: Set<String>, offlineList: Bool) -> Friend {
        let location = user.location ?? "offline"
        let state: Friend.State
        if offlineList {
            state = .offline
        } else if online.contains(user.id) {
            state = .online
        } else if active.contains(user.id) {
            state = .active
        } else {
            // The lists on auth/user can lag behind: go by the location
            state = location == "offline" || location.isEmpty ? .active : .online
        }
        return Friend(user: user, state: state, location: state == .online ? location : "offline",
                      travelingTo: user.travelingToLocation, platform: user.platform)
    }

    /// Only what ends or pauses the session: for a page or an action, whose
    /// own failure shows where it happened, not as the Friends banner
    func handleSession(_ error: Error) {
        switch error {
        case APIError.signedOut:
            session?.sessionEnded()
        case APIError.relaySignedOut:
            session?.relayIsSignedOut()
        default:
            break
        }
    }

    /// A failed refresh of the friends list: also shown as its banner
    func handle(_ error: Error) {
        switch error {
        case APIError.signedOut:
            session?.sessionEnded()
        case APIError.relaySignedOut:
            session?.relayIsSignedOut()
        default:
            self.error = error.localizedDescription
        }
    }

    // MARK: Live updates

    private struct FriendEvent: Decodable {
        let userId: String
        var user: VRCUser?
        var location: String?
        var travelingToLocation: String?
        var platform: String?
    }

    /// Apply a pipeline event; returns whether it was about a friend
    @discardableResult
    func apply(_ event: PipelineEvent) -> Bool {
        guard event.type.hasPrefix("friend-"), let content = event.decode(FriendEvent.self) else { return false }
        let id = content.userId
        let now = event.received
        let old = friends[id]
        let wasPendingOffline = pendingOffline[id] != nil
        switch event.type {
        case "friend-online":
            cancelPendingOffline(id)
            update(id, user: content.user) { friend in
                if friend.state != .online { friend.stateSince = now }
                friend.state = .online
                friend.platform = content.platform ?? friend.platform
                setLocation(&friend, content.location ?? "private", traveling: content.travelingToLocation, at: now)
            }
        case "friend-active":
            cancelPendingOffline(id)
            update(id, user: content.user) { friend in
                if friend.state != .active { friend.stateSince = now }
                friend.state = .active
                friend.platform = content.platform ?? "web"
                setLocation(&friend, "offline", traveling: nil, at: now)
            }
        case "friend-offline":
            scheduleOffline(id, platform: content.platform, at: now)
        case "friend-location":
            cancelPendingOffline(id)
            update(id, user: content.user) { friend in
                if friend.state != .online {
                    friend.state = .online
                    friend.stateSince = now
                }
                setLocation(&friend, content.location ?? friend.location, traveling: content.travelingToLocation, at: now)
            }
        case "friend-update", "friend-add":
            update(id, user: content.user) { _ in }
        case "friend-delete":
            cancelPendingOffline(id)
            friends[id] = nil
            favouriteIds.remove(id)
        default:
            return false
        }
        if let friend = friends[id] {
            requestWorld(friend.place.worldId)
            recordFeed(event.type, old: old, new: friend, wasPendingOffline: wasPendingOffline, at: now)
        }
        return true
    }

    /// Turn a change into feed items, with VRCX's rules: coming back within
    /// 170 seconds of going offline isn't news, and a move only counts when
    /// Portal knew where they were before
    private func recordFeed(_ type: String, old: Friend?, new: Friend, wasPendingOffline: Bool, at date: Date) {
        guard let onFeed, let old else { return }
        func item(_ kind: FeedItem.Kind, location: String? = nil, text: String? = nil, previous: String? = nil) {
            onFeed(FeedItem(id: UUID().uuidString, date: date, userId: new.id, name: new.name, image: new.user.imageURL,
                            kind: kind, location: location, worldName: worlds[Location(location).worldId]?.name,
                            text: text, previous: previous))
        }
        switch type {
        case "friend-online":
            if !wasPendingOffline && old.state != .online {
                item(.online, location: new.location)
            } else if old.location != new.location && new.place.isInstance {
                item(.location, location: new.location, previous: old.location)
            }
        case "friend-location":
            guard new.location != "traveling", old.state == .online, old.location != new.location,
                  old.location != "offline", !old.location.isEmpty else { return }
            item(.location, location: new.location, previous: old.location)
        case "friend-update":
            if old.user.status != new.user.status, let status = new.user.status {
                item(.status, text: UserStatus(status).label, previous: old.user.status.map { UserStatus($0).label })
            }
            if (old.user.statusDescription ?? "") != (new.user.statusDescription ?? "") {
                item(.statusMessage, text: new.user.statusDescription ?? "", previous: old.user.statusDescription)
            }
            if old.user.currentAvatarThumbnailImageUrl != nil,
               old.user.currentAvatarThumbnailImageUrl != new.user.currentAvatarThumbnailImageUrl {
                item(.avatar)
            }
        default:
            break
        }
    }

    private func update(_ id: String, user: VRCUser?, _ change: (inout Friend) -> Void) {
        var friend = friends[id]
            ?? Friend(user: user ?? VRCUser(id: id), state: .offline, location: "offline")
        if let user { friend.user = friend.user.merged(with: user) }
        change(&friend)
        friends[id] = friend
    }

    private func setLocation(_ friend: inout Friend, _ location: String, traveling: String?, at date: Date) {
        if location == "traveling" {
            friend.travelingTo = traveling
            if friend.location != "traveling" { friend.locationSince = date }
            friend.location = "traveling"
            return
        }
        if friend.location != location { friend.locationSince = date }
        friend.location = location
        friend.travelingTo = nil
    }

    private func scheduleOffline(_ id: String, platform: String?, at date: Date) {
        cancelPendingOffline(id)
        pendingOffline[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.offlineDelay))
            guard !Task.isCancelled, let self else { return }
            self.pendingOffline[id] = nil
            let wasOnline = self.friends[id].map { $0.state != .offline } ?? false
            self.update(id, user: nil) { friend in
                friend.state = .offline
                friend.stateSince = date
                friend.location = "offline"
                friend.travelingTo = nil
                friend.locationSince = date
                friend.platform = platform ?? friend.platform
            }
            if wasOnline, let friend = self.friends[id] {
                self.onFeed?(FeedItem(id: UUID().uuidString, date: date, userId: id, name: friend.name,
                                      image: friend.user.imageURL, kind: .offline))
            }
        }
    }

    private func cancelPendingOffline(_ id: String) {
        pendingOffline.removeValue(forKey: id)?.cancel()
    }

    // MARK: Worlds

    func world(for location: Location) -> VRCWorld? {
        worlds[location.worldId]
    }

    /// Fetch a world's name and picture if Portal doesn't have them yet.
    /// One at a time, spaced out, and cached on disk: names barely change.
    func requestWorld(_ id: String) {
        guard !isDemo, id.hasPrefix("wrld_"), worlds[id] == nil, !worldsLoading.contains(id) else { return }
        worldsLoading.insert(id)
        worldQueue.append(id)
        guard worldWorker == nil else { return }
        worldWorker = Task { [weak self] in
            while let self, !self.worldQueue.isEmpty, !Task.isCancelled {
                let next = self.worldQueue.removeFirst()
                if let api = self.api, let world: VRCWorld = try? await api.get("worlds/\(next)") {
                    self.worlds[next] = world
                    WorldCache.save(self.worlds)
                }
                self.worldsLoading.remove(next)
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.worldWorker = nil
        }
    }

    private func requestWorlds(for friends: [Friend]) {
        let ids = Set(friends.filter(\.isInGame).map(\.place.worldId))
        for id in ids { requestWorld(id) }
    }

    /// Fetch a group's name and icon if Portal doesn't have them yet
    func requestGroup(_ id: String?) {
        guard let id, id.hasPrefix("grp_"), groups[id] == nil, !groupsLoading.contains(id), !isDemo,
              let api else { return }
        groupsLoading.insert(id)
        Task {
            if let group: VRCGroup = try? await api.get("groups/\(id)") {
                groups[id] = group
            }
            groupsLoading.remove(id)
        }
    }

    /// The group that owns an instance, if Portal has it
    func group(for location: Location) -> VRCGroup? {
        location.groupId.flatMap { groups[$0] }
    }

    /// Load a world afresh, for its page: player counts change
    func loadWorld(_ id: String) async throws -> VRCWorld {
        if isDemo, let world = worlds[id] { return world }
        guard let api else { throw APIError.signedOut }
        let world: VRCWorld = try await api.get("worlds/\(id)")
        worlds[id] = world
        WorldCache.save(worlds)
        return world
    }

    // MARK: Who's where

    var myId: String? { session?.me?.id }
    var myLocation: String? { session?.me?.location }

    func isFavourite(_ friend: Friend) -> Bool {
        favouriteIds.contains(friend.id)
    }

    /// Whether a friend is in the same instance as you
    func isWithYou(_ friend: Friend) -> Bool {
        guard friend.isInGame, let mine = myLocation else { return false }
        return friend.location == mine
    }

    /// VRCX's and the wrist's rule: online, not busy, in a real instance,
    /// and one that lets you in (yours, public, friends+, friends of its
    /// owner if you're their friend, or an open group instance)
    func access(for friend: Friend) -> Access {
        guard friend.isInGame, friend.status != .busy, friend.id != myId else { return .cannotJoin }
        let place = friend.place
        guard place.isInstance else {
            return .canRequest
        }
        let open: Bool
        switch place.accessType {
        case .public, .friendsPlus: open = true
        case .friends: open = place.ownerId.map { $0 == myId || friends[$0] != nil } ?? false
        case .group: open = place.groupAccessType == "public" || place.groupAccessType == "plus"
        case .invite, .invitePlus, nil: open = place.ownerId == myId
        }
        return open ? .canJoin : .canRequest
    }

    func place(of friend: Friend) -> FriendPlace {
        switch friend.state {
        case .offline: return .offline
        case .active: return .notInGame
        case .online: return access(for: friend) == .canJoin ? .joinable : .inGame
        }
    }

    /// What to show for where someone is: "Test World", "Private Instance"
    func locationText(for friend: Friend) -> String {
        switch friend.state {
        case .offline: return "Offline"
        case .active: return "Not In Game"
        case .online: break
        }
        let place = friend.place
        if place.isPrivate { return "Private Instance" }
        if place.isTraveling {
            let destination = Location(friend.travelingTo)
            if let name = worlds[destination.worldId]?.name { return "Traveling to \(name)" }
            return "Between Instances"
        }
        if place.isOffline { return "Not In Game" }
        if let name = worlds[place.worldId]?.name { return name }
        return place.worldId.isEmpty ? "Location Unknown" : "Loading World…"
    }

    /// The wrist's order: in game first, then joinable, then status, then name
    func sorted(_ list: [Friend]) -> [Friend] {
        list.sorted { a, b in
            if a.isInGame != b.isInGame { return a.isInGame }
            let aJoin = access(for: a) == .canJoin, bJoin = access(for: b) == .canJoin
            if aJoin != bJoin { return aJoin }
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func sections(filter: FriendFilter, search: String) -> [FriendSection] {
        var list = Array(friends.values)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { friend in
                friend.name.localizedCaseInsensitiveContains(query)
                    || (friend.user.statusDescription?.localizedCaseInsensitiveContains(query) ?? false)
                    || locationText(for: friend).localizedCaseInsensitiveContains(query)
            }
        }
        switch filter {
        case .all:
            break
        case .online:
            list = list.filter { $0.state != .offline }
        case .joinable:
            list = list.filter { access(for: $0) == .canJoin }
        case .favourites:
            list = list.filter(isFavourite)
        case .offline:
            list = list.filter { $0.state == .offline }
        }

        var result: [FriendSection] = []
        // Favourites first, as on the wrist (one chosen group, or all of
        // them), unless they're what's filtered
        var rest = list
        if filter == .all || filter == .online {
            let favourites = list.filter { isInFavouritesSection($0) && (showOfflineFavourites || $0.state != .offline) }
            if !favourites.isEmpty {
                let title = chosenFavouritesGroup.map { $0.displayName ?? $0.name } ?? "Favourites"
                result.append(FriendSection(id: "favourites", title: title, friends: sorted(favourites)))
                let ids = Set(favourites.map(\.id))
                rest = list.filter { !ids.contains($0.id) }
            }
        }
        let grouped = Dictionary(grouping: rest, by: place(of:))
        for place in FriendPlace.allCases {
            guard let members = grouped[place], !members.isEmpty else { continue }
            result.append(FriendSection(id: "\(place)", title: place.title, friends: sorted(members)))
        }
        return result
    }

    var onlineCount: Int { friends.values.filter { $0.state == .online }.count }
    var joinableCount: Int { friends.values.filter { access(for: $0) == .canJoin }.count }

    /// Friends in a given instance
    func friends(in location: String) -> [Friend] {
        sorted(friends.values.filter { $0.isInGame && $0.location == location })
    }

    /// Friends in any instance of a world
    func friends(inWorld worldId: String) -> [Friend] {
        sorted(friends.values.filter { $0.isInGame && $0.place.worldId == worldId })
    }
}

/// World names and pictures, kept between launches so the list isn't full
/// of "Loading World…" each time. Only public world details, nothing about
/// you or your friends.
enum WorldCache {
    private static var url: URL {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "worlds.json")
    }

    static func load() -> [String: VRCWorld] {
        guard let data = try? Data(contentsOf: url),
              let worlds = try? JSONDecoder().decode([String: VRCWorld].self, from: data) else { return [:] }
        return worlds
    }

    static func save(_ worlds: [String: VRCWorld]) {
        // The most recent few hundred is plenty
        let kept = worlds.count > 500 ? Dictionary(uniqueKeysWithValues: worlds.prefix(500).map { ($0.key, $0.value) }) : worlds
        if let data = try? JSONEncoder().encode(kept) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
