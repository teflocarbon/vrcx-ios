import Foundation
import Observation
import UIKit
import UserNotifications

/// Where a tapped notification should take you, picked up by the app
@MainActor
@Observable
final class DeepLinks {
    static let shared = DeepLinks()

    enum Destination: Equatable {
        case inbox
        case user(String)
        case you
    }

    var pending: Destination?
}

/// Receives the push token, and answers notification buttons. The buttons
/// work without opening Portal: iOS wakes it in the background, and it
/// talks to the relay with the saved session.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once its stores exist
    @MainActor static weak var push: PushStore?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationActions.categories)
        BackgroundCheck.register()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppDelegate.push?.received(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in AppDelegate.push?.failed(error) }
    }

    /// While Portal is open, invites and requests already show at the
    /// bottom of the screen, so those only go to Notification Centre
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        switch notification.request.content.categoryIdentifier {
        case "INVITE", "INVITE_REQUEST", "FRIEND_REQUEST", "INVITE_RESPONSE":
            return [.list]
        default:
            return [.banner, .list, .sound]
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await NotificationActions.handle(response)
    }
}

/// The buttons on Portal's notifications, and what they do
enum NotificationActions {
    static let join = "JOIN"
    static let sendInvite = "SEND_INVITE"
    static let accept = "ACCEPT"
    static let requestInvite = "REQUEST_INVITE"

    static var categories: Set<UNNotificationCategory> {
        let joinAction = UNNotificationAction(identifier: join, title: "Join", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "paperplane"))
        let sendAction = UNNotificationAction(identifier: sendInvite, title: "Send Invite", options: [],
                                        icon: UNNotificationActionIcon(systemImageName: "envelope"))
        let acceptAction = UNNotificationAction(identifier: accept, title: "Accept", options: [.authenticationRequired],
                                          icon: UNNotificationActionIcon(systemImageName: "person.badge.plus"))
        let requestAction = UNNotificationAction(identifier: requestInvite, title: "Request Invite", options: [],
                                           icon: UNNotificationActionIcon(systemImageName: "hand.raised"))
        return [
            UNNotificationCategory(identifier: "INVITE", actions: [joinAction], intentIdentifiers: []),
            UNNotificationCategory(identifier: "INVITE_REQUEST", actions: [sendAction], intentIdentifiers: []),
            UNNotificationCategory(identifier: "FRIEND_REQUEST", actions: [acceptAction], intentIdentifiers: []),
            UNNotificationCategory(identifier: "FRIEND_ONLINE", actions: [requestAction], intentIdentifiers: []),
            UNNotificationCategory(identifier: "INVITE_RESPONSE", actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: "RELAY_STATUS", actions: [], intentIdentifiers: []),
        ]
    }

    /// The relay's part of a push: `{"relay": {…}}`
    struct Payload {
        var type: String?
        var notificationId: String?
        var senderUserId: String?
        var location: String?

        init(_ info: [AnyHashable: Any]) {
            let relay = info["relay"] as? [String: Any] ?? [:]
            type = relay["type"] as? String
            notificationId = relay["notificationId"] as? String
            senderUserId = relay["senderUserId"] as? String
            location = relay["location"] as? String
        }
    }

    static func handle(_ response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let payload = Payload(content.userInfo)
        let category = content.categoryIdentifier

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            await MainActor.run {
                switch category {
                case "FRIEND_ONLINE":
                    DeepLinks.shared.pending = payload.senderUserId.map { .user($0) } ?? .inbox
                case "RELAY_STATUS":
                    DeepLinks.shared.pending = .you
                default:
                    DeepLinks.shared.pending = .inbox
                }
            }
            return
        case UNNotificationDismissActionIdentifier:
            return
        default:
            break
        }

        // A button: do it with the saved session, and only speak up if it
        // didn't work (success is quiet, as with Apple's own)
        guard let api = await SavedSession.api() else {
            Notifier.post(title: "Couldn't do that", body: "Open Portal and sign in again.")
            return
        }
        do {
            switch response.actionIdentifier {
            case join:
                guard let location = payload.location else { throw APIError.notFound }
                try await api.send("POST", "invite/myself/to/\(location)")
            case sendInvite:
                guard let sender = payload.senderUserId else { throw APIError.notFound }
                let me: CurrentUser = try await api.get("auth/user")
                guard let mine = me.location else {
                    Notifier.post(title: "Couldn't send the invite", body: "You're not in an instance, so there's nowhere to invite them to.")
                    return
                }
                try await api.send("POST", "invite/\(sender)", body: ["instanceId": mine])
                if let id = payload.notificationId {
                    try? await api.send("PUT", "auth/user/notifications/\(id)/hide")
                }
            case accept:
                guard let id = payload.notificationId else { throw APIError.notFound }
                try await api.send("PUT", "auth/user/notifications/\(id)/accept")
            case requestInvite:
                guard let sender = payload.senderUserId else { throw APIError.notFound }
                try await api.send("POST", "requestInvite/\(sender)")
            default:
                break
            }
        } catch {
            Notifier.post(title: "Couldn't do that", body: error.userMessage)
        }
    }
}
