import Foundation

/// A group in full, from `groups/{id}`
struct VRCGroupDetail: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String?
    var shortCode: String?
    var discriminator: String?
    var description: String?
    var iconUrl: String?
    var bannerUrl: String?
    var privacy: String?
    var joinState: String?
    var rules: String?
    var links: [String]?
    var languages: [String]?
    var memberCount: Int?
    var onlineMemberCount: Int?
    var isVerified: Bool?
    var createdAt: String?
    var membershipStatus: String?
    var myMember: Member?

    struct Member: Codable, Sendable, Hashable {
        var isRepresenting: Bool?
        var isSubscribedToAnnouncements: Bool?
        var joinedAt: String?
    }

    var summary: VRCGroup {
        VRCGroup(id: id, name: name, shortCode: shortCode, discriminator: discriminator, iconUrl: iconUrl,
                 memberCount: memberCount)
    }

    var isMember: Bool { membershipStatus == "member" }

    /// "Public", "Members Only", how people get in
    var privacyName: String {
        switch privacy {
        case "default": "Public"
        case "private": "Private"
        default: privacy?.capitalized ?? "Group"
        }
    }

    var joinName: String? {
        switch joinState {
        case "open": "Anyone can join"
        case "request": "Join by request"
        case "invite": "Join by invite"
        case "closed": "Closed"
        default: nil
        }
    }
}

/// A group's open instance, from `groups/{id}/instances`
struct VRCGroupInstance: Codable, Sendable, Hashable, Identifiable {
    var id: String { location ?? instanceId ?? UUID().uuidString }
    var instanceId: String?
    var location: String?
    var world: VRCWorld?
    var memberCount: Int?
    var userCount: Int?

    /// The full location, however VRChat sent it
    var place: String? {
        if let location, location.contains(":") { return location }
        if let world, let instanceId { return "\(world.id):\(instanceId)" }
        return location
    }

    var people: Int? { memberCount ?? userCount }
}

/// A group's announcement, from `groups/{id}/posts`
struct VRCGroupPost: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var title: String?
    var text: String?
    var imageUrl: String?
    var createdAt: String?
}

/// `groups/{id}/posts` answers `{"posts": […]}` (or, in places, the list)
struct VRCGroupPosts: Decodable {
    let posts: [VRCGroupPost]

    init(from decoder: Decoder) throws {
        if let list = try? [VRCGroupPost](from: decoder) {
            posts = list
            return
        }
        struct Wrapped: Decodable { let posts: [VRCGroupPost]? }
        posts = (try? Wrapped(from: decoder))?.posts ?? []
    }
}

extension VRChatLinks {
    static func group(_ id: String) -> URL {
        URL(string: "https://vrchat.com/home/group/\(id)")!
    }
}
