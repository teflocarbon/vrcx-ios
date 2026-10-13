import Foundation

// VRChat's API objects, as Portal reads them. Every field but the ID is
// optional: VRChat adds and drops fields without notice, and a missing one
// mustn't stop Portal from working. The relay passes these through as they
// are, so both connections decode the same way.

/// You, from `GET auth/user`
struct CurrentUser: Codable, Sendable, Hashable {
    let id: String
    var displayName: String?
    var status: String?
    var statusDescription: String?
    var statusHistory: [String]?
    var bio: String?
    var pronouns: String?
    var currentAvatarThumbnailImageUrl: String?
    var currentAvatarImageUrl: String?
    var profilePicOverride: String?
    var profilePicOverrideThumbnail: String?
    var userIcon: String?
    var tags: [String]?
    var friends: [String]?
    var onlineFriends: [String]?
    var activeFriends: [String]?
    var offlineFriends: [String]?
    var presence: Presence?
    var lastPlatform: String?

    struct Presence: Codable, Sendable, Hashable {
        var world: String?
        var instance: String?
        var platform: String?
        var travelingToWorld: String?
        var travelingToInstance: String?
        var status: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, status, statusDescription, statusHistory, bio, pronouns
        case currentAvatarThumbnailImageUrl, currentAvatarImageUrl, profilePicOverride
        case profilePicOverrideThumbnail, userIcon, tags, friends, onlineFriends
        case activeFriends, offlineFriends, presence
        case lastPlatform = "last_platform"
    }

    /// Where you are, from your presence: "wrld_…:12345~…", or nil when
    /// you're not in an instance
    var location: String? {
        guard let world = presence?.world, let instance = presence?.instance,
              world.hasPrefix("wrld_"), !instance.isEmpty else { return nil }
        return instance.contains(":") ? instance : "\(world):\(instance)"
    }

    var asUser: VRCUser {
        var user = VRCUser(id: id)
        user.displayName = displayName
        user.status = status
        user.statusDescription = statusDescription
        user.bio = bio
        user.pronouns = pronouns
        user.currentAvatarThumbnailImageUrl = currentAvatarThumbnailImageUrl
        user.currentAvatarImageUrl = currentAvatarImageUrl
        user.profilePicOverride = profilePicOverride
        user.profilePicOverrideThumbnail = profilePicOverrideThumbnail
        user.userIcon = userIcon
        user.tags = tags
        user.location = location
        user.lastPlatform = presence?.platform ?? lastPlatform
        return user
    }
}

/// Anyone else: a friend from `auth/user/friends`, a profile from
/// `users/{id}`, or the `user` in a pipeline event
struct VRCUser: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var displayName: String?
    var status: String?
    var statusDescription: String?
    var bio: String?
    var bioLinks: [String]?
    var pronouns: String?
    var location: String?
    var travelingToLocation: String?
    var platform: String?
    var lastPlatform: String?
    var lastLogin: String?
    var lastActivity: String?
    var dateJoined: String?
    var currentAvatarThumbnailImageUrl: String?
    var currentAvatarImageUrl: String?
    var profilePicOverride: String?
    var profilePicOverrideThumbnail: String?
    var userIcon: String?
    var tags: [String]?
    var developerType: String?
    var isFriend: Bool?
    var friendKey: String?
    /// "online", "active" or "offline", on `users/{id}`
    var state: String?
    var note: String?

    init(id: String) {
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, status, statusDescription, bio, bioLinks, pronouns, location
        case travelingToLocation, platform, currentAvatarThumbnailImageUrl, currentAvatarImageUrl
        case profilePicOverride, profilePicOverrideThumbnail, userIcon, tags, developerType
        case isFriend, friendKey, state, note
        case lastPlatform = "last_platform"
        case lastLogin = "last_login"
        case lastActivity = "last_activity"
        case dateJoined = "date_joined"
    }

    /// This user with anything `newer` knows filled in over it. Pipeline
    /// events carry partial users, so a missing field keeps what we had.
    func merged(with newer: VRCUser) -> VRCUser {
        var user = self
        user.displayName = newer.displayName ?? displayName
        user.status = newer.status ?? status
        user.statusDescription = newer.statusDescription ?? statusDescription
        user.bio = newer.bio ?? bio
        user.bioLinks = newer.bioLinks ?? bioLinks
        user.pronouns = newer.pronouns ?? pronouns
        user.location = newer.location ?? location
        user.travelingToLocation = newer.travelingToLocation ?? travelingToLocation
        user.platform = newer.platform ?? platform
        user.lastPlatform = newer.lastPlatform ?? lastPlatform
        user.lastLogin = newer.lastLogin ?? lastLogin
        user.lastActivity = newer.lastActivity ?? lastActivity
        user.dateJoined = newer.dateJoined ?? dateJoined
        user.currentAvatarThumbnailImageUrl = newer.currentAvatarThumbnailImageUrl ?? currentAvatarThumbnailImageUrl
        user.currentAvatarImageUrl = newer.currentAvatarImageUrl ?? currentAvatarImageUrl
        user.profilePicOverride = newer.profilePicOverride ?? profilePicOverride
        user.profilePicOverrideThumbnail = newer.profilePicOverrideThumbnail ?? profilePicOverrideThumbnail
        user.userIcon = newer.userIcon ?? userIcon
        user.tags = newer.tags ?? tags
        user.developerType = newer.developerType ?? developerType
        user.isFriend = newer.isFriend ?? isFriend
        user.friendKey = newer.friendKey ?? friendKey
        user.state = newer.state ?? state
        user.note = newer.note ?? note
        return user
    }

    /// The picture VRChat shows for someone: their own icon, then a profile
    /// picture, then their avatar's thumbnail
    var imageURL: String? {
        [userIcon, profilePicOverrideThumbnail, profilePicOverride, currentAvatarThumbnailImageUrl]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    /// Every picture someone has, best first, at `size` pixels: if one
    /// fails to load, the next is tried
    func imageURLs(size: Int) -> [String] {
        var seen = Set<String>()
        return [userIcon, profilePicOverrideThumbnail, profilePicOverride, currentAvatarThumbnailImageUrl, currentAvatarImageUrl]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map { VRChatImage.sized($0, size) }
            .filter { seen.insert($0).inserted }
    }

    /// The larger picture for a profile page
    var largeImageURL: String? {
        [profilePicOverride, currentAvatarImageUrl, imageURL]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    var name: String { displayName ?? "Unknown User" }
}

/// A world, from `worlds/{id}`
struct VRCWorld: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String?
    var authorId: String?
    var authorName: String?
    var description: String?
    var imageUrl: String?
    var thumbnailImageUrl: String?
    var capacity: Int?
    var recommendedCapacity: Int?
    var occupants: Int?
    var publicOccupants: Int?
    var privateOccupants: Int?
    var favorites: Int?
    var visits: Int?
    var heat: Int?
    var popularity: Int?
    var tags: [String]?
    var releaseStatus: String?
    var createdAt: String?
    var updatedAt: String?
    var labsPublicationDate: String?
    var publicationDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, authorId, authorName, description, imageUrl, thumbnailImageUrl
        case capacity, recommendedCapacity, occupants, publicOccupants, privateOccupants
        case favorites, visits, heat, popularity, tags, releaseStatus, labsPublicationDate
        case publicationDate
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// An instance of a world, from `instances/{worldId}:{instanceId}`
struct VRCInstance: Codable, Sendable, Hashable {
    var id: String?
    var location: String?
    var worldId: String?
    var instanceId: String?
    var name: String?
    var type: String?
    var region: String?
    var capacity: Int?
    var userCount: Int?
    var nUsers: Int?
    var queueSize: Int?
    var queueEnabled: Bool?
    var ownerId: String?
    var closedAt: String?
    var full: Bool?
    var hasCapacityForYou: Bool?
    var world: VRCWorld?
    var platforms: [String: Int]?
    /// A custom name some instances have ("Movie Night"); nil for most
    var displayName: String?

    enum CodingKeys: String, CodingKey {
        case id, location, worldId, instanceId, name, type, region, capacity, userCount
        case queueSize, queueEnabled, ownerId, closedAt, full, hasCapacityForYou, world, platforms, displayName
        case nUsers = "n_users"
    }

    var people: Int? { userCount ?? nUsers }
}

/// One of your friend favourites, from `favorites?type=friend`
struct VRCFavorite: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var type: String?
    var favoriteId: String
    var tags: [String]?
}

/// A favourite group, from `favorite/groups?type=friend`: "group_0", shown
/// as its display name
struct VRCFavoriteGroup: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String
    var displayName: String?
    var type: String?
    var visibility: String?
}

/// What `auth/user` says when it wants a second factor first
struct TwoFactorRequired: Decodable {
    let requiresTwoFactorAuth: [String]
}

/// VRChat's error body: `{"error": {"message": "…", "status_code": 401}}`
struct VRCErrorBody: Decodable {
    struct Inner: Decodable {
        let message: String?
    }

    let error: Inner?
}

/// A group, from `groups/{id}`: who owns a group instance
struct VRCGroup: Codable, Sendable, Hashable, Identifiable {
    let id: String
    var name: String?
    var shortCode: String?
    var discriminator: String?
    var iconUrl: String?
    var memberCount: Int?

    /// "FURRY.1234", as VRChat shows a group's code
    var code: String? {
        guard let shortCode, !shortCode.isEmpty else { return nil }
        return discriminator.map { "\(shortCode).\($0)" } ?? shortCode
    }
}
