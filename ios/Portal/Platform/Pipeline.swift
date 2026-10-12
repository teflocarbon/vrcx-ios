import Foundation
import Network

/// One event from VRChat's pipeline: `{"type": "friend-online", "content":
/// "<json>"}`. The content is JSON inside a string; `content` holds it
/// decoded back to bytes (or the raw string, for events like
/// `see-notification` whose content is a bare ID).
struct PipelineEvent: Sendable {
    let type: String
    let content: Data
    let received: Date

    init?(text: String, received: Date = Date()) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        self.type = type
        self.received = received
        switch object["content"] {
        case let string as String:
            content = Data(string.utf8)
        case let value? where JSONSerialization.isValidJSONObject(value):
            content = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        default:
            content = Data()
        }
    }

    init(type: String, content: Data, received: Date = Date()) {
        self.type = type
        self.content = content
        self.received = received
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: content)
    }

    /// The content as text, for events whose content is a bare string
    var text: String { String(decoding: content, as: UTF8.self) }
}

/// The live connection to VRChat's pipeline, through the relay or directly.
/// iOS closes sockets soon after an app leaves the screen, so this runs only
/// while Portal is open: `start` when it becomes active, `stop` when it
/// goes to the background. It reconnects with backoff on its own, and asks
/// for a full refresh whenever events may have been missed.
@MainActor
final class Pipeline {
    enum State: Equatable {
        case stopped, connecting, connected
        case waiting(retryAt: Date)
    }

    private(set) var state: State = .stopped {
        didSet { onState?(state) }
    }

    var onEvent: ((PipelineEvent) -> Void)?
    var onState: ((State) -> Void)?
    /// After a reconnect: events in the gap are lost, so reload everything
    var onNeedsRefresh: (() -> Void)?
    /// The session has gone (401 for the ticket)
    var onSignedOut: (() -> Void)?

    private let api: VRChatAPI
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var failures = 0
    private let session = URLSession(configuration: .ephemeral)
    /// Wi-Fi to cellular and back can leave a socket dead without an error:
    /// a change of network means reconnecting at once
    private let monitor = NWPathMonitor()
    private var lastPath: String?
    private var networkChanged = false

    /// The last few events, for the Developer page
    private(set) var recent: [PipelineEvent] = []

    init(api: VRChatAPI) {
        self.api = api
    }

    func start() {
        guard loop == nil else { return }
        startMonitor()
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        // A stopped pipeline is thrown away, and a monitor can't restart
        monitor.cancel()
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .stopped
    }

    private func run() async {
        var first = true
        while !Task.isCancelled {
            state = .connecting
            let opened = Date()
            let closeCode = await connectOnce(refresh: !first)
            first = false
            if Task.isCancelled { break }
            if closeCode == .signedOut {
                onSignedOut?()
                break
            }
            // A connection that held for a while resets the backoff
            if Date().timeIntervalSince(opened) > 60 { failures = 0 }
            failures += 1
            // The relay closes with 1012 when its own upstream reconnects:
            // come straight back
            let delay = closeCode == .restart || networkChanged ? 1 : backoff(failures)
            networkChanged = false
            state = .waiting(retryAt: Date().addingTimeInterval(delay))
            try? await Task.sleep(for: .seconds(delay))
        }
        if !Task.isCancelled { state = .stopped }
    }

    private enum Outcome: Equatable {
        case closed, restart, signedOut
    }

    private func backoff(_ failures: Int) -> TimeInterval {
        let base = min(60, pow(2, Double(min(failures, 6))))
        return base * Double.random(in: 0.7...1.3)
    }

    /// Fetch a ticket, open the socket and read until it closes
    private func connectOnce(refresh: Bool) async -> Outcome {
        struct Ticket: Decodable {
            let token: String
        }
        let ticket: Ticket
        do {
            ticket = try await api.get("auth")
        } catch APIError.signedOut {
            return .signedOut
        } catch {
            return .closed
        }

        var parts = URLComponents(url: api.connection.pipelineBase, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "authToken", value: ticket.token)]
        var request = URLRequest(url: parts.url!)
        request.setValue(VRChatAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()

        // The pipeline can be quiet for minutes: a ping answered means it's open
        let open = await Self.ping(socket, within: 15)
        guard open, !Task.isCancelled else {
            socket.cancel(with: .goingAway, reason: nil)
            if task === socket { task = nil }
            return socket.closeCode.rawValue == 1012 ? .restart : .closed
        }
        state = .connected
        if refresh { onNeedsRefresh?() }

        // A socket can die without saying so: ping now and then, and close
        // it if there's no answer, so the loop reconnects
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                if await !Self.ping(socket, within: 10) {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let text: String?
                switch message {
                case .string(let string): text = string
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, let event = PipelineEvent(text: text) {
                    remember(event)
                    onEvent?(event)
                }
            } catch {
                break
            }
        }
        let code = socket.closeCode
        socket.cancel(with: .goingAway, reason: nil)
        if task === socket { task = nil }
        // 1012 is "service restart"
        return code.rawValue == 1012 ? .restart : .closed
    }

    private func remember(_ event: PipelineEvent) {
        recent.append(event)
        if recent.count > 100 { recent.removeFirst(recent.count - 100) }
    }

    /// Whether the socket answers a ping in time. A dead socket may never
    /// answer, so give up after `seconds` and close it, which makes the
    /// unanswered ping finish too.
    private nonisolated static func ping(_ socket: URLSessionWebSocketTask, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    socket.sendPing { error in continuation.resume(returning: error == nil) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let answered = await group.next() ?? false
            if !answered { socket.cancel(with: .goingAway, reason: nil) }
            group.cancelAll()
            return answered
        }
    }

    /// Reconnect straight away when the network changes under an open
    /// socket (Wi-Fi to cellular, a VPN like Tailscale coming up)
    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let description = "\(path.status) \(path.availableInterfaces.map(\.name))"
            Task { @MainActor in self?.pathChanged(to: description, satisfied: path.status == .satisfied) }
        }
        if monitor.queue == nil {
            monitor.start(queue: DispatchQueue(label: "Portal.network"))
        }
    }

    private func pathChanged(to description: String, satisfied: Bool) {
        defer { lastPath = description }
        guard let lastPath, lastPath != description, satisfied else { return }
        if state == .connected || state == .connecting {
            networkChanged = true
            task?.cancel(with: .goingAway, reason: nil)
        }
    }
}
