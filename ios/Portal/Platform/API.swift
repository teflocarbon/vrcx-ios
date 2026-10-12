import Foundation

/// Where Portal talks to: your VRCX relay, or VRChat itself. Both speak
/// VRChat's API (the relay passes it through), so everything above this
/// layer is the same either way.
enum Connection: Codable, Hashable, Sendable {
    /// A relay's origin, e.g. https://relay.example.ts.net
    case relay(URL)
    case direct

    static let vrchatAPI = URL(string: "https://api.vrchat.cloud/api/1/")!
    static let vrchatPipeline = URL(string: "wss://pipeline.vrchat.cloud/")!

    var apiBase: URL {
        switch self {
        case .relay(let origin): origin.appending(path: "api/1/")
        case .direct: Self.vrchatAPI
        }
    }

    /// The pipeline: the relay serves it at its own origin
    var pipelineBase: URL {
        switch self {
        case .relay(let origin):
            var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
            parts.scheme = parts.scheme == "http" ? "ws" : "wss"
            parts.path = "/"
            return parts.url!
        case .direct:
            return Self.vrchatPipeline
        }
    }

    var isRelay: Bool {
        if case .relay = self { return true }
        return false
    }

    /// "relay.example.ts.net", or "VRChat"
    var displayName: String {
        switch self {
        case .relay(let origin): origin.host() ?? origin.absoluteString
        case .direct: "VRChat"
        }
    }

    /// A relay address as typed: "relay.example.ts.net", with or without
    /// https:// or a trailing /api/1, becomes its origin
    static func relayOrigin(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || parts.scheme == "http" else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

/// What went wrong talking to VRChat or the relay, in words for the UI
enum APIError: LocalizedError, Equatable {
    /// The session is gone: sign in again
    case signedOut
    /// The relay is up but has lost its own VRChat session
    case relaySignedOut
    case rateLimited
    case notFound
    case forbidden(String?)
    case http(Int, String?)
    case unreachable(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "You've been signed out. Sign in again to carry on."
        case .relaySignedOut:
            "Your relay is signed out of VRChat. Sign it in again from its admin page."
        case .rateLimited:
            "VRChat is asking Portal to slow down. Try again in a minute."
        case .notFound:
            "VRChat couldn't find that. It may have been deleted."
        case .forbidden(let message):
            message ?? "VRChat didn't allow that."
        case .http(let status, let message):
            message ?? "VRChat answered with an error (\(status))."
        case .unreachable(let message):
            message
        case .unexpected(let message):
            "Portal didn't understand VRChat's answer: \(message)"
        }
    }
}

/// Cookies for one connection, kept in the Keychain: the relay's
/// `vrcx_relay_session`, or VRChat's `auth` and `twoFactorAuth`. Portal
/// sends them itself rather than using iOS's shared cookie store, so they
/// never land on disk outside the Keychain.
final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: String]
    private let key: String

    init(key: String, persisted: Bool) {
        self.key = persisted ? key : ""
        if persisted, let data = Keychain.data(for: key),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cookies = saved
        } else {
            cookies = [:]
        }
    }

    var header: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !cookies.isEmpty else { return nil }
        return cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cookies.isEmpty
    }

    func take(from response: HTTPURLResponse, url: URL) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let name = pair.key as? String, let value = pair.value as? String { result[name] = value }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !received.isEmpty else { return }
        lock.lock()
        for cookie in received {
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 < Date() } ?? false) {
                cookies[cookie.name] = nil
            } else {
                cookies[cookie.name] = cookie.value
            }
        }
        let snapshot = cookies
        lock.unlock()
        save(snapshot)
    }

    func clear() {
        lock.lock()
        cookies.removeAll()
        lock.unlock()
        save([:])
    }

    private func save(_ snapshot: [String: String]) {
        guard !key.isEmpty else { return }
        let data = snapshot.isEmpty ? nil : try? JSONEncoder().encode(snapshot)
        try? Keychain.set(data, for: key)
    }
}

/// VRChat's REST API, through the relay or directly. Records every request
/// in the network log, without headers or query strings.
final class VRChatAPI: Sendable {
    let connection: Connection
    let cookies: CookieJar
    private let session: URLSession

    /// VRChat asks third-party apps to say who they are and how to reach
    /// whoever makes them
    static let userAgent = "Portal/\(BuildInfo.version) (github.com/teflocarbon/vrcx-ios)"

    init(connection: Connection, persisted: Bool = true) {
        self.connection = connection
        cookies = CookieJar(key: "cookies:\(connection.displayName)", persisted: persisted)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        // Paths can hold instance IDs with ~ ( ) and :, which URL accepts as is
        var url = URL(string: path, relativeTo: connection.apiBase)?.absoluteURL ?? connection.apiBase
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        return url
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let data = try await data("GET", path, query: query)
        return try decode(data, path: path)
    }

    @discardableResult
    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, as type: T.Type = T.self) async throws -> T {
        let data = try await data(method, path, body: body)
        return try decode(data, path: path)
    }

    func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws {
        _ = try await data(method, path, body: body)
    }

    /// One request; any 2xx is the body, anything else is an `APIError`
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
              authorization: String? = nil) async throws -> Data {
        let (data, response) = try await raw(method, path, query: query, body: body, authorization: authorization)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.signedOut
        case 503 where connection.isRelay:
            throw APIError.relaySignedOut
        case 429:
            throw APIError.rateLimited
        case 404:
            throw APIError.notFound
        case 403:
            throw APIError.forbidden(Self.message(in: data))
        default:
            throw APIError.http(response.statusCode, Self.message(in: data))
        }
    }

    /// One request, whatever the status
    func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
             authorization: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = url(path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie = cookies.header {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method != "GET" && method != "DELETE" {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            NetworkLog.shared.record(method: method, url: url.absoluteString, status: nil, detail: error.localizedDescription)
            throw APIError.unreachable(Self.describe(error, connection: connection))
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.unexpected("not an HTTP response")
        }
        cookies.take(from: http, url: url)
        let detail = (200..<300).contains(http.statusCode) ? nil : Self.message(in: data)
        NetworkLog.shared.record(method: method, url: url.absoluteString, status: http.statusCode, detail: detail)
        return (data, http)
    }

    private func decode<T: Decodable>(_ data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.unexpected("\(path.split(separator: "?").first ?? ""): \(error.localizedDescription)")
        }
    }

    static func message(in data: Data) -> String? {
        if let body = try? JSONDecoder().decode(VRCErrorBody.self, from: data), let message = body.error?.message {
            return message
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func describe(_ error: URLError, connection: Connection) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "You're offline. Portal will carry on when you're back."
        case .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed:
            if connection.isRelay {
                return "Can't reach your relay at \(connection.displayName). Is Tailscale on?"
            }
            return "Can't reach VRChat. Try again in a moment."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "\(connection.displayName)'s certificate isn't trusted. Relays need a real certificate, for example from tailscale serve."
        case .appTransportSecurityRequiresSecureConnection:
            return "Portal only talks to relays over HTTPS."
        default:
            return error.localizedDescription
        }
    }
}

extension VRChatAPI {
    /// HTTP Basic, the way VRChat (and the relay) want it: each half
    /// percent-encoded as JavaScript's encodeURIComponent does, then joined
    static func basic(username: String, password: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let user = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        let pass = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
    }
}
