import UniformTypeIdentifiers
import UserNotifications

/// Adds the sender's picture to Portal's push notifications. The relay puts
/// a link to it in the push, on its own image route, which needs no
/// session, so this never touches the Keychain. If the picture doesn't
/// arrive in time, the notification shows without it.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        handler = contentHandler
        self.content = content

        guard let relay = content.userInfo["relay"] as? [String: Any],
              let link = relay["senderImageUrl"] as? String,
              let url = URL(string: link), url.scheme == "https" else {
            finish()
            return
        }
        var download = URLRequest(url: url, timeoutInterval: 15)
        download.setValue("Portal (github.com/teflocarbon/vrcx-ios)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.downloadTask(with: download) { [weak self] file, response, _ in
            guard let self else { return }
            if let file, let http = response as? HTTPURLResponse, http.statusCode == 200,
               let type = Self.imageType(http.mimeType),
               let attachment = Self.attachment(from: file, type: type) {
                self.content?.attachments = [attachment]
            }
            self.finish()
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    private func finish() {
        guard let handler, let content else { return }
        self.handler = nil
        handler(content)
    }

    /// Only types a notification can show
    private static func imageType(_ mime: String?) -> UTType? {
        guard let mime else { return nil }
        switch mime {
        case "image/png": .png
        case "image/jpeg", "image/jpg": .jpeg
        case "image/gif": .gif
        default: nil
        }
    }

    /// The download is deleted when its handler returns: move it somewhere
    /// the attachment can take it from, with the right extension
    private static func attachment(from file: URL, type: UTType) -> UNNotificationAttachment? {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = folder.appending(path: "sender").appendingPathExtension(for: type)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: destination)
            return try UNNotificationAttachment(identifier: "sender", url: destination, options: [
                UNNotificationAttachmentOptionsTypeHintKey: type.identifier,
            ])
        } catch {
            return nil
        }
    }
}
