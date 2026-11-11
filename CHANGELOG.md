# Changelog

## 0.3.0

- APNs: `requestPushAuthorization()`, `setAPNsToken(_:)`, `didReceiveRemoteNotification(_:)` (deduplicated against Gateway and Inbox, acked delivered) and `didOpenNotification(_:)` (acked clicked).
- `IAlertNotificationService` product: a Notification Service Extension that attaches `ialert.image`.
- Outages: `registerBackgroundSync` / `scheduleBackgroundSync` run a background refresh that shows undelivered Inbox messages as local notifications, skipping those APNs already shows.

## 0.2.0

- README: subscribing a Live Activity to an iAlert broadcast channel with ActivityKit (iOS 18+). No API change.

## 0.1.0

- First release: device registration with a public key, tags and external user id, a live connection to the iAlert Gateway over WebSocket with reconnect, Inbox sync after each connect, delivered/read/clicked acknowledgements and message de-duplication.
- Licensed under Apache 2.0.
