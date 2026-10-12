import UIKit

/// Pictures of people and worlds. Through the relay they need no session
/// (it serves them itself); straight from VRChat, its file URLs want the
/// auth cookie, so this adds it for VRChat's API host only, never for
/// anyone else's. Kept in memory and in a disk cache between launches.
///
/// VRChat refuses pictures asked for too quickly, and the Friends list
/// wants a hundred at once, so they queue: a few at a time, each URL
/// fetched once however many rows want it, retried when VRChat says to
/// slow down, and left alone for a while after it really fails.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var api: VRChatAPI?
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private let gate = Gate(limit: 4)

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 200 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        memory.countLimit = 400
    }

    func use(_ api: VRChatAPI?) {
        withLock {
            self.api = api
            failedAt = [:]
        }
    }

    func cached(_ url: String) -> UIImage? {
        memory.object(forKey: url as NSString)
    }

    /// The first of `urls` that loads
    func image(_ urls: [String]) async -> UIImage? {
        for url in urls {
            if let image = await image(url) { return image }
        }
        return nil
    }

    func image(_ string: String) async -> UIImage? {
        if let image = memory.object(forKey: string as NSString) { return image }
        if string.hasPrefix("demo:") {
            let image = Demo.image(for: string)
            memory.setObject(image, forKey: string as NSString)
            return image
        }
        let task: Task<UIImage?, Never> = withLock {
            if let running = inFlight[string] { return running }
            // Recently failed: don't ask VRChat for it again yet
            if let failed = failedAt[string], Date().timeIntervalSince(failed) < 120 {
                return Task { nil }
            }
            let task = Task { await self.fetch(string) }
            inFlight[string] = task
            return task
        }
        let image = await task.value
        withLock {
            inFlight[string] = nil
            failedAt[string] = image == nil ? Date() : nil
        }
        if let image { memory.setObject(image, forKey: string as NSString) }
        return image
    }

    /// Locks can't be held across an await: everything under the lock goes
    /// through here, in plain synchronous code
    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    private func fetch(_ string: String) async -> UIImage? {
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url)
        request.setValue(VRChatAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let api = withLock { self.api }
        if let api, !api.connection.isRelay, url.host() == api.connection.apiBase.host(),
           let cookie = api.cookies.header {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        await gate.enter()
        defer { Task { await gate.leave() } }
        for attempt in 0..<3 {
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch {
                NetworkLog.shared.record(method: "IMAGE", url: string, status: nil, detail: error.localizedDescription)
                return nil
            }
            let http = result.1 as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) {
                return await Self.decode(result.0)
            }
            NetworkLog.shared.record(method: "IMAGE", url: string, status: status, detail: VRChatAPI.message(in: result.0))
            // Too many at once, or the relay or VRChat having a moment: wait
            // and try again; anything else won't get better
            guard status == 429 || status >= 500, attempt < 2 else { return nil }
            let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            try? await Task.sleep(for: .seconds(min(wait ?? Double(2 << attempt), 10)))
        }
        return nil
    }

    /// Decoded off the main thread, and shrunk: VRChat's pictures can be
    /// 2048 px wide and most are shown at 50 points
    private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 600, height: 600 * image.size.height / max(image.size.width, 1)))
                ?? image
        }.value
    }
}

/// At most `limit` at a time; the rest wait their turn
private actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func enter() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// VRChat's picture links, at the size they're shown. Profile pictures and
/// icons come as links to the whole file; VRChat also serves any of them
/// resized at /image/<file>/<version>/<size>, as VRCX asks for them, which
/// is far smaller and kinder to its limits.
enum VRChatImage {
    static func sized(_ link: String, _ size: Int) -> String {
        guard var parts = URLComponents(string: link) else { return link }
        let path = parts.path
        guard let match = path.firstMatch(of: /\/(?:file|image)\/(file_[0-9A-Za-z-]+)\/(\d+)/),
              let prefix = path.range(of: "/api/1/") else { return link }
        parts.path = String(path[..<prefix.upperBound]) + "image/\(match.1)/\(match.2)/\(size)"
        return parts.string ?? link
    }
}
