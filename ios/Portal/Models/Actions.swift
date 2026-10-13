import Foundation
import Observation

/// Places a tab can open: someone's profile, a world, an instance
enum Route: Hashable {
    case user(String)
    case world(String)
    case instance(String)
    case group(String)
}

/// The things you can do to or for someone, with a short message after
/// each so you know it went through. Every one is something you tapped:
/// Portal never acts by itself.
@MainActor
@Observable
final class Actions {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
        var failed = false
    }

    private(set) var toast: Toast?
    /// Actions running now, by a key like "invite:usr_…", for spinners
    private(set) var running: Set<String> = []

    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private var dismiss: Task<Void, Never>?

    func attach(_ session: SessionStore) {
        self.session = session
    }

    func dismissToast() {
        dismiss?.cancel()
        toast = nil
    }

    func show(_ text: String, symbol: String = "checkmark.circle.fill", failed: Bool = false) {
        toast = Toast(text: text, symbol: symbol, failed: failed)
        dismiss?.cancel()
        dismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(failed ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func perform(_ key: String, success: String, symbol: String, _ work: (VRChatAPI) async throws -> Void) async {
        if Demo.isOn {
            show(success, symbol: symbol)
            return
        }
        guard let api = session?.api else { return }
        running.insert(key)
        defer { running.remove(key) }
        do {
            try await work(api)
            show(success, symbol: symbol)
        } catch {
            session?.friends.handleSession(error)
            show(error.userMessage, symbol: "exclamationmark.triangle.fill", failed: true)
        }
    }

    /// An invite to yourself, which pops up in the game: the phone's way of
    /// joining someone
    func inviteMyself(to location: String, worldName: String?) async {
        await perform("self:\(location)", success: "Invite sent. Open it in VRChat to join \(worldName ?? "the instance").", symbol: "paperplane.fill") { api in
            try await api.send("POST", "invite/myself/to/\(location)")
        }
    }

    func requestInvite(from friend: Friend) async {
        await perform("request:\(friend.id)", success: "Asked \(friend.name) for an invite", symbol: "hand.raised.fill") { api in
            try await api.send("POST", "requestInvite/\(friend.user.id)")
        }
    }

    /// Invite someone to where you are
    func invite(_ friend: Friend, to location: String) async {
        await perform("invite:\(friend.id)", success: "Invited \(friend.name)", symbol: "envelope.fill") { api in
            try await api.send("POST", "invite/\(friend.user.id)", body: ["instanceId": location])
        }
    }

    func isRunning(_ key: String) -> Bool {
        running.contains(key)
    }
}

/// Links VRChat's website understands, for copying and sharing
enum VRChatLinks {
    static func user(_ id: String) -> URL {
        URL(string: "https://vrchat.com/home/user/\(id)")!
    }

    static func world(_ id: String) -> URL {
        URL(string: "https://vrchat.com/home/world/\(id)")!
    }

    static func instance(_ location: Location) -> URL? {
        guard location.isInstance else { return nil }
        var parts = URLComponents(string: "https://vrchat.com/home/launch")!
        parts.queryItems = [
            URLQueryItem(name: "worldId", value: location.worldId),
            URLQueryItem(name: "instanceId", value: location.instanceId),
        ]
        return parts.url
    }
}
