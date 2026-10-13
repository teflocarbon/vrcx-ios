import Foundation
import Observation

/// A notification from the relay's history, with what became of it
struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var seq: Int
    var item: InboxItem
    var seen: Bool
    var hidden: Bool
    var responded: Bool
    /// VRCX's own mark: cleared or answered (imported rows have only this)
    var expired: Bool

    var date: Date { item.date ?? .distantPast }

    /// "Answered", "Cleared", "Seen", or nothing
    var outcome: (text: String, symbol: String)? {
        if responded { return ("Answered", "checkmark.circle") }
        if hidden || expired { return ("Cleared", "xmark.circle") }
        if seen { return ("Seen", "eye") }
        return nil
    }
}

/// Every notification the relay has seen, as VRCX keeps them, including
/// ones VRChat has long since forgotten and VRCX's own imported past. Read
/// like the feed: the newest page first, Load Earlier for more, and a
/// catch-up from Portal's own place that also brings changes, so an invite
/// answered on the PC shows as answered here.
@MainActor
@Observable
final class NotificationHistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private(set) var available = false
    private(set) var isLoading = false
    private(set) var hasMore = false
    var error: String?

    @ObservationIgnored private weak var session: SessionStore?
    /// The relay's revision Portal has caught up to, the oldest row it has,
    /// and the relay's database: saved in the same write as the rows
    @ObservationIgnored private var rev: Int?
    @ObservationIgnored private var oldest: Int?
    @ObservationIgnored private var instance: String?
    @ObservationIgnored private var save: Task<Void, Never>?
    @ObservationIgnored private var nudgeTask: Task<Void, Never>?
    private let isDemo: Bool

    init() {
        isDemo = false
        let saved = Self.load()
        entries = saved.entries
        rev = saved.rev
        oldest = saved.oldest
        instance = saved.instance
        hasMore = saved.hasMore ?? false
    }

    init(demoEntries: [HistoryEntry]) {
        isDemo = true
        entries = demoEntries
        available = true
    }

    func attach(_ session: SessionStore) {
        self.session = session
        if session.api == nil && !isDemo {
            entries = []
            rev = nil
            oldest = nil
            instance = nil
            hasMore = false
            available = false
            persist()
        }
    }

    /// A notification arrived: the relay will have it shortly
    func nudge() {
        guard available else { return }
        nudgeTask?.cancel()
        nudgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Reading

    func refresh() async {
        guard !isDemo, let session, let api = session.api, case .relay(let origin)? = session.connection,
              !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        available = await RelayProbe.capabilities(origin)?.features.notifications ?? false
        guard available else { return }
        do {
            if let rev, !entries.isEmpty, try await catchUp(api, from: rev) {
                // Caught up
            } else {
                try await loadNewest(api)
            }
            if !hasMore, let oldest {
                // Older history can arrive later, from a VRCX import
                hasMore = try await fetch(api, ["before": oldest, "limit": 1]).rows.isEmpty == false
            }
            error = nil
            persist()
        } catch {
            self.error = error.userMessage
        }
    }

    /// Everything added or changed since `rev`; false when that's too much
    /// or the relay's database has changed, and the newest page is better
    private func catchUp(_ api: VRChatAPI, from rev: Int) async throws -> Bool {
        var since = rev
        for _ in 0..<5 {
            let page = try await fetch(api, ["since": since, "limit": 500])
            if let changed = page.instance, let known = instance, changed != known { return false }
            upsert(page.rows)
            since = page.next ?? since
            if page.rows.count < 500 {
                self.rev = since
                return true
            }
        }
        return false
    }

    private func loadNewest(_ api: VRChatAPI) async throws {
        let page = try await fetch(api, ["before": Int(Int32.max), "limit": 100])
        entries = []
        upsert(page.rows)
        rev = page.rev ?? 0
        oldest = page.rows.last?.seq
        hasMore = page.next != nil
        instance = page.instance
    }

    func loadEarlier() async {
        guard !isDemo, let api = session?.api, let oldest, hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(api, ["before": oldest, "limit": 100])
            upsert(page.rows)
            self.oldest = page.rows.last?.seq ?? oldest
            hasMore = page.next != nil && !page.rows.isEmpty
            persist()
        } catch {
            self.error = error.userMessage
        }
    }

    private func fetch(_ api: VRChatAPI, _ parameters: [String: Int]) async throws -> Page {
        // /relay/v1 sits beside /api/1 on the relay's origin
        try await api.get("../../relay/v1/notifications",
                          query: parameters.map { URLQueryItem(name: $0.key, value: String($0.value)) })
    }

    private func upsert(_ rows: [Row]) {
        guard !rows.isEmpty else { return }
        var byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if let entry = row.entry() { byId[entry.id] = entry }
        }
        entries = byId.values.sorted { $0.date > $1.date }
    }

    // MARK: The relay's rows

    private struct Page: Decodable {
        let rows: [Row]
        let next: Int?
        var rev: Int?
        var instance: String?
    }

    private struct Row: Decodable {
        struct State: Decodable {
            var seen: Bool?
            var hidden: Bool?
            var responded: Bool?
        }

        let seq: Int
        let table: String
        let id: String
        let data: Columns
        var state: State?

        func entry() -> HistoryEntry? {
            let item: InboxItem
            if table == "notifications_v2" {
                var n = VRCNotificationV2(id: id, type: data.type ?? "")
                n.title = data.title
                n.message = data.message
                n.senderUserId = data.senderUserId
                n.senderUsername = data.senderUsername
                n.imageUrl = data.imageUrl.flatMap { $0.isEmpty ? nil : $0 }
                n.link = data.link
                n.linkText = data.linkText
                n.createdAt = data.createdAt
                n.expiresAt = data.expiresAt
                n.seen = data.seen
                item = InboxItem(source: .v2(n))
            } else {
                var n = VRCNotification(id: id, type: data.type ?? "")
                n.senderUserId = data.senderUserId
                n.senderUsername = data.senderUsername
                n.receiverUserId = data.receiverUserId
                n.message = data.message
                n.createdAt = data.createdAt
                n.seen = state?.seen
                n.details = VRCNotification.Details(
                    worldId: data.worldId, worldName: data.worldName, inviteMessage: data.inviteMessage,
                    requestMessage: data.requestMessage, responseMessage: data.responseMessage)
                item = InboxItem(source: .v1(n))
            }
            return HistoryEntry(id: id, seq: seq, item: item, seen: state?.seen ?? data.seen ?? false,
                                hidden: state?.hidden ?? false, responded: state?.responded ?? false,
                                expired: data.expired ?? false)
        }
    }

    /// VRCX's columns for both tables; each row has the ones its table uses
    private struct Columns: Decodable {
        var type: String?
        var createdAt: String?
        var senderUserId: String?
        var senderUsername: String?
        var receiverUserId: String?
        var message: String?
        var worldId: String?
        var worldName: String?
        var imageUrl: String?
        var inviteMessage: String?
        var requestMessage: String?
        var responseMessage: String?
        var expired: Bool?
        var title: String?
        var link: String?
        var linkText: String?
        var expiresAt: String?
        var seen: Bool?

        enum CodingKeys: String, CodingKey {
            case type, message, title, link, expired, seen
            case createdAt = "created_at"
            case senderUserId = "sender_user_id"
            case senderUsername = "sender_username"
            case receiverUserId = "receiver_user_id"
            case worldId = "world_id"
            case worldName = "world_name"
            case imageUrl = "image_url"
            case inviteMessage = "invite_message"
            case requestMessage = "request_message"
            case responseMessage = "response_message"
            case linkText = "link_text"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? { try? c.decode(String.self, forKey: key) }
            // VRCX keeps these as 0 or 1
            func flag(_ key: CodingKeys) -> Bool? {
                if let number = try? c.decode(Int.self, forKey: key) { return number != 0 }
                return try? c.decode(Bool.self, forKey: key)
            }
            type = text(.type)
            createdAt = text(.createdAt)
            senderUserId = text(.senderUserId)
            senderUsername = text(.senderUsername)
            receiverUserId = text(.receiverUserId)
            message = text(.message)
            worldId = text(.worldId)
            worldName = text(.worldName)
            imageUrl = text(.imageUrl)
            inviteMessage = text(.inviteMessage)
            requestMessage = text(.requestMessage)
            responseMessage = text(.responseMessage)
            expired = flag(.expired)
            title = text(.title)
            link = text(.link)
            linkText = text(.linkText)
            expiresAt = text(.expiresAt)
            seen = flag(.seen)
        }
    }

    // MARK: Saving

    private struct Saved: Codable {
        var entries: [HistoryEntry]
        var rev: Int?
        var oldest: Int?
        var instance: String?
        var hasMore: Bool?
    }

    private static var url: URL {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "notification-history.json")
    }

    private static func load() -> Saved {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved(entries: []) }
        return saved
    }

    /// Saved a moment later, so a burst of changes is one write. It stays on
    /// this phone, protected while it's locked: it's other people's messages.
    private func persist() {
        guard !isDemo else { return }
        save?.cancel()
        let snapshot = Saved(entries: entries, rev: rev, oldest: oldest, instance: instance, hasMore: hasMore)
        let url = Self.url
        save = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
}
