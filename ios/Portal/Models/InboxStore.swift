import Foundation
import Observation

/// Invites, requests and group notices: loaded over REST, then kept up to
/// date from the pipeline. Accepting, joining and sending invites are
/// always things you tap; nothing here answers anyone by itself.
@MainActor
@Observable
final class InboxStore {
    private(set) var items: [InboxItem] = []
    private(set) var isLoading = false
    private(set) var loadedAt: Date?
    var error: String?
    /// Items being acted on, for spinners
    private(set) var busy: Set<String> = []

    @ObservationIgnored private weak var session: SessionStore?
    private let isDemo: Bool

    init() {
        isDemo = false
    }

    init(demoItems: [InboxItem]) {
        isDemo = true
        items = demoItems
        loadedAt = Date()
    }

    func attach(_ session: SessionStore) {
        self.session = session
        if session.api == nil && !isDemo {
            items = []
            loadedAt = nil
        }
    }

    private var api: VRChatAPI? { session?.api }

    var unreadCount: Int { items.filter { !$0.seen }.count }

    func filtered(_ filter: InboxFilter) -> [InboxItem] {
        let list: [InboxItem]
        switch filter {
        case .all: list = items
        case .social: list = items.filter(\.isSocial)
        case .groups: list = items.filter { $0.kind == .group }
        case .unread: list = items.filter { !$0.seen }
        }
        return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: Loading

    func refresh() async {
        guard !isDemo, let api, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let v1: [VRCNotification] = try await api.get("auth/user/notifications", query: [
                URLQueryItem(name: "n", value: "100"),
            ])
            // The newer kind is optional: an older relay or an outage there
            // shouldn't hide invites
            let v2: [VRCNotificationV2] = (try? await api.get("notifications", query: [
                URLQueryItem(name: "n", value: "100"),
            ])) ?? []
            items = v1.map { InboxItem(source: .v1($0)) } + v2.map { InboxItem(source: .v2($0)) }
            loadedAt = Date()
            error = nil
        } catch {
            session?.friends.handle(error)
            self.error = error.userMessage
        }
    }

    func refreshIfStale() async {
        guard let loadedAt, Date().timeIntervalSince(loadedAt) < 60 else {
            await refresh()
            return
        }
    }

    // MARK: Live updates

    private struct V2Update: Decodable {
        let id: String
        var updates: Updates?

        struct Updates: Decodable {
            var seen: Bool?
        }
    }

    private struct V2Delete: Decodable {
        let ids: [String]
    }

    /// Apply a pipeline event; returns whether it was about notifications.
    /// Calls `arrived` for something new, so Portal can say so.
    @discardableResult
    func apply(_ event: PipelineEvent, arrived: (InboxItem) -> Void = { _ in }) -> Bool {
        switch event.type {
        case "notification":
            guard let notification = event.decode(VRCNotification.self) else { return true }
            let item = InboxItem(source: .v1(notification))
            insert(item, arrived: arrived)
        case "notification-v2":
            guard let notification = event.decode(VRCNotificationV2.self) else { return true }
            let item = InboxItem(source: .v2(notification))
            insert(item, arrived: arrived)
        case "see-notification":
            markSeenLocally(event.text.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
        case "hide-notification", "response-notification":
            struct Responded: Decodable {
                let notificationId: String
            }
            let id = event.decode(Responded.self)?.notificationId
                ?? event.text.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            items.removeAll { $0.id == id }
        case "notification-v2-update":
            if let update = event.decode(V2Update.self), update.updates?.seen == true {
                markSeenLocally(update.id)
            }
        case "notification-v2-delete":
            if let delete = event.decode(V2Delete.self) {
                items.removeAll { delete.ids.contains($0.id) }
            }
        default:
            return false
        }
        return true
    }

    private func insert(_ item: InboxItem, arrived: (InboxItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
            arrived(item)
        }
    }

    private func markSeenLocally(_ id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = items[index].with(seen: true)
        }
    }

    // MARK: Answering

    private func run(_ item: InboxItem, _ work: (VRChatAPI) async throws -> Void) async throws {
        if isDemo { return }
        guard let api else { throw APIError.signedOut }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        try await work(api)
    }

    func markSeen(_ item: InboxItem) async {
        guard !item.seen else { return }
        markSeenLocally(item.id)
        try? await run(item) { api in
            switch item.source {
            case .v1(let n): try await api.send("PUT", "auth/user/notifications/\(n.id)/see")
            case .v2(let n): try await api.send("POST", "notifications/\(n.id)/see")
            }
        }
    }

    func markAllSeen() async {
        for item in items where !item.seen {
            await markSeen(item)
        }
    }

    /// Clear something from the inbox: hidden on VRChat, so VRCX clears it
    /// too
    func dismiss(_ item: InboxItem) async throws {
        try await run(item) { api in
            switch item.source {
            case .v1(let n): try await api.send("PUT", "auth/user/notifications/\(n.id)/hide")
            case .v2(let n): try await api.send("DELETE", "notifications/\(n.id)")
            }
        }
        items.removeAll { $0.id == item.id }
    }

    func acceptFriendRequest(_ item: InboxItem) async throws {
        guard case .v1(let n) = item.source else { return }
        try await run(item) { api in
            try await api.send("PUT", "auth/user/notifications/\(n.id)/accept")
        }
        items.removeAll { $0.id == item.id }
        Task { await session?.friends.refresh() }
    }

    /// One of a newer notification's own buttons ("Accept", "Join Group")
    func respond(_ item: InboxItem, with response: VRCNotificationV2.Response) async throws {
        guard case .v2(let n) = item.source else { return }
        try await run(item) { api in
            var body: [String: Any] = ["responseType": response.type]
            if let data = response.data { body["responseData"] = data }
            try await api.send("POST", "notifications/\(n.id)/respond", body: body)
        }
        items.removeAll { $0.id == item.id }
    }

    func isBusy(_ item: InboxItem) -> Bool {
        busy.contains(item.id)
    }
}
