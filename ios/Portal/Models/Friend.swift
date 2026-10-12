import Foundation

/// What someone has set as their status
enum UserStatus: String, CaseIterable, Sendable {
    case joinMe = "join me"
    case online = "active"
    case askMe = "ask me"
    case busy
    case offline

    init(_ raw: String?) {
        self = UserStatus(rawValue: raw ?? "") ?? .online
    }

    var label: String {
        switch self {
        case .joinMe: "Join Me"
        case .online: "Online"
        case .askMe: "Ask Me"
        case .busy: "Busy"
        case .offline: "Offline"
        }
    }

    /// The order the wrist sorts by: most open first
    var rank: Int {
        switch self {
        case .joinMe: 0
        case .online: 1
        case .askMe: 2
        case .busy: 3
        case .offline: 4
        }
    }

    /// The statuses you can choose for yourself
    static let choosable: [UserStatus] = [.online, .joinMe, .askMe, .busy]
}

/// A friend, with where they are and since when
struct Friend: Identifiable, Hashable, Sendable {
    /// In the game, on the website or app only, or gone
    enum State: String, Sendable {
        case online, active, offline
    }

    var user: VRCUser
    var state: State
    /// VRChat's location string: "wrld_…:…", "private", "traveling", "offline"
    var location: String
    var travelingTo: String?
    /// When Portal saw them arrive where they are (nil if they were there
    /// before Portal looked)
    var locationSince: Date?
    var stateSince: Date?
    var platform: String?

    var id: String { user.id }
    var name: String { user.name }
    var place: Location { Location(location) }

    var status: UserStatus {
        state == .offline ? .offline : UserStatus(user.status)
    }

    var isInGame: Bool { state == .online }

    /// "PC", "Quest", "iOS", "Web"
    var platformName: String? {
        Self.platformName(platform ?? user.platform ?? user.lastPlatform)
    }

    static func platformName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "standalonewindows": return "PC"
        case "android": return "Android"
        case "ios": return "iOS"
        case "web": return "Web"
        default: return raw
        }
    }
}

/// Where a friend sits in the list, as on the wrist
enum FriendPlace: Int, CaseIterable, Sendable {
    case joinable, inGame, notInGame, offline

    var title: String {
        switch self {
        case .joinable: "Joinable"
        case .inGame: "Private / Unavailable"
        case .notInGame: "Not In Game"
        case .offline: "Offline"
        }
    }
}

/// Whether you can get to a friend
enum Access: Sendable {
    case canJoin, canRequest, cannotJoin

    var label: String {
        switch self {
        case .canJoin: "Can Join"
        case .canRequest: "Can Request"
        case .cannotJoin: "Cannot Join"
        }
    }
}

enum FriendFilter: String, CaseIterable, Identifiable, Sendable {
    case all, online, joinable, favourites, offline

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "person.2"
        case .online: "circle.inset.filled"
        case .joinable: "arrow.right.circle"
        case .favourites: "star"
        case .offline: "moon.zzz"
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .online: "Online"
        case .joinable: "Joinable"
        case .favourites: "Favourites"
        case .offline: "Offline"
        }
    }
}

struct FriendSection: Identifiable {
    let id: String
    let title: String
    let friends: [Friend]
}
