import BackgroundTasks
import Foundation
import UserNotifications

/// For sign-ins with no relay to push: iOS wakes Portal now and then, and
/// it posts a notification for invites, invite requests and friend requests
/// it hasn't told you about. iOS decides when (often a few times an hour,
/// less when the battery's low, never after Portal is swiped away), so this
/// is a fallback, not live.
enum BackgroundCheck {
    /// Read back from the bundle: the signer changes the bundle ID
    static var identifier: String {
        (Bundle.main.bundleIdentifier ?? "com.example.portal") + ".refresh"
    }

    private static let enabledKey = "backgroundCheck"
    private static let knownKey = "notifiedIds"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { schedule() } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        }
    }

    /// Before launch finishes, as BackgroundTasks requires
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task {
                await run()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        guard isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Notifications Portal has already shown, or that you've seen in the
    /// app, so nothing is announced twice
    static func remember(_ ids: [String]) {
        var known = UserDefaults.standard.stringArray(forKey: knownKey) ?? []
        let existing = Set(known)
        known += ids.filter { !existing.contains($0) }
        UserDefaults.standard.set(Array(known.suffix(300)), forKey: knownKey)
    }

    static func run() async {
        guard isOn, let api = await SavedSession.api() else { return }
        guard let notifications: [VRCNotification] = try? await api.get("auth/user/notifications", query: [
            URLQueryItem(name: "n", value: "50"),
        ]) else { return }
        let known = Set(UserDefaults.standard.stringArray(forKey: knownKey) ?? [])
        let fresh = notifications.filter { notification in
            !(notification.seen ?? false) && !known.contains(notification.id)
                && ["invite", "requestInvite", "friendRequest"].contains(notification.type)
        }
        for notification in fresh {
            post(notification)
        }
        remember(notifications.map(\.id))
    }

    /// Shaped like the relay's pushes, so the same buttons work on it
    private static func post(_ notification: VRCNotification) {
        let item = InboxItem(source: .v1(notification))
        let content = UNMutableNotificationContent()
        content.title = notification.senderUsername ?? "VRChat"
        content.body = item.headline(worldName: nil)
        content.sound = .default
        content.threadIdentifier = notification.senderUserId ?? notification.type
        switch notification.type {
        case "invite":
            content.categoryIdentifier = "INVITE"
            content.interruptionLevel = .timeSensitive
        case "requestInvite":
            content.categoryIdentifier = "INVITE_REQUEST"
            content.interruptionLevel = .timeSensitive
        default:
            content.categoryIdentifier = "FRIEND_REQUEST"
        }
        var relay: [String: Any] = ["type": notification.type, "notificationId": notification.id]
        relay["senderUserId"] = notification.senderUserId
        relay["location"] = notification.details?.worldId
        content.userInfo = ["relay": relay]
        let request = UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// The saved session, for when iOS wakes Portal without a screen: a button
/// on a notification, or a background check
enum SavedSession {
    @MainActor static func api() -> VRChatAPI? {
        guard let data = UserDefaults.standard.data(forKey: "connection"),
              let connection = try? JSONDecoder().decode(Connection.self, from: data) else { return nil }
        let api = VRChatAPI(connection: connection)
        return api.cookies.isEmpty ? nil : api
    }
}
