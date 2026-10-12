import Foundation
import Observation
import UIKit
import UserNotifications

/// Push notifications, sent by your relay through Apple: invites, requests,
/// friends coming online, and a warning when the relay is signed out.
/// Portal registers this phone with the relay on every launch (the relay
/// drops tokens Apple says are gone), and keeps your choices there, so
/// they apply even while Portal is closed.
@MainActor
@Observable
final class PushStore {
    enum Availability: Equatable {
        /// Checking what the relay offers
        case unknown
        /// Signed in to VRChat directly: nothing to send pushes
        case needsRelay
        /// The relay has no APNs key yet
        case relayNotSetUp
        case available
    }

    /// Kinds of push the relay sends, as it names them
    enum Kind: String, CaseIterable, Identifiable {
        case invite = "INVITE"
        case inviteRequest = "INVITE_REQUEST"
        case friendRequest = "FRIEND_REQUEST"
        case inviteResponse = "INVITE_RESPONSE"
        case friendOnline = "FRIEND_ONLINE"
        case relayStatus = "RELAY_STATUS"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .invite: "Invites"
            case .inviteRequest: "Invite Requests"
            case .friendRequest: "Friend Requests"
            case .inviteResponse: "Replies to Your Invites"
            case .friendOnline: "Friends Coming Online"
            case .relayStatus: "Relay Problems"
            }
        }
    }

    struct Device: Codable, Equatable {
        var token: String
        var topic: String?
        var environment: String?
        var types: [String]?
        var friendsOnline: [String]?
        var quietWhileInVR: Bool?
    }

    private(set) var availability: Availability = .unknown
    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var device: Device?
    private(set) var registering = false
    var error: String?

    @ObservationIgnored private weak var session: SessionStore?
    @ObservationIgnored private(set) var token: String?
    private let isDemo: Bool

    init() {
        isDemo = false
    }

    init(demo: Bool) {
        isDemo = demo
        availability = .available
        permission = .authorized
        device = Device(token: "demo", types: Kind.allCases.map(\.rawValue), friendsOnline: [Demo.userId(1)], quietWhileInVR: false)
    }

    func attach(_ session: SessionStore) {
        self.session = session
    }

    var isOn: Bool { permission == .authorized && device != nil }

    func wants(_ kind: Kind) -> Bool {
        device?.types?.contains(kind.rawValue) ?? true
    }

    func notifiesOnline(_ userId: String) -> Bool {
        device?.friendsOnline?.contains(userId) ?? false
    }

    // MARK: Setting up

    /// After signing in or at launch: see whether the relay can push, and if
    /// you've already allowed notifications, register this phone
    func setUp() async {
        guard !isDemo else { return }
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard case .relay(let origin)? = session?.connection else {
            availability = .needsRelay
            return
        }
        guard let capabilities = await RelayProbe.capabilities(origin) else {
            availability = .relayNotSetUp
            return
        }
        availability = capabilities.features.push ? .available : .relayNotSetUp
        if availability == .available && permission == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Ask iOS, then register. Asked when you turn it on, not at launch.
    func turnOn() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        permission = await center.notificationSettings().authorizationStatus
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// iOS gave us a token: tell the relay where to send pushes
    func received(token data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.token = token
        await register()
    }

    func failed(_ error: Error) {
        self.error = "iOS couldn't set up push notifications: \(error.localizedDescription)"
    }

    private func register() async {
        guard let api = session?.api, api.connection.isRelay, let token else { return }
        registering = true
        defer { registering = false }
        let body: [String: Any] = [
            "token": token,
            // The real bundle ID: the signer replaces the placeholder
            "topic": Bundle.main.bundleIdentifier ?? "",
            "environment": Provisioning.pushEnvironment,
        ]
        do {
            let response: DeviceResponse = try await api.send("POST", "../../relay/v1/push/devices", body: body)
            device = response.device
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }

    private struct DeviceResponse: Decodable {
        let pushEnabled: Bool?
        let device: Device?
    }

    // MARK: Choices

    func set(_ kind: Kind, on: Bool) async {
        var types = Set(device?.types ?? Kind.allCases.map(\.rawValue))
        if on { types.insert(kind.rawValue) } else { types.remove(kind.rawValue) }
        await update(["types": Kind.allCases.map(\.rawValue).filter(types.contains)])
    }

    func setOnline(_ userId: String, on: Bool) async {
        var ids = device?.friendsOnline ?? []
        ids.removeAll { $0 == userId }
        if on { ids.append(userId) }
        await update(["friendsOnline": ids])
    }

    func setQuietWhileInVR(_ on: Bool) async {
        await update(["quietWhileInVR": on])
    }

    private func update(_ changes: [String: Any]) async {
        if isDemo {
            if let types = changes["types"] as? [String] { device?.types = types }
            if let ids = changes["friendsOnline"] as? [String] { device?.friendsOnline = ids }
            if let quiet = changes["quietWhileInVR"] as? Bool { device?.quietWhileInVR = quiet }
            return
        }
        guard let api = session?.api, let token else { return }
        var body = changes
        body["token"] = token
        do {
            let response: DeviceResponse = try await api.send("PUT", "../../relay/v1/push/devices", body: body)
            device = response.device ?? device
            error = nil
        } catch {
            self.error = error.userMessage
        }
    }

    /// Ask the relay to push a test to this phone, and say what Apple said
    func sendTest() async -> String {
        if isDemo { return "Sent. It should arrive in a moment." }
        guard let api = session?.api, let token else { return "This phone isn't registered yet." }
        struct Result: Decodable {
            let ok: Bool
            let status: Int?
            let reason: String?
        }
        do {
            let result: Result = try await api.send("POST", "../../relay/v1/push/test", body: ["token": token])
            if result.ok { return "Sent. It should arrive in a moment." }
            return "Apple refused it: \(result.reason ?? "status \(result.status ?? 0)")."
        } catch {
            return error.userMessage
        }
    }

    /// Before signing out: stop the relay pushing to this phone
    func unregister() async {
        guard let api = session?.api, api.connection.isRelay, let token else { return }
        try? await api.send("DELETE", "../../relay/v1/push/devices", body: ["token": token])
        device = nil
    }
}

/// What this copy of Portal was signed with, read from its provisioning
/// profile: development profiles get pushes from Apple's sandbox
enum Provisioning {
    static var pushEnvironment: String {
        apsEnvironment == "production" ? "production" : "sandbox"
    }

    static let apsEnvironment: String? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // A signed (CMS) wrapper around a plain XML plist
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return nil }
        let xml = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }()
}
