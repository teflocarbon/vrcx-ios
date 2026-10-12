import Foundation
import Observation

/// Who you're signed in as, and through what: your relay or VRChat itself.
/// Owns the API and the pipeline, and hands pipeline events to the stores
/// that care about them.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        /// Checking a saved session at launch
        case restoring
        case signedOut
        case signedIn
    }

    private(set) var phase: Phase = .restoring
    private(set) var connection: Connection?
    private(set) var me: CurrentUser?
    private(set) var pipelineState: Pipeline.State = .stopped
    /// The relay is up but its own VRChat session has gone
    private(set) var relaySignedOut = false
    /// Why the last refresh failed, when it isn't one of the above
    var problem: String?

    /// VRChat wants a second factor: which kinds it accepts ("totp",
    /// "emailOtp", "otp")
    private(set) var twoFactorMethods: [String]?

    @ObservationIgnored private(set) var api: VRChatAPI?
    @ObservationIgnored private var pipeline: Pipeline?
    @ObservationIgnored private var pendingAPI: VRChatAPI?
    let friends: FriendsStore
    let inbox: InboxStore
    let feed: FeedStore
    /// Something new arrived in the inbox while Portal is open
    @ObservationIgnored var onArrival: ((InboxItem) -> Void)?
    /// So signing out can stop the relay pushing to this phone
    @ObservationIgnored weak var push: PushStore?
    private let isDemo: Bool

    private static let connectionKey = "connection"

    init(friends: FriendsStore, inbox: InboxStore, feed: FeedStore) {
        self.friends = friends
        self.inbox = inbox
        self.feed = feed
        friends.onFeed = { [weak feed] item in feed?.add(item) }
        isDemo = false
    }

    init(demoMe: CurrentUser, friends: FriendsStore, inbox: InboxStore, feed: FeedStore) {
        self.friends = friends
        self.inbox = inbox
        self.feed = feed
        isDemo = true
        me = demoMe
        connection = .relay(URL(string: "https://relay.example.com")!)
        phase = .signedIn
        pipelineState = .connected
    }

    var savedConnection: Connection? {
        guard let data = UserDefaults.standard.data(forKey: Self.connectionKey) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    // MARK: Signing in

    /// At launch: carry on with the saved session if there is one
    func restore() async {
        guard !isDemo else { return }
        guard let saved = savedConnection else {
            phase = .signedOut
            return
        }
        let api = VRChatAPI(connection: saved)
        guard !api.cookies.isEmpty else {
            phase = .signedOut
            return
        }
        connection = saved
        self.api = api
        ImageLoader.shared.use(api)
        friends.attach(api: api, session: self)
        inbox.attach(self)
        feed.attach(self)
        // Signed in until VRChat says otherwise: offline at launch shouldn't
        // mean signing in again
        phase = .signedIn
        await refresh()
        startLive()
    }

    /// Sign in to a relay with a login from its admin page. The relay holds
    /// the VRChat session, so there's never a second factor here.
    func signIn(relay address: String, login: String, password: String) async throws {
        guard let origin = Connection.relayOrigin(from: address) else {
            throw SignInError("That doesn't look like a relay address. Try something like relay.example.ts.net.")
        }
        guard origin.scheme == "https" else {
            throw SignInError("Portal only talks to relays over HTTPS. Use your relay's tailscale serve address.")
        }
        let connection = Connection.relay(origin)
        let api = VRChatAPI(connection: connection)
        api.cookies.clear()
        let authorization = VRChatAPI.basic(username: login, password: password)
        let (data, response) = try await api.raw("GET", "auth/user", authorization: authorization)
        switch response.statusCode {
        case 200:
            let user = try decodeUser(data)
            finishSignIn(api: api, user: user)
        case 401:
            throw SignInError("That login or password isn't right. Logins are made on the relay's admin page.")
        case 429:
            throw SignInError("Too many tries. Wait a few minutes, then try again.")
        case 503:
            throw SignInError("Your relay is signed out of VRChat. Sign it in from its admin page first.")
        case 404:
            throw SignInError("There's no VRCX relay at that address.")
        default:
            throw SignInError(VRChatAPI.message(in: data) ?? "The relay answered with an error (\(response.statusCode)).")
        }
    }

    /// Sign in to VRChat itself. Your password is used once and never kept;
    /// only the session cookies are, in the Keychain.
    func signIn(vrchat username: String, password: String) async throws {
        let api = VRChatAPI(connection: .direct)
        api.cookies.clear()
        let authorization = VRChatAPI.basic(username: username, password: password)
        let (data, response) = try await api.raw("GET", "auth/user", authorization: authorization)
        switch response.statusCode {
        case 200:
            if let required = try? JSONDecoder().decode(TwoFactorRequired.self, from: data) {
                pendingAPI = api
                twoFactorMethods = required.requiresTwoFactorAuth
                return
            }
            finishSignIn(api: api, user: try decodeUser(data))
        case 401:
            throw SignInError(VRChatAPI.message(in: data).map { "VRChat says: \($0)" }
                ?? "That username or password isn't right.")
        case 429:
            throw SignInError("Too many tries. Wait a few minutes, then try again.")
        default:
            throw SignInError(VRChatAPI.message(in: data) ?? "VRChat answered with an error (\(response.statusCode)).")
        }
    }

    /// The code from an authenticator app, an email, or a recovery code
    func verify(code: String, method: String) async throws {
        guard let api = pendingAPI else { throw SignInError("Start again from the beginning.") }
        struct Verified: Decodable {
            let verified: Bool
        }
        let path = switch method {
        case "emailOtp": "auth/twofactorauth/emailotp/verify"
        case "otp": "auth/twofactorauth/otp/verify"
        default: "auth/twofactorauth/totp/verify"
        }
        let trimmed = code.filter { !$0.isWhitespace }
        let result: Verified
        do {
            result = try await api.send("POST", path, body: ["code": trimmed])
        } catch APIError.signedOut {
            throw SignInError("That code didn't work. Check it and try again.")
        }
        guard result.verified else { throw SignInError("That code didn't work. Check it and try again.") }
        let user: CurrentUser = try await api.get("auth/user")
        finishSignIn(api: api, user: user)
    }

    func cancelTwoFactor() {
        pendingAPI?.cookies.clear()
        pendingAPI = nil
        twoFactorMethods = nil
    }

    private func decodeUser(_ data: Data) throws -> CurrentUser {
        do {
            return try JSONDecoder().decode(CurrentUser.self, from: data)
        } catch {
            throw SignInError("Signed in, but Portal didn't understand the answer. Is that a VRCX relay?")
        }
    }

    private func finishSignIn(api: VRChatAPI, user: CurrentUser) {
        pendingAPI = nil
        twoFactorMethods = nil
        self.api = api
        ImageLoader.shared.use(api)
        connection = api.connection
        me = user
        relaySignedOut = false
        problem = nil
        if let data = try? JSONEncoder().encode(api.connection) {
            UserDefaults.standard.set(data, forKey: Self.connectionKey)
        }
        friends.attach(api: api, session: self)
        inbox.attach(self)
        feed.attach(self)
        phase = .signedIn
        Task { await refresh() }
        startLive()
    }

    /// Sign out: from a relay this only ends Portal's relay login; directly,
    /// it ends this VRChat session (others, like VRCX's, carry on)
    func signOut() async {
        await push?.unregister()
        stopLive()
        if let api {
            try? await api.send(api.connection.isRelay ? "POST" : "PUT", "logout")
            api.cookies.clear()
        }
        clearSession()
    }

    /// VRChat or the relay said the session has gone
    func sessionEnded() {
        stopLive()
        api?.cookies.clear()
        clearSession()
        problem = "You've been signed out. Sign in again to carry on."
    }

    private func clearSession() {
        api = nil
        ImageLoader.shared.use(nil)
        me = nil
        relaySignedOut = false
        friends.attach(api: nil, session: self)
        inbox.attach(self)
        feed.attach(self)
        phase = .signedOut
    }

    func relayIsSignedOut() {
        relaySignedOut = true
    }

    func updateMe(_ user: CurrentUser) {
        me = user
        relaySignedOut = false
    }

    // MARK: Keeping up to date

    /// Reload you and your friends
    func refresh() async {
        guard !isDemo, api != nil else { return }
        async let people: Void = friends.refresh()
        async let notices: Void = inbox.refresh()
        async let history: Void = feed.refresh()
        _ = await (people, notices, history)
    }

    /// Start the pipeline, while Portal is on screen
    func startLive() {
        guard !isDemo, phase == .signedIn, let api else { return }
        if pipeline == nil {
            let pipeline = Pipeline(api: api)
            pipeline.onEvent = { [weak self] event in self?.handle(event) }
            pipeline.onState = { [weak self] state in self?.pipelineState = state }
            pipeline.onNeedsRefresh = { [weak self] in
                Task { await self?.refresh() }
            }
            pipeline.onSignedOut = { [weak self] in self?.sessionEnded() }
            self.pipeline = pipeline
        }
        pipeline?.start()
    }

    func stopLive() {
        pipeline?.stop()
        pipeline = nil
    }

    var recentEvents: [PipelineEvent] { pipeline?.recent ?? [] }

    private struct SelfLocation: Decodable {
        var location: String?
        var travelingToLocation: String?
    }

    private struct SelfUpdate: Decodable {
        var user: CurrentUser?
    }

    private func handle(_ event: PipelineEvent) {
        relaySignedOut = false
        if friends.apply(event) {
            // With a relay feed, the relay will have a row for it shortly
            feed.nudge(offline: event.type == "friend-offline")
            return
        }
        if inbox.apply(event, arrived: { [weak self] item in self?.onArrival?(item) }) { return }
        switch event.type {
        case "user-location":
            guard var me, let content = event.decode(SelfLocation.self) else { return }
            let location = Location(content.location)
            var presence = me.presence ?? CurrentUser.Presence()
            if location.isInstance {
                presence.world = location.worldId
                presence.instance = location.tag
            } else {
                presence.world = content.location
                presence.instance = nil
            }
            me.presence = presence
            self.me = me
            friends.requestWorld(location.worldId)
        case "user-update":
            guard let user = event.decode(SelfUpdate.self)?.user, let me else { return }
            var updated = me
            updated.displayName = user.displayName ?? me.displayName
            updated.status = user.status ?? me.status
            updated.statusDescription = user.statusDescription ?? me.statusDescription
            updated.bio = user.bio ?? me.bio
            updated.currentAvatarThumbnailImageUrl = user.currentAvatarThumbnailImageUrl ?? me.currentAvatarThumbnailImageUrl
            updated.profilePicOverride = user.profilePicOverride ?? me.profilePicOverride
            updated.userIcon = user.userIcon ?? me.userIcon
            self.me = updated
        default:
            break
        }
    }

    // MARK: Your status

    /// Set your status and status message (32 characters at most)
    func setStatus(_ status: UserStatus, message: String) async throws {
        guard let me else { return }
        let trimmed = String(message.prefix(32))
        if isDemo {
            var updated = me
            updated.status = status.rawValue
            updated.statusDescription = trimmed
            self.me = updated
            return
        }
        guard let api else { throw APIError.signedOut }
        let user: CurrentUser = try await api.send("PUT", "users/\(me.id)", body: [
            "status": status.rawValue,
            "statusDescription": trimmed,
        ])
        var updated = me
        updated.status = user.status ?? status.rawValue
        updated.statusDescription = user.statusDescription ?? trimmed
        updated.statusHistory = user.statusHistory ?? me.statusHistory
        self.me = updated
    }
}

struct SignInError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
