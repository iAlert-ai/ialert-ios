# IAlert (iOS)

iAlert iOS SDK, a Swift Package with no dependencies (Foundation's `URLSession` and `URLSessionWebSocketTask` only). It registers the app as an `ios` device and receives notifications while the app runs, over iAlert's own channel: a WebSocket to the iAlert Gateway, plus the device Inbox for anything sent while the app was closed. Each notification reaches your listeners once, across both channels and restarts. iOS 15+.

```swift
// Package.swift: .package(url: "<repo url>", from: "0.1.0")
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

## Next step: native push

0.1.0 delivers only while the app runs. Next comes APNs integration: pass the device token to `register(pushToken:)`, add a Notification Service Extension, and dedupe APNs payloads by their `ialert.id` against Gateway/Inbox messages (for example by sharing the storage through an App Group).

## Development

```bash
swift build
swift test      # fakes for HTTP and WebSocket, no device needed
```

API reference: `docs/api-v1.md` in the iAlert server repository.

## License

Copyright 2026 iAlert.ir

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE).
