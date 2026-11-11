#if canImport(UIKit) && os(iOS)
import Foundation
import ObjectiveC
import UIKit
import UserNotifications

public extension IAlert {
    /// The instance created by `start(publicKey:)`, or nil before it.
    private(set) static var shared: IAlert? {
        get { AutoSetup.instance }
        set { AutoSetup.instance = newValue }
    }

    /// One-line setup. Call it once, as early as possible (in the `App` initializer
    /// or `application(_:didFinishLaunchingWithOptions:)`):
    ///
    /// ```swift
    /// IAlert.start(publicKey: "ia_pk_live_…")
    /// ```
    ///
    /// It registers the device, asks for notification permission, picks up the APNs
    /// token without any AppDelegate code, shows iAlert notifications while the app
    /// is open, reports taps, keeps the Gateway connected while the app is in the
    /// foreground and schedules the background Inbox sync for outages (when the
    /// identifier `<bundle id>.ialert-sync` is listed in Info.plist).
    @discardableResult
    static func start(publicKey: String, fields: DeviceFields = DeviceFields(), requestPermission: Bool = true) -> IAlert? {
        if let shared { return shared }

        guard let ialert = try? IAlert(publicKey: publicKey) else {
            assertionFailure("iAlert: use the app's public key (ia_pk_…)")
            return nil
        }

        shared = ialert
        AutoSetup.fields = fields
        AutoSetup.install(ialert, requestPermission: requestPermission)

        return ialert
    }

    /// Set (or clear) the signed-in user of this device for `external_user_ids` targeting.
    static func login(_ externalUserId: String?) {
        AutoSetup.fields.externalUserId = externalUserId.map(JSONValue.string) ?? .null
        guard let shared else { return }
        Task { _ = try? await shared.setExternalUserId(externalUserId) }
    }
}

/// Wires an `IAlert` into UIKit: APNs token capture by method swizzling on the app
/// delegate, a forwarding `UNUserNotificationCenterDelegate`, background sync and
/// Gateway lifecycle. Everything the app did before keeps working.
enum AutoSetup {
    static var instance: IAlert?
    static var fields = DeviceFields()
    private static var token: Data?
    private static var registered = false

    static var syncIdentifier: String { "\(Bundle.main.bundleIdentifier ?? "app").ialert-sync" }

    static func install(_ ialert: IAlert, requestPermission: Bool) {
        NotificationProxy.shared.install()

        if backgroundSyncAllowed {
            ialert.registerBackgroundSync(identifier: syncIdentifier)
        }

        DispatchQueue.main.async {
            swizzleTokenCallbacks()
            Task {
                if requestPermission {
                    _ = try? await ialert.requestPushAuthorization()
                } else {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                // Without a token (simulator, APNs unreachable) the device still gets
                // messages over the Gateway and Inbox; the token re-registers later.
                if token == nil {
                    await register(ialert)
                }
            }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            ialert.disconnect()
            if backgroundSyncAllowed {
                ialert.scheduleBackgroundSync(identifier: syncIdentifier)
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            if ialert.deviceId != nil {
                try? ialert.connect()
            } else {
                Task { await register(ialert) }
            }
        }
    }

    static func didReceive(token deviceToken: Data) {
        token = deviceToken
        guard let ialert = instance else { return }
        Task { await register(ialert) }
    }

    private static func register(_ ialert: IAlert) async {
        if let token {
            _ = try? await ialert.setAPNsToken(token, fields: fields)
        } else {
            _ = try? await ialert.register(fields: fields)
        }
    }

    /// `BGTaskScheduler.register` crashes for identifiers missing from Info.plist.
    private static var backgroundSyncAllowed: Bool {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.contains(syncIdentifier)
    }

    // MARK: APNs token without AppDelegate code

    private static let tokenSelector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))

    private static func swizzleTokenCallbacks() {
        guard let delegate = UIApplication.shared.delegate, let cls = object_getClass(delegate) else { return }

        typealias TokenIMP = @convention(c) (AnyObject, Selector, UIApplication, Data) -> Void
        let original = class_getInstanceMethod(cls, tokenSelector).map { unsafeBitCast(method_getImplementation($0), to: TokenIMP.self) }

        let block: @convention(block) (AnyObject, UIApplication, Data) -> Void = { object, application, deviceToken in
            original?(object, tokenSelector, application, deviceToken)
            AutoSetup.didReceive(token: deviceToken)
        }
        let implementation = imp_implementationWithBlock(block)

        if let method = class_getInstanceMethod(cls, tokenSelector), original != nil {
            method_setImplementation(method, implementation)
        } else {
            class_addMethod(cls, tokenSelector, implementation, "v@:@@")
        }
    }
}

/// Becomes the notification center delegate and forwards every call to the
/// delegate the app had (or sets later), so foreground display and taps of
/// iAlert notifications work without code in the app.
final class NotificationProxy: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationProxy()
    weak var appDelegate: UNUserNotificationCenterDelegate?

    func install() {
        let center = UNUserNotificationCenter.current()
        if let current = center.delegate, current !== self {
            appDelegate = current
        }
        center.delegate = self
    }

    private func isIAlert(_ notification: UNNotification) -> Bool {
        notification.request.content.userInfo["ialert"] != nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if isIAlert(notification) {
            AutoSetup.instance?.didReceiveRemoteNotification(notification.request.content.userInfo)
        }

        if let appDelegate, appDelegate.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            appDelegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            return
        }

        completionHandler(isIAlert(notification) ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        if isIAlert(response.notification), let ialert = AutoSetup.instance {
            Task { await ialert.didOpenNotification(userInfo) }
            AutoSetup.openURL(from: userInfo)
        }

        if let appDelegate, appDelegate.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            appDelegate.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        appDelegate?.userNotificationCenter?(center, openSettingsFor: notification)
    }
}

extension AutoSetup {
    /// Opens `data.url` of a tapped notification (a deep link or web page), if set.
    static func openURL(from userInfo: [AnyHashable: Any]) {
        let data = (userInfo["ialert"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        guard let string = data["url"] as? String, let url = URL(string: string) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }
}
#endif
