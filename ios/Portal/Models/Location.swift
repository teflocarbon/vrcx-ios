import Foundation

/// A VRChat location string, parsed: "offline", "private", "traveling", or
/// `wrld_…:12345~hidden(usr_…)~region(eu)~…`. Follows VRCX's
/// `locationParser.js` (MIT, see NOTICE) rule for rule, so Portal shows the
/// same access types VRCX and the wrist do.
struct Location: Hashable, Sendable {
    let tag: String
    var isOffline = false
    var isPrivate = false
    var isTraveling = false
    var isRealInstance = false
    var worldId = ""
    var instanceId = ""
    /// The instance's number, "12345"
    var instanceName = ""
    var accessType: AccessType?
    var region = ""
    var shortName = ""
    /// Who owns the instance: the private, friends or hidden ID
    var ownerId: String?
    var groupId: String?
    var groupAccessType: String?
    var canRequestInvite = false
    var strict = false
    var ageGate = false

    enum AccessType: String, Sendable {
        case `public`, friendsPlus = "friends+", friends, invitePlus = "invite+", invite, group
    }

    init(_ tag: String?) {
        var text = tag ?? ""
        self.tag = text
        switch text {
        case "offline", "offline:offline":
            isOffline = true
            return
        case "private", "private:private":
            isPrivate = true
            return
        case "traveling", "traveling:traveling":
            isTraveling = true
            return
        default:
            break
        }
        guard !text.isEmpty, !text.hasPrefix("local") else { return }
        isRealInstance = true

        // Not part of the ID, but there when it's copied from a link
        if let range = text.range(of: "&shortName=") {
            shortName = String(text[range.upperBound...])
            text = String(text[..<range.lowerBound])
        }
        guard let colon = text.firstIndex(of: ":") else {
            worldId = text
            return
        }
        worldId = String(text[..<colon])
        instanceId = String(text[text.index(after: colon)...])

        var hiddenId: String?, privateId: String?, friendsId: String?
        for (index, part) in instanceId.split(separator: "~", omittingEmptySubsequences: false).enumerated() {
            guard index > 0 else {
                instanceName = String(part)
                continue
            }
            let key: Substring, value: String
            if let open = part.firstIndex(of: "("), let close = part.lastIndex(of: ")"), open < close {
                key = part[..<open]
                value = String(part[part.index(after: open)..<close])
            } else {
                key = part
                value = ""
            }
            switch key {
            case "hidden": hiddenId = value
            case "private": privateId = value
            case "friends": friendsId = value
            case "canRequestInvite": canRequestInvite = true
            case "region": region = value
            case "group": groupId = value
            case "groupAccessType": groupAccessType = value
            case "strict": strict = true
            case "ageGate": ageGate = true
            default: break
            }
        }

        if let privateId {
            accessType = canRequestInvite ? .invitePlus : .invite
            ownerId = privateId
        } else if let friendsId {
            accessType = .friends
            ownerId = friendsId
        } else if let hiddenId {
            accessType = .friendsPlus
            ownerId = hiddenId
        } else if groupId != nil {
            accessType = .group
        } else {
            accessType = .public
        }
    }

    /// Whether this names a world and an instance someone could be in
    var isInstance: Bool { isRealInstance && !worldId.isEmpty && !instanceId.isEmpty }

    /// VRChat's default when an instance doesn't say is US West
    var resolvedRegion: String {
        if !region.isEmpty { return region }
        return isInstance ? "us" : ""
    }

    /// "Friends+", "Group Public", "Invite"
    var accessName: String {
        switch accessType {
        case .public: "Public"
        case .friendsPlus: "Friends+"
        case .friends: "Friends"
        case .invitePlus: "Invite+"
        case .invite: "Invite"
        case .group:
            switch groupAccessType {
            case "public": "Group Public"
            case "plus": "Group+"
            default: "Group"
            }
        case nil: ""
        }
    }

    /// "Europe", "US West"
    var regionName: String {
        switch resolvedRegion {
        case "us": "US West"
        case "use": "US East"
        case "eu": "Europe"
        case "jp": "Japan"
        case let other: other.uppercased()
        }
    }

    /// The flag VRChat shows for a region
    var regionFlag: String {
        switch resolvedRegion {
        case "us", "use": "🇺🇸"
        case "eu": "🇪🇺"
        case "jp": "🇯🇵"
        default: ""
        }
    }
}
