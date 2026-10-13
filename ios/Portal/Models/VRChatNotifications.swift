import Foundation

/// A notification from `auth/user/notifications` or the pipeline's
/// `notification` event: invites, invite requests, friend requests and
/// replies to them
struct VRCNotification: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var type: String
    var senderUserId: String?
    var senderUsername: String?
    var receiverUserId: String?
    var message: String?
    var details: Details?
    var seen: Bool?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, type, senderUserId, senderUsername, receiverUserId, message, details, seen
        case createdAt = "created_at"
    }

    /// VRChat sends `details` as an object, or as JSON inside a string, or
    /// as "{}": take whichever arrives
    struct Details: Codable, Sendable, Hashable {
        var worldId: String?
        var worldName: String?
        var inviteMessage: String?
        var requestMessage: String?
        var responseMessage: String?
        var platform: String?

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                let inner = (try? JSONDecoder().decode(Plain.self, from: Data(string.utf8))) ?? Plain()
                self.init(inner)
                return
            }
            self.init(try Plain(from: decoder))
        }

        init(worldId: String?, worldName: String?, inviteMessage: String?, requestMessage: String?,
             responseMessage: String?, platform: String? = nil) {
            self.worldId = worldId
            self.worldName = worldName
            self.inviteMessage = inviteMessage
            self.requestMessage = requestMessage
            self.responseMessage = responseMessage
            self.platform = platform
        }

        private init(_ plain: Plain) {
            worldId = plain.worldId
            worldName = plain.worldName
            inviteMessage = plain.inviteMessage
            requestMessage = plain.requestMessage
            responseMessage = plain.responseMessage
            platform = plain.platform
        }

        func encode(to encoder: Encoder) throws {
            try Plain(worldId: worldId, worldName: worldName, inviteMessage: inviteMessage, requestMessage: requestMessage,
                      responseMessage: responseMessage, platform: platform).encode(to: encoder)
        }

        private struct Plain: Codable {
            var worldId: String?
            var worldName: String?
            var inviteMessage: String?
            var requestMessage: String?
            var responseMessage: String?
            var platform: String?
        }
    }
}

/// A newer-style notification from `notifications` or the pipeline's
/// `notification-v2`: group announcements, group invites, and the like,
/// each with its own buttons
struct VRCNotificationV2: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var type: String
    var title: String?
    var message: String?
    var senderUserId: String?
    var senderUsername: String?
    var imageUrl: String?
    var link: String?
    var linkText: String?
    var createdAt: String?
    var expiresAt: String?
    var seen: Bool?
    var canDelete: Bool?
    var responses: [Response]?

    struct Response: Codable, Sendable, Hashable {
        var type: String
        var data: String?
        var icon: String?
        var text: String?
    }
}

/// One row in the Inbox, from either kind of notification
struct InboxItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case invite, inviteRequest, friendRequest, inviteResponse, requestResponse, message
        case group, other
    }

    enum Source: Codable, Sendable, Hashable {
        case v1(VRCNotification)
        case v2(VRCNotificationV2)
    }

    let source: Source

    var id: String {
        switch source {
        case .v1(let n): n.id
        case .v2(let n): n.id
        }
    }

    var kind: Kind {
        switch source {
        case .v1(let n):
            switch n.type {
            case "invite": .invite
            case "requestInvite": .inviteRequest
            case "friendRequest": .friendRequest
            case "inviteResponse": .inviteResponse
            case "requestInviteResponse": .requestResponse
            case "message": .message
            default: .other
            }
        case .v2(let n):
            n.type.hasPrefix("group") ? .group : .other
        }
    }

    var isSocial: Bool { kind != .group && kind != .other }

    /// The person it's from: never blank (VRChat's own notices have no
    /// sender), and only a user, not a group
    var senderId: String? {
        let id: String? = switch source {
        case .v1(let n): n.senderUserId
        case .v2(let n): n.senderUserId
        }
        return id.flatMap { $0.hasPrefix("usr_") ? $0 : nil }
    }

    var senderName: String? {
        let name: String? = switch source {
        case .v1(let n): n.senderUsername
        case .v2(let n): n.senderUsername
        }
        // VRCX keeps a blank name for notices from VRChat itself
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Who or what it's from, for the row's name: a group notice leads with
    /// its title ("Test Group posted an announcement")
    var displayName: String? {
        guard case .v2(let n) = source else { return senderName }
        if let title = n.title, !title.isEmpty { return title }
        return senderName
    }

    /// Notices VRChat writes itself (a boop, a gift of VRC+): a plain line,
    /// never quoted as if the sender had written it
    var isSystemLine: Bool {
        guard case .v1 = source else { return false }
        return kind == .other || kind == .message
    }

    var date: Date? {
        switch source {
        case .v1(let n): Date(vrchat: n.createdAt)
        case .v2(let n): Date(vrchat: n.createdAt)
        }
    }

    var seen: Bool {
        switch source {
        case .v1(let n): n.seen ?? false
        case .v2(let n): n.seen ?? false
        }
    }

    /// Where an invite is to
    var location: String? {
        guard case .v1(let n) = source else { return nil }
        return n.details?.worldId
    }

    /// The message someone attached, if any
    var note: String? {
        switch source {
        case .v1(let n):
            let text = n.details?.inviteMessage ?? n.details?.requestMessage ?? n.details?.responseMessage
            if let text, !text.isEmpty { return text }
            return nil
        case .v2(let n):
            // Group posts often end in blank lines
            return n.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "Invited you to Lantern Harbour"
    func headline(worldName: String?) -> String {
        switch source {
        case .v1(let n):
            let world = n.details?.worldName ?? worldName ?? "their instance"
            switch kind {
            case .invite: return "Invited you to \(world)"
            case .inviteRequest: return "Asked you for an invite"
            case .friendRequest: return "Sent you a friend request"
            case .inviteResponse: return "Replied to your invite"
            case .requestResponse: return "Replied to your invite request"
            case .message, .group, .other: return Self.systemLine(n)
            }
        case .v2(let n):
            return n.title ?? n.message ?? "Notification"
        }
    }

    /// "Booped you", "Gifted you 1 month of VRC+": VRChat's own text, without
    /// the sender's name it starts with (the row already shows it)
    private static func systemLine(_ n: VRCNotification) -> String {
        if n.type == "boop" { return "Booped you" }
        var text = (n.message ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        if let name = n.senderUsername, !name.isEmpty, text.hasPrefix(name) {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            for verb in ["has ", "is "] where text.hasPrefix(verb) {
                text = String(text.dropFirst(verb.count))
            }
        }
        text = text.replacingOccurrences(of: "1 months", with: "1 month")
        guard let first = text.first else { return n.type.capitalized }
        return first.uppercased() + text.dropFirst()
    }

    func with(seen: Bool) -> InboxItem {
        switch source {
        case .v1(var n):
            n.seen = seen
            return InboxItem(source: .v1(n))
        case .v2(var n):
            n.seen = seen
            return InboxItem(source: .v2(n))
        }
    }
}

enum InboxFilter: String, CaseIterable, Identifiable, Sendable {
    case all, social, groups, unread, history

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "tray"
        case .social: "person.2"
        case .groups: "person.3"
        case .unread: "envelope.badge"
        case .history: "clock.arrow.circlepath"
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .social: "Social"
        case .groups: "Groups"
        case .unread: "Unread"
        case .history: "History"
        }
    }
}
