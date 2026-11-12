#if canImport(UserNotifications) && os(iOS)
import UserNotifications

/// Notification Service Extension for iAlert pushes. Subclass it as your extension's principal
/// class (`NSExtensionPrincipalClass`); nothing else is needed. It
/// - downloads `ialert.image` and attaches it, so the notification shows the picture;
/// - turns a message with `ialert.sender` into a communication notification: the sender's
///   photo and name in place of the app icon (needs the "Communication Notifications"
///   capability on the app and `INSendMessageIntent` in the app's `NSUserActivityTypes`).
///
/// Pushes that are not from iAlert are passed on unchanged, so it can share the extension with
/// other providers: override `didReceive` and call `super` for iAlert ones.
open class IAlertNotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNNotificationContent?
    private var work: Task<Void, Never>?
    private let lock = NSLock()

    open override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        lock.withLock {
            self.contentHandler = contentHandler
            bestAttempt = content
        }

        guard let ialert = content.userInfo["ialert"] as? [String: Any] else {
            finish(with: content)
            return
        }

        let sender = ServiceSender(ialert["sender"])
        let image = (ialert["image"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }

        work = Task { [weak self] in
            async let attachment = Self.attachment(from: image)
            async let avatar = CommunicationNotification.download(sender?.avatar)

            if let attachment = await attachment {
                content.attachments = [attachment]
            }
            self?.lock.withLock { self?.bestAttempt = content }

            var result: UNNotificationContent = content
            if let sender {
                result = await CommunicationNotification.update(content, sender: sender, avatar: await avatar)
            }
            self?.finish(with: result)
        }
    }

    open override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(with: nil)
    }

    /// Hands the content to iOS once; on timeout the best version so far.
    private func finish(with content: UNNotificationContent?) {
        let (handler, fallback): (((UNNotificationContent) -> Void)?, UNNotificationContent?) = lock.withLock {
            defer { contentHandler = nil }
            return (contentHandler, bestAttempt)
        }
        guard let handler, let shown = content ?? fallback else { return }
        handler(shown)
    }

    private static func attachment(from url: URL?) async -> UNNotificationAttachment? {
        guard let url, let (location, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }

        let ext: String
        switch response.mimeType {
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
