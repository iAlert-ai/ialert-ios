#if canImport(UserNotifications) && os(iOS)
import UserNotifications

/// Notification Service Extension for iAlert pushes: downloads `ialert.image` and
/// attaches it so the notification shows the picture. Subclass it as your
/// extension's principal class (`NSExtensionPrincipalClass`); nothing else is needed.
open class IAlertNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var download: URLSessionDownloadTask?

    open override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        bestAttempt = content

        guard let ialert = content.userInfo["ialert"] as? [String: Any],
              let image = ialert["image"] as? String,
              let url = URL(string: image), url.scheme == "https" else {
            contentHandler(content)
            return
        }

        download = URLSession.shared.downloadTask(with: url) { [weak self] location, response, _ in
            guard let self else { return }
            if let location, let attachment = Self.attachment(from: location, url: url, mimeType: response?.mimeType) {
                content.attachments = [attachment]
            }
            self.finish()
        }
        download?.resume()
    }

    open override func serviceExtensionTimeWillExpire() {
        download?.cancel()
        finish()
    }

    private func finish() {
        guard let handler = contentHandler, let content = bestAttempt else { return }
        contentHandler = nil
        handler(content)
    }

    private static func attachment(from location: URL, url: URL, mimeType: String?) -> UNNotificationAttachment? {
        let ext: String
        switch mimeType {
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/jpeg", "image/jpg": ext = "jpg"
        default: ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)

        do {
            try FileManager.default.moveItem(at: location, to: file)
            return try UNNotificationAttachment(identifier: "ialert-image", url: file)
        } catch {
            return nil
        }
    }
}
#endif
