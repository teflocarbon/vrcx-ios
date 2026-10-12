import Foundation
import Observation

/// Something a friend did: came online, moved, changed status
struct FeedItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case online, offline, location, status, statusMessage, avatar
    }

    /// "e1042" for an event from the relay's history, otherwise random
    let id: String
    let date: Date
    let userId: String
    var name: String
    var image: String?
    let kind: Kind
    var location: String?
    var worldName: String?
    var text: String?
    var previous: String?

    var fromHistory: Bool { id.hasPrefix("e") }
}

enum FeedFilter: String, CaseIterable, Identifiable, Sendable {
    case all, online, location, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .online: "Online"
        case .location: "Location"
        case .status: "Status"
        }
    }

    func includes(_ kind: FeedItem.Kind) -> Bool {
        switch self {
        case .all: true
        case .online: kind == .online || kind == .offline
        case .location: kind == .location
        case .status: kind == .status || kind == .statusMessage || kind == .avatar
        }
    }
}

/// What your friends have been doing. Built from the pipeline while Portal
/// is open, with VRCX's rules (an offline that's undone within 170 seconds
/// never shows; a move only shows when where they were is known). With a
/// relay that records events, it also reads back what happened while
/// Portal was closed.
@MainActor
@Observable
final class FeedStore {
    private(set) var items: [FeedItem] = []
    private(set) var isLoading = false
    private(set) var historyAvailable = false
    /// More history to page back through
    private(set) var hasMore = false
    var error: String?

    var favouritesOnly: Bool {
        didSet { UserDefaults.standard.set(favouritesOnly, forKey: "feedFavouritesOnly") }
    }

    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private var oldestEvent: Int?
    @ObservationIgnored private var save: Task<Void, Never>?
    private let isDemo: Bool

    private static let keep: TimeInterval = 7 * 86_400
    private static let historyTypes = "friend-online,friend-offline,friend-location"

    init() {
        isDemo = false
        favouritesOnly = UserDefaults.standard.bool(forKey: "feedFavouritesOnly")
        items = Self.load()
    }

    init(demoItems: [FeedItem]) {
        isDemo = true
        favouritesOnly = false
        items = demoItems
        historyAvailable = true
    }

    func attach(_ session: SessionStore) {
        self.session = session
        if session.api == nil && !isDemo {
            items = []
            oldestEvent = nil
            historyAvailable = false
            persist()
        }
    }

    func filtered(_ filter: FeedFilter, favourites: Set<String>, search: String) -> [FeedItem] {
        items.filter { item in
            filter.includes(item.kind)
                && (!favouritesOnly || favourites.contains(item.userId))
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search)
                    || (item.worldName?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    // MARK: Live

    func add(_ item: FeedItem) {
        guard !isDemo else { return }
        items.insert(item, at: 0)
        trim()
        persist()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        if items.count > 1_500 { items.removeLast(items.count - 1_500) }
        items.removeAll { $0.date < cutoff && !$0.fromHistory }
    }

    // MARK: History from the relay

    /// The newest page of the relay's history, replacing what Portal saw
    /// live up to then (the same events, now with their IDs)
    func refresh() async {
        guard !isDemo, let session, let api = session.api, case .relay(let origin)? = session.connection else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let capabilities = await RelayProbe.capabilities(origin) {
            historyAvailable = capabilities.features.events
        } else {
            historyAvailable = false
        }
        guard historyAvailable else { return }
        do {
            let page = try await fetch(api, before: Int(Int32.max))
            let history = convert(page.events)
            let newest = history.first?.date ?? .distantPast
            let live = items.filter { !$0.fromHistory && $0.date > newest.addingTimeInterval(1) }
            items = live + history
            oldestEvent = page.events.last?.id
            hasMore = page.next != nil
            error = nil
            persist()
        } catch {
            self.error = error.userMessage
        }
    }

    /// The page before the oldest one shown
    func loadEarlier() async {
        guard !isDemo, let api = session?.api, let oldestEvent, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(api, before: oldestEvent)
            let known = Set(items.map(\.id))
            items += convert(page.events).filter { !known.contains($0.id) }
            self.oldestEvent = page.events.last?.id ?? oldestEvent
            hasMore = page.next != nil && !page.events.isEmpty
        } catch {
            self.error = error.userMessage
        }
    }

    private struct Page: Decodable {
        struct Event: Decodable {
            let id: Int
            let type: String
            let receivedAt: String
            let content: Content
        }

        struct Content: Decodable {
            let userId: String?
            var user: VRCUser?
            var location: String?
            var travelingToLocation: String?
        }

        let events: [Event]
        let next: Int?
    }

    private func fetch(_ api: VRChatAPI, before: Int) async throws -> Page {
        // /relay/v1 sits beside /api/1 on the relay's origin
        try await api.get("../../relay/v1/events", query: [
            URLQueryItem(name: "before", value: String(before)),
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "types", value: Self.historyTypes),
        ])
    }

    /// Events, newest first, as feed items with VRCX's rules: an offline
    /// followed by an online within 170 seconds is dropped, and moving into
    /// "traveling" isn't a move
    private func convert(_ events: [Page.Event]) -> [FeedItem] {
        guard let friends = session?.friends else { return [] }
        var result: [FeedItem] = []
        // Newest first, so the online that undoes an offline comes before it
        var cameBackAt: [String: Date] = [:]
        for event in events {
            guard let userId = event.content.userId, let date = Date(vrchat: event.receivedAt) else { continue }
            let known = friends.friends[userId]
            let name = event.content.user?.displayName ?? known?.name ?? "Unknown User"
            let image = event.content.user?.imageURL ?? known?.user.imageURL
            switch event.type {
            case "friend-online":
                cameBackAt[userId] = date
                let location = event.content.location
                result.append(FeedItem(id: "e\(event.id)", date: date, userId: userId, name: name, image: image, kind: .online,
                                       location: location, worldName: worldName(location, friends)))
            case "friend-offline":
                if let back = cameBackAt[userId], back.timeIntervalSince(date) < FriendsStore.offlineDelay { continue }
                result.append(FeedItem(id: "e\(event.id)", date: date, userId: userId, name: name, image: image, kind: .offline))
            case "friend-location":
                guard let location = event.content.location, location != "traveling" else { continue }
                result.append(FeedItem(id: "e\(event.id)", date: date, userId: userId, name: name, image: image, kind: .location,
                                       location: location, worldName: worldName(location, friends)))
            default:
                continue
            }
        }
        return result
    }

    private func worldName(_ location: String?, _ friends: FriendsStore) -> String? {
        let place = Location(location)
        guard place.isInstance else { return nil }
        friends.requestWorld(place.worldId)
        return friends.worlds[place.worldId]?.name
    }

    // MARK: Saving

    private static var url: URL {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "feed.json")
    }

    private static func load() -> [FeedItem] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([FeedItem].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-keep)
        return items.filter { $0.date >= cutoff }
    }

    /// Saved a moment later, so a burst of events is one write. It stays on
    /// this phone: it's other people's comings and goings.
    private func persist() {
        guard !isDemo else { return }
        save?.cancel()
        let snapshot = items
        let url = Self.url
        save = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
