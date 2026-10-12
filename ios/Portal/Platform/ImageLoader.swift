import UIKit

/// Pictures of people and worlds. Through the relay they need no session
/// (it serves them itself); straight from VRChat, its file URLs want the
/// auth cookie, so this adds it for VRChat's API host only, never for
/// anyone else's. Kept in memory and in a disk cache between launches.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var api: VRChatAPI?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 200 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
        memory.countLimit = 400
    }

    func use(_ api: VRChatAPI?) {
        lock.lock()
        self.api = api
        lock.unlock()
    }

    /// Read under the lock from a plain function: locks can't be held across
    /// an await
    private var currentAPI: VRChatAPI? {
        lock.lock()
        defer { lock.unlock() }
        return api
    }

    func cached(_ url: String) -> UIImage? {
        memory.object(forKey: url as NSString)
    }

    func image(_ string: String) async -> UIImage? {
        if let image = memory.object(forKey: string as NSString) { return image }
        if string.hasPrefix("demo:") {
            let image = Demo.image(for: string)
            memory.setObject(image, forKey: string as NSString)
            return image
        }
        guard let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url)
        request.setValue(VRChatAPI.userAgent, forHTTPHeaderField: "User-Agent")
        if let api = currentAPI, url.host() == api.connection.apiBase.host(), let cookie = api.cookies.header {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = await Self.decode(result.0) else { return nil }
        memory.setObject(image, forKey: string as NSString)
        return image
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
