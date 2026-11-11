import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

#if canImport(UserNotifications)
/// Shows local notifications through `UNUserNotificationCenter`, tagged with the
/// notification id so a later APNs copy of the same message is recognised.
public struct UserNotificationsNotifier: LocalNotifier {
    public init() {}

    public func deliveredNotificationIds() async -> Set<String> {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return Set(delivered.compactMap { ($0.request.content.userInfo["ialert"] as? [String: Any])?["id"] as? String })
    }

    public func show(_ message: IAlertMessage) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title ?? ""
        content.body = message.body ?? ""
        content.sound = .default
        var ialert: [String: Any] = ["id": message.id]
        ialert["image"] = message.image
        if let data = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(message.data)) {
            ialert["data"] = data
        }
        content.userInfo = ["ialert": ialert]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ialert-\(message.id)", content: content, trigger: nil))
    }
}

public extension IAlert {
    /// Ask for permission to show notifications and, on iOS, register for APNs.
    /// The token then arrives in `didRegisterForRemoteNotificationsWithDeviceToken`; pass it to `setAPNsToken`.
    @discardableResult
    func requestPushAuthorization(options: UNAuthorizationOptions = [.alert, .sound, .badge]) async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        #if canImport(UIKit) && os(iOS)
        if granted {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
        #endif
        return granted
    }
}
#endif

#if canImport(BackgroundTasks) && os(iOS)
public extension IAlert {
    /// Register the background Inbox sync. Call once at launch, before the app finishes
    /// launching, with an identifier listed under `BGTaskSchedulerPermittedIdentifiers`
    /// in Info.plist, and enable the "Background fetch" background mode.
    func registerBackgroundSync(identifier: String, notifier: LocalNotifier = UserNotificationsNotifier()) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            self.scheduleBackgroundSync(identifier: identifier)
            let work = Task {
                let ok = (try? await self.backgroundSync(notifier: notifier)) != nil
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Ask iOS to run the sync again; iOS picks the time (at least `after` seconds from now).
    func scheduleBackgroundSync(identifier: String, after: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: after)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
