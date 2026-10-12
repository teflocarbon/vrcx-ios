import Foundation
import Observation

/// Something a friend did: came online, moved, changed status
struct FeedItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case online, offline, location, status, statusMessage, avatar, bio
    }

    /// "f812" for a row from the relay's feed, otherwise random
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
    var groupName: String?
    /// For a move, how long they'd been where they were; for going
    /// offline, how long they'd been online
    var duration: TimeInterval?
    var avatarName: String?
    var avatarImage: String?

    var fromRelay: Bool { id.hasPrefix("f") }
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
        case .status: kind == .status || kind == .statusMessage || kind == .avatar || kind == .bio
        }
    }
}

/// What your friends have been doing.
///
/// With a relay that keeps the feed, the relay works it out the way VRCX
/// does (it runs VRCX's own rules) and Portal shows its rows, keeping its
/// own place in them: on launch it asks only for what came after the last
/// row it has, so the feed fills in what happened while Portal was closed.
/// Otherwise Portal follows VRCX's rules itself, from the pipeline while
/// it's open: an offline undone within 170 seconds isn't shown, and a move
/// only counts when where they were is known.
@MainActor
@Observable
final class FeedStore {
    private(set) var items: [FeedItem] = []
    private(set) var isLoading = false
    /// The relay keeps the feed, including while Portal is closed
    private(set) var relayFeed = false
    /// More history to page back through
    private(set) var hasMore = false
    var error: String?

    var favouritesOnly: Bool {
        didSet { UserDefaults.standard.set(favouritesOnly, forKey: "feedFavouritesOnly") }
    }

    @ObservationIgnored private weak var session: SessionStore?
    /// Where Portal has read up to in the relay's feed, and the oldest row
    /// it has. Each phone keeps its own; the relay's backfill is for VRCX.
    /// Saved in the same write as the rows, so neither runs ahead.
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private var oldest: Int?
    @ObservationIgnored private var epoch: String?
    @ObservationIgnored private var save: Task<Void, Never>?
    @ObservationIgnored private var nudge: Task<Void, Never>?
    @ObservationIgnored private var lateNudge: Task<Void, Never>?
    private let isDemo: Bool

    private static let keep: TimeInterval = 7 * 86_400

    init() {
        isDemo = false
        favouritesOnly = UserDefaults.standard.bool(forKey: "feedFavouritesOnly")
        let saved = Self.load()
        items = saved.items
        cursor = saved.cursor
        oldest = saved.oldest
        epoch = saved.epoch
        hasMore = saved.hasMore ?? false
    }

    init(demoItems: [FeedItem]) {
        isDemo = true
        favouritesOnly = false
        items = demoItems
        relayFeed = true
    }

    func attach(_ session: SessionStore) {
        self.session = session
        if session.api == nil && !isDemo {
            items = []
            oldest = nil
            relayFeed = false
            cursor = nil
            epoch = nil
            hasMore = false
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

    // MARK: Live, without a relay feed

    /// A change Portal worked out itself from the pipeline. Ignored when the
    /// relay keeps the feed: its rows are the record, and they'd only be
    /// shown twice.
    func add(_ item: FeedItem) {
        guard !isDemo, !relayFeed else { return }
        items.insert(item, at: 0)
        trim()
        persist()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-Self.keep)
        if items.count > 1_500 { items.removeLast(items.count - 1_500) }
        // The relay keeps its own history for longer; only what Portal saw
        // itself ages out here
        items.removeAll { $0.date < cutoff && !$0.fromRelay }
    }

    // MARK: The relay's feed

    /// A friend did something: the relay will have a row for it shortly.
    /// Going offline takes 170 seconds to count, so look again after that.
    func nudge(offline: Bool) {
        guard relayFeed else { return }
        nudge?.cancel()
        nudge = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
        if offline {
            lateNudge?.cancel()
            lateNudge = Task { [weak self] in
                try? await Task.sleep(for: .seconds(FriendsStore.offlineDelay + 5))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// Catch up: everything after the last row Portal has. Asking twice is
    /// harmless (rows have their own IDs), and the place moves on only with
    /// the rows it covers, so a fetch iOS cuts short just happens again.
    func refresh() async {
        guard !isDemo, let session, let api = session.api, case .relay(let origin)? = session.connection else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let capabilities = await RelayProbe.capabilities(origin)
        let available = capabilities?.features.feed ?? false
        if available != relayFeed {
            relayFeed = available
            // Switching sources: what the other one made doesn't belong
            items.removeAll { $0.fromRelay != available }
        }
        guard relayFeed else { return }
        do {
            if let cursor, items.contains(where: \.fromRelay), try await catchUp(api, origin: origin, from: cursor) {
                // Caught up
            } else {
                try await loadNewest(api, origin: origin)
            }
            error = nil
            trim()
            persist()
        } catch {
            self.error = error.userMessage
        }
    }

    /// Everything after `cursor`, a few pages at most. Returns false when
    /// that isn't enough (a long time away) or the relay's numbering has
    /// started again: then the newest page is the place to start, so Load
    /// Earlier walks back with no hole in the middle.
    private func catchUp(_ api: VRChatAPI, origin: URL, from cursor: Int) async throws -> Bool {
        var after = cursor
        var fresh: [FeedItem] = []
        for _ in 0..<5 {
            let page = try await fetch(api, origin: origin, after: after)
            if let epoch = page.instance, let known = self.epoch, epoch != known { return false }
            fresh += convert(page.rows, origin: origin)
            after = page.next ?? after
            if page.rows.count < 500 {
                let known = Set(items.map(\.id))
                items.insert(contentsOf: fresh.reversed().filter { !known.contains($0.id) }, at: 0)
                self.cursor = after
                if self.epoch == nil { self.epoch = page.instance }
                return true
            }
        }
        return false
    }

    private func loadNewest(_ api: VRChatAPI, origin: URL) async throws {
        let page = try await fetch(api, origin: origin, before: Int(Int32.max))
        items = items.filter { !$0.fromRelay } + convert(page.rows, origin: origin)
        cursor = page.rows.first?.seq ?? 0
        oldest = page.rows.last?.seq
        hasMore = page.next != nil
        epoch = page.instance
    }

    /// The page before the oldest row shown
    func loadEarlier() async {
        guard !isDemo, relayFeed, let api = session?.api, case .relay(let origin)? = session?.connection,
              let oldest, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(api, origin: origin, before: oldest)
            let known = Set(items.map(\.id))
            items += convert(page.rows, origin: origin).filter { !known.contains($0.id) }
            self.oldest = page.rows.last?.seq ?? oldest
            hasMore = page.next != nil && !page.rows.isEmpty
            persist()
        } catch {
            self.error = error.userMessage
        }
    }

    private struct Page: Decodable {
        let rows: [Row]
        let next: Int?
        /// The relay's database: new if it was wiped or replaced, when its
        /// numbering starts again. Older relays don't send it.
        var instance: String?
    }

    /// One row of VRCX's feed tables, with VRCX's own column names
    private struct Row: Decodable {
        let seq: Int
        let table: String
        let data: Columns

        struct Columns: Decodable {
            var createdAt: String?
            var userId: String?
            var displayName: String?
            var location: String?
            var worldName: String?
            var previousLocation: String?
            var groupName: String?
            var type: String?
            var time: Double?
            var status: String?
            var statusDescription: String?
            var previousStatus: String?
            var previousStatusDescription: String?
            var bio: String?
            var previousBio: String?
            var avatarName: String?
            var currentAvatarThumbnailImageUrl: String?

            enum CodingKeys: String, CodingKey {
                case createdAt = "created_at"
                case userId = "user_id"
                case displayName = "display_name"
                case location
                case worldName = "world_name"
                case previousLocation = "previous_location"
                case groupName = "group_name"
                case type, time, status
                case statusDescription = "status_description"
                case previousStatus = "previous_status"
                case previousStatusDescription = "previous_status_description"
                case bio
                case previousBio = "previous_bio"
                case avatarName = "avatar_name"
                case currentAvatarThumbnailImageUrl = "current_avatar_thumbnail_image_url"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                createdAt = try? c.decode(String.self, forKey: .createdAt)
                userId = try? c.decode(String.self, forKey: .userId)
                displayName = try? c.decode(String.self, forKey: .displayName)
                location = try? c.decode(String.self, forKey: .location)
                worldName = try? c.decode(String.self, forKey: .worldName)
                previousLocation = try? c.decode(String.self, forKey: .previousLocation)
                groupName = try? c.decode(String.self, forKey: .groupName)
                type = try? c.decode(String.self, forKey: .type)
                // VRCX writes "" for an Online row's time
                time = try? c.decode(Double.self, forKey: .time)
                status = try? c.decode(String.self, forKey: .status)
                statusDescription = try? c.decode(String.self, forKey: .statusDescription)
                previousStatus = try? c.decode(String.self, forKey: .previousStatus)
                previousStatusDescription = try? c.decode(String.self, forKey: .previousStatusDescription)
                bio = try? c.decode(String.self, forKey: .bio)
                previousBio = try? c.decode(String.self, forKey: .previousBio)
                avatarName = try? c.decode(String.self, forKey: .avatarName)
                currentAvatarThumbnailImageUrl = try? c.decode(String.self, forKey: .currentAvatarThumbnailImageUrl)
            }
        }
    }

    private func fetch(_ api: VRChatAPI, origin: URL, after: Int? = nil, before: Int? = nil) async throws -> Page {
        var query = [URLQueryItem(name: "limit", value: after != nil ? "500" : "200")]
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        // /relay/v1 sits beside /api/1 on the relay's origin
        return try await api.get("../../relay/v1/feed", query: query)
    }

    /// Rows, in the order given, as feed items. A status row can change the
    /// status and the message at once, which is two items.
    private func convert(_ rows: [Row], origin: URL) -> [FeedItem] {
        let friends = session?.friends
        var result: [FeedItem] = []
        for row in rows {
            let data = row.data
            guard let userId = data.userId, let date = Date(vrchat: data.createdAt) else { continue }
            let name = data.displayName ?? friends?.friends[userId]?.name ?? "Unknown User"
            let image = friends?.friends[userId]?.user.imageURL
            func item(_ kind: FeedItem.Kind, _ suffix: String = "") -> FeedItem {
                FeedItem(id: "f\(row.seq)\(suffix)", date: date, userId: userId, name: name, image: image, kind: kind)
            }
            switch row.table {
            case "feed_gps":
                var entry = item(.location)
                entry.location = data.location
                entry.worldName = data.worldName
                entry.previous = data.previousLocation
                entry.groupName = data.groupName.flatMap { $0.isEmpty ? nil : $0 }
                entry.duration = data.time.map { $0 / 1_000 }
                result.append(entry)
            case "feed_online_offline":
                var entry = item(data.type == "Offline" ? .offline : .online)
                entry.location = data.location
                entry.worldName = data.worldName
                entry.groupName = data.groupName.flatMap { $0.isEmpty ? nil : $0 }
                entry.duration = data.time.map { $0 / 1_000 }
                result.append(entry)
            case "feed_status":
                if data.status != data.previousStatus, let status = data.status {
                    var entry = item(.status, "s")
                    entry.text = UserStatus(status).label
                    entry.previous = data.previousStatus.map { UserStatus($0).label }
                    result.append(entry)
                }
                if (data.statusDescription ?? "") != (data.previousStatusDescription ?? "") {
                    var entry = item(.statusMessage, "m")
                    entry.text = data.statusDescription ?? ""
                    entry.previous = data.previousStatusDescription
                    result.append(entry)
                }
            case "feed_bio":
                var entry = item(.bio)
                entry.text = data.bio
                entry.previous = data.previousBio
                result.append(entry)
            case "feed_avatar":
                var entry = item(.avatar)
                entry.avatarName = data.avatarName
                entry.avatarImage = data.currentAvatarThumbnailImageUrl.map { Self.throughRelay($0, origin: origin) }
                result.append(entry)
            default:
                continue
            }
        }
        return result
    }

    /// VRChat's own image links, sent the relay's way: its image route needs
    /// no session
    static func throughRelay(_ link: String, origin: URL) -> String {
        let prefix = Connection.vrchatAPI.absoluteString
        guard link.hasPrefix(prefix) else { return link }
        return origin.appending(path: "api/1/").absoluteString + link.dropFirst(prefix.count)
    }

    // MARK: Saving

    private static var url: URL {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "feed.json")
    }

    /// The rows and Portal's place in the relay's feed, saved together
    private struct Saved: Codable {
        var items: [FeedItem]
        var cursor: Int?
        var oldest: Int?
        var hasMore: Bool?
        var epoch: String?
    }

    private static func load() -> Saved {
        guard let data = try? Data(contentsOf: url),
              var saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved(items: []) }
        let cutoff = Date().addingTimeInterval(-keep)
        saved.items = saved.items.filter { $0.fromRelay || $0.date >= cutoff }
        return saved
    }

    /// Saved a moment later, so a burst of changes is one write. It stays on
    /// this phone: it's other people's comings and goings.
    private func persist() {
        guard !isDemo else { return }
        save?.cancel()
        let snapshot = Saved(items: items, cursor: cursor, oldest: oldest, hasMore: hasMore, epoch: epoch)
        let url = Self.url
        save = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
