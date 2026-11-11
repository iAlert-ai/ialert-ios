# ialert-ios

iAlert iOS SDK, a Swift Package with no dependencies (Foundation's `URLSession` and `URLSessionWebSocketTask` only). It registers the app as an `ios` device and receives notifications while the app runs, over iAlert's own channel: a WebSocket to the iAlert Gateway, plus the device Inbox for anything sent while the app was closed. Each notification reaches your listeners once, across both channels and restarts. iOS 15+.

## Install

In Xcode: **File → Add Package Dependencies…** and enter `https://github.com/iAlert-ai/ialert-ios`, or in `Package.swift`:

```swift
.package(url: "https://github.com/iAlert-ai/ialert-ios", from: "0.3.0")
// target dependency:
.product(name: "IAlert", package: "ialert-ios")
```

## Usage

```swift
import IAlert

let ialert = try IAlert(publicKey: "ia_pk_live_…")

ialert.onMessage { message in show(message.title, message.body, message.data) }
// or: for await message in ialert.messages() { … }
// connection: ialert.onConnectionStateChange { … } / ialert.connectionStates()

try await ialert.register(fields: DeviceFields(externalUserId: "user-42", tags: ["plan": "gold"]))

try await ialert.setTags(["plan": "silver", "trial": nil]) // merged; nil removes
try await ialert.ack([message.id], event: .clicked)
try await ialert.unsubscribe()
```

- Use the app's **public** key (`ia_pk_…`); secret keys are refused.
- `register(pushToken:)` sends your APNs token (hex). Without one, a stable installation id is used. Calling it on every launch is safe.
- `delivered` is acked automatically (`autoAckDelivered = false` turns it off). Report `read` / `clicked` yourself. Acks go over the socket when it is ready, otherwise over HTTP.
- `IAlert.Configuration` lets you inject `storage` (defaults to `UserDefaults`), `transport` (`URLSession`), `webSocketFactory`, `apiURL`, `gatewayURL`, `autoConnect` and the ping/reconnect timings.

## Native push (APNs), images and outages

**1. APNs.** Add the *Push Notifications* capability, put the app's `.p8` in the iAlert panel (environment **sandbox** for builds run from Xcode, **production** for TestFlight/App Store), then:

```swift
// AppDelegate
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    ialert.registerBackgroundSync(identifier: "com.example.app.ialert-sync") // step 3
    Task { try? await ialert.requestPushAuthorization() }
    return true
}

func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { try? await ialert.setAPNsToken(deviceToken, fields: DeviceFields(externalUserId: "user-42")) }
}

func applicationDidEnterBackground(_ application: UIApplication) {
    ialert.scheduleBackgroundSync(identifier: "com.example.app.ialert-sync")
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    ialert.didReceiveRemoteNotification(notification.request.content.userInfo) // listeners get it once
    return [.banner, .sound]
}

func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    await ialert.didOpenNotification(response.notification.request.content.userInfo) // acked as clicked
}
```

**2. Images.** Add a *Notification Service Extension* target, add the `IAlertNotificationService` product of this package to it, and make its principal class a subclass:

```swift
import IAlertNotificationService

final class NotificationService: IAlertNotificationService {}
```

It downloads `ialert.image` (HTTPS only) and attaches it to the notification.

**3. While APNs is unreachable (internet shutdown).** iAlert keeps every message in the device Inbox. `registerBackgroundSync` lets iOS run a background refresh that pulls Inbox messages no channel delivered yet and shows them as local notifications, skipping any APNs already shows. In Info.plist add the identifier under `BGTaskSchedulerPermittedIdentifiers`, and enable *Background Modes → Background fetch*. **iOS decides when this runs** (depending on battery, network and how often the user opens the app), so during an outage messages arrive with a delay and are not guaranteed; when the app is open they arrive at once over the Gateway.

## Live Activity broadcasts (iOS 18+)

One push from your server updates a Live Activity on every subscribed device (scores, deliveries, flights). Your server creates the channel with `POST /v1/live-activity-channels` (the app's APNs `.p8` must be in the iAlert panel, and the App ID needs the **Broadcast Capability** under Push Notifications) and gives its `channel_id` to the app.

The app subscribes its Live Activity to the channel with ActivityKit; nothing goes through this SDK:

```swift
import ActivityKit

let activity = try Activity.request(
    attributes: MatchAttributes(home: "Persepolis", away: "Esteghlal"),
    content: .init(state: MatchAttributes.ContentState(home: 0, away: 0), staleDate: nil),
    pushType: .channel(channelId)
)
```

Every broadcast's `content_state` must decode as your `ContentState`. iOS shows `update` events and ends the activity on `end`. Live Activities need a Widget Extension and iOS 18+; test broadcasts on a device (a Simulator on an Apple-silicon Mac receives APNs only from the sandbox environment).

## Development

```bash
swift build
swift test      # fakes for HTTP and WebSocket, no device needed
```

API reference: `docs/api-v1.md` in the iAlert server repository.

## License

Copyright 2026 iAlert.ir

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).
