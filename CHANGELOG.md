# Changelog

## 0.6.0

- Notification links: the new `url` field (`ialert.url` in APNs) opens on tap: Safari or a Universal Link for web links, the app itself for deep links with its URL scheme. `IAlert.onNotificationClick` lets the app route taps itself. `IAlertMessage.url`; `data.url` still works.
- Registration sends a stable `installation_id`, the device model (`hw.machine`) and the iOS version, so one install stays one device across the internal network and APNs.

## 0.5.1

- Background sync leaves `pushed` entries unacknowledged, so they are shown once the platform switches to its internal network during an outage.

## 0.5.0

- `IAlert.start(publicKey:)`: one-line setup with no AppDelegate code. Picks up the APNs token, forwards notification-center delegate calls, shows iAlert notifications in the foreground, acks taps and opens `data.url`, manages the Gateway across foreground/background and schedules background sync when `<bundle id>.ialert-sync` is permitted.
- `IAlert.login(_:)` sets the external user id.
- Custom notification sounds: `IAlertMessage.sound`, used by background-sync local notifications (`none` is silent).
- Local notifications from background sync carry the message data, so taps open `data.url`.
- Background sync skips Inbox entries APNs already took (`pushed`), so a notification the user dismissed is not shown again.

## 0.4.0

- Auth Push: `respondToAuthRequest` approves or denies a sign-in request on this device (with the typed number for number matching), and a helper reads the request a message carries.

## 0.3.0

- APNs: `requestPushAuthorization()`, `setAPNsToken(_:)`, `didReceiveRemoteNotification(_:)` (deduplicated against Gateway and Inbox, acked delivered) and `didOpenNotification(_:)` (acked clicked).
- `IAlertNotificationService` product: a Notification Service Extension that attaches `ialert.image`.
- Outages: `registerBackgroundSync` / `scheduleBackgroundSync` run a background refresh that shows undelivered Inbox messages as local notifications, skipping those APNs already shows.

## 0.2.0

- README: subscribing a Live Activity to an iAlert broadcast channel with ActivityKit (iOS 18+). No API change.

## 0.1.0

- First release: device registration with a public key, tags and external user id, a live connection to the iAlert Gateway over WebSocket with reconnect, Inbox sync after each connect, delivered/read/clicked acknowledgements and message de-duplication.
- Licensed under Apache 2.0.
