import SwiftUI
import UIKit

/// Sample data and a starting screen for screenshots: launch with
/// `-demo -demoScreen <name>` (see tools/screenshots.sh). Never touches
/// the Keychain, the network or a real account, so screenshots never show
/// real people. Everyone and everywhere here is made up.
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")

    enum Screen: String, CaseIterable {
        case friends, friend, world, inbox, feed, you, signIn
    }

    static var screen: Screen {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-demoScreen"), index + 1 < arguments.count else {
            return .friends
        }
        return Screen(rawValue: arguments[index + 1]) ?? .friends
    }

    // MARK: Pictures

    /// "demo:<symbol>:<RRGGBB>:<RRGGBB>", drawn here instead of downloaded
    static func picture(_ symbol: String, _ from: UInt32, _ to: UInt32) -> String {
        "demo:\(symbol):\(String(from, radix: 16)):\(String(to, radix: 16))"
    }

    static func image(for url: String) -> UIImage {
        let parts = url.split(separator: ":").map(String.init)
        let symbol = parts.count > 1 ? parts[1] : "person.fill"
        let from = parts.count > 2 ? UInt32(parts[2], radix: 16) ?? 0x7E9DB8 : 0x7E9DB8
        let to = parts.count > 3 ? UInt32(parts[3], radix: 16) ?? 0x968CB3 : 0x968CB3
        return icon(symbol, [UIColor(hex: from), UIColor(hex: to)], size: CGSize(width: 240, height: symbol.hasPrefix("w.") ? 160 : 240))
    }

    static func icon(_ symbol: String, _ colors: [UIColor], size: CGSize) -> UIImage {
        let name = symbol.hasPrefix("w.") ? String(symbol.dropFirst(2)) : symbol
        return UIGraphicsImageRenderer(size: size).image { context in
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height) * 0.42, weight: .semibold)
            if let glyph = UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2))
            }
        }
    }

    // MARK: People and worlds

    static func userId(_ n: Int) -> String {
        String(format: "usr_00000000-0000-0000-0000-%012ld", n)
    }

    static func worldId(_ n: Int) -> String {
        String(format: "wrld_00000000-0000-0000-0000-%012ld", n)
    }

    static let worlds: [VRCWorld] = {
        let samples: [(String, String, UInt32, UInt32, Int)] = [
            ("Lantern Harbour", "w.sailboat.fill", 0x2F6FB0, 0xE0A040, 32),
            ("Midnight Rooftop", "w.moon.stars.fill", 0x26235A, 0x7A4FB8, 24),
            ("Cloud Atelier", "w.cloud.fill", 0x7FB6E8, 0xC9A6E8, 16),
            ("Pixel Arcade", "w.gamecontroller.fill", 0xC2366B, 0x5B3FD6, 40),
            ("Quiet Library", "w.books.vertical.fill", 0x6B4A2E, 0xB08A5A, 20),
            ("Aurora Lake", "w.sparkles", 0x1E8C7A, 0x4B5FD0, 30),
        ]
        return samples.enumerated().map { index, sample in
            var world = VRCWorld(id: worldId(index + 1))
            world.name = sample.0
            world.authorName = "Test Creator"
            world.description = "\(sample.0) is a made-up world, shown for screenshots. Sit by the water, play a round, or just hang out with friends."
            world.thumbnailImageUrl = picture(sample.1, sample.2, sample.3)
            world.imageUrl = world.thumbnailImageUrl
            world.capacity = sample.4
            world.recommendedCapacity = sample.4 / 2
            world.occupants = 40 + index * 37
            world.favorites = 1_200 + index * 2_315
            world.visits = 48_000 + index * 91_000
            world.tags = ["system_approved"]
            return world
        }
    }()

    private struct Person {
        let name: String
        let status: UserStatus
        let message: String
        let state: Friend.State
        let location: String
        let symbol: String
        let colors: (UInt32, UInt32)
        var platform = "standalonewindows"
        var minutesAgo = 0
    }

    private static func instance(_ world: Int, _ number: Int, _ access: String = "", region: String = "eu") -> String {
        "\(worldId(world)):\(number)\(access)~region(\(region))"
    }

    private static var people: [Person] {
        [
            Person(name: "Moonbeam", status: .joinMe, message: "come hang out!", state: .online,
                   location: instance(1, 48213, "~hidden(\(userId(1)))"), symbol: "moon.fill", colors: (0x4B5FD0, 0x9C7BE0), minutesAgo: 84),
            Person(name: "Pixel Fox", status: .online, message: "speedrunning the arcade", state: .online,
                   location: instance(4, 11870), symbol: "hare.fill", colors: (0xE07A3F, 0xC2366B), minutesAgo: 23),
            Person(name: "Kiwi", status: .askMe, message: "", state: .online,
                   location: instance(3, 50021, "~private(\(userId(3)))~canRequestInvite"), symbol: "leaf.fill", colors: (0x4E9A4A, 0xA4C64B),
                   platform: "android", minutesAgo: 51),
            Person(name: "Saturn", status: .busy, message: "recording, back later", state: .online,
                   location: instance(2, 70004, "~private(\(userId(4)))"), symbol: "globe.europe.africa.fill", colors: (0x8A5A2E, 0xD9A55A), minutesAgo: 140),
            Person(name: "Nova Lane", status: .online, message: "", state: .online,
                   location: instance(1, 48213, "~hidden(\(userId(1)))"), symbol: "star.fill", colors: (0xD0A12F, 0xE05A7A), minutesAgo: 12),
            Person(name: "Bramble", status: .joinMe, message: "reading club at 9", state: .online,
                   location: instance(5, 30311, "~friends(\(userId(6)))", region: "use"), symbol: "tree.fill", colors: (0x2E7D5B, 0x8FB85B), minutesAgo: 35),
            Person(name: "Echo", status: .online, message: "on my phone", state: .active,
                   location: "offline", symbol: "waveform", colors: (0x3F8FC0, 0x5BD0C8), platform: "web"),
            Person(name: "Juniper", status: .online, message: "", state: .online,
                   location: "traveling", symbol: "camera.macro", colors: (0x7A4FB8, 0xD07AC0), platform: "ios", minutesAgo: 1),
            Person(name: "Orbit Cat", status: .askMe, message: "", state: .active,
                   location: "offline", symbol: "cat.fill", colors: (0x5A5A6E, 0x9A8FB8), platform: "web"),
            Person(name: "Velvet", status: .offline, message: "", state: .offline,
                   location: "offline", symbol: "heart.fill", colors: (0xA0305A, 0xE07A8A)),
            Person(name: "Quill", status: .offline, message: "", state: .offline,
                   location: "offline", symbol: "pencil.and.scribble", colors: (0x3A4A6E, 0x7A9AC0)),
            Person(name: "Tofu", status: .offline, message: "", state: .offline,
                   location: "offline", symbol: "fork.knife", colors: (0xC0A07A, 0xE8D0A0)),
        ]
    }

    static let me: CurrentUser = {
        var me = CurrentUser(id: userId(99))
        me.displayName = "Test User"
        me.status = UserStatus.joinMe.rawValue
        me.statusDescription = "making a phone app"
        me.bio = "Just a test account, for screenshots."
        me.userIcon = picture("sparkles", 0x2F7FD0, 0x4A40D6)
        me.presence = CurrentUser.Presence(world: worldId(1), instance: instance(1, 48213, "~hidden(\(userId(1)))"), platform: "standalonewindows")
        me.statusHistory = ["making a phone app", "come hang out!", "afk"]
        return me
    }()

    @MainActor static func friends() -> FriendsStore {
        let now = Date()
        let list = people.enumerated().map { index, person in
            var user = VRCUser(id: userId(index + 1))
            user.displayName = person.name
            user.status = person.status == .offline ? UserStatus.online.rawValue : person.status.rawValue
            user.statusDescription = person.message
            user.userIcon = picture(person.symbol, person.colors.0, person.colors.1)
            user.bio = "\(person.name) is a made-up person, shown for screenshots."
            user.tags = ["system_trust_veteran", "language_eng"]
            user.lastPlatform = person.platform
            user.dateJoined = "2021-03-14"
            let since = person.minutesAgo > 0 ? now.addingTimeInterval(-Double(person.minutesAgo) * 60) : nil
            return Friend(user: user, state: person.state, location: person.location,
                          travelingTo: person.location == "traveling" ? instance(6, 22222) : nil,
                          locationSince: since, stateSince: since, platform: person.platform)
        }
        return FriendsStore(
            demoFriends: list,
            favourites: [userId(1), userId(5), userId(10)],
            groups: [userId(1): ["Close Friends"], userId(5): ["Close Friends"], userId(10): ["Group 2"]],
            worlds: worlds
        )
    }

    @MainActor static func session(friends: FriendsStore, inbox: InboxStore, feed: FeedStore) -> SessionStore {
        SessionStore(demoMe: me, friends: friends, inbox: inbox, feed: feed)
    }

    private static func ago(_ minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    @MainActor static func inbox() -> InboxStore {
        func notification(_ n: Int, _ type: String, from person: Int, minutes: Double, seen: Bool = false,
                          details: String? = nil) -> InboxItem {
            var json: [String: Any] = [
                "id": String(format: "not_00000000-0000-0000-0000-%012ld", n),
                "type": type,
                "senderUserId": userId(person),
                "senderUsername": people[person - 1].name,
                "created_at": ago(minutes),
                "seen": seen,
                "message": "",
            ]
            if let details { json["details"] = details }
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            let decoded = (try? JSONDecoder().decode(VRCNotification.self, from: data))
                ?? VRCNotification(id: "not_\(n)", type: type)
            return InboxItem(source: .v1(decoded))
        }
        let invite = "{\"worldId\":\"\(instance(4, 11870))\",\"worldName\":\"Pixel Arcade\",\"inviteMessage\":\"come race us!\"}"
        var group = VRCNotificationV2(id: "not_00000000-0000-0000-0000-000000000009", type: "group.announcement")
        group.title = "Test Group posted an announcement"
        group.message = "Movie night is on Saturday at 8. Bring snacks, and a friend if you like."
        group.createdAt = ago(300)
        group.seen = true
        group.imageUrl = picture("popcorn.fill", 0xC2366B, 0xE0A040)
        return InboxStore(demoItems: [
            notification(1, "invite", from: 2, minutes: 3, details: invite),
            notification(2, "requestInvite", from: 3, minutes: 18, details: "{\"requestMessage\":\"can I join?\"}"),
            notification(3, "friendRequest", from: 11, minutes: 95, seen: true),
            InboxItem(source: .v2(group)),
        ])
    }

    @MainActor static func feed() -> FeedStore {
        let now = Date()
        func item(_ n: Int, _ kind: FeedItem.Kind, person: Int, minutes: Double, location: String? = nil,
                  text: String? = nil, previous: String? = nil) -> FeedItem {
            let who = people[person - 1]
            return FeedItem(id: "demo\(n)", date: now.addingTimeInterval(-minutes * 60), userId: userId(person), name: who.name,
                            image: picture(who.symbol, who.colors.0, who.colors.1), kind: kind, location: location,
                            text: text, previous: previous)
        }
        return FeedStore(demoItems: [
            item(1, .location, person: 5, minutes: 12, location: instance(1, 48213, "~hidden(\(userId(1)))")),
            item(2, .online, person: 2, minutes: 23, location: instance(4, 11870)),
            item(3, .statusMessage, person: 4, minutes: 41, text: "recording, back later"),
            item(4, .status, person: 4, minutes: 41, text: "Busy", previous: "Online"),
            item(5, .location, person: 6, minutes: 35, location: instance(5, 30311, "~friends(\(userId(6)))", region: "use")),
            item(6, .offline, person: 10, minutes: 70),
            item(7, .avatar, person: 1, minutes: 84),
            item(8, .online, person: 1, minutes: 84, location: instance(1, 48213, "~hidden(\(userId(1)))")),
            item(9, .offline, person: 12, minutes: 60 * 22),
            item(10, .online, person: 3, minutes: 60 * 26, location: "private"),
        ])
    }
}
