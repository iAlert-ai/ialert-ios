import Foundation

/// iAlert iOS SDK. Registers the app as an `ios` device, keeps a Gateway socket
/// open while the app runs, syncs the Inbox after every (re)connect and hands
/// each notification to listeners exactly once.
public final class IAlert: @unchecked Sendable {
    public static let sdkVersion = "0.1.0"

    public struct Configuration {
        /// Public key of the app (`ia_pk_…`).
        public var publicKey: String
        public var apiURL = "https://api.ialert.ir/api/v1"
        public var gatewayURL = URL(string: "wss://gw.ialert.ir/v1/connect")!
        public var storage: KeyValueStorage = UserDefaultsStorage()
        public var transport: HTTPTransport = URLSession.shared
        public var webSocketFactory: WebSocketFactory = { URLSessionWebSocketClient(url: $0) }
        /// Connect to the Gateway right after `register()`.
        public var autoConnect = true
        /// Ack `delivered` for every message handed to listeners.
        public var autoAckDelivered = true
        /// Client ping interval; the Gateway drops a socket after about 75 s of silence.
        public var pingInterval: TimeInterval = 30
        public var minReconnectDelay: TimeInterval = 1
        public var maxReconnectDelay: TimeInterval = 60

        public init(publicKey: String) {
            self.publicKey = publicKey
        }
    }

    private struct Registration: Codable {
        let deviceId: String
        let deviceToken: String
    }

    private static let tagKey = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{1,64}$")
    private static let seenLimit = 500

    private let configuration: Configuration
    private let api: ApiClient
    private let store: Store
    private let lock = NSRecursiveLock()
    private var gateway: GatewayConnection?
    private var registration: Registration?
    private var seen: [String]
    private var messageListeners: [UUID: (IAlertMessage) -> Void] = [:]
    private var stateListeners: [UUID: (ConnectionState) -> Void] = [:]
    private var syncTask: Task<[IAlertMessage], Error>?

    public convenience init(publicKey: String) throws {
        try self.init(configuration: Configuration(publicKey: publicKey))
    }

    public init(configuration: Configuration) throws {
        guard configuration.publicKey.hasPrefix("ia_pk_") else {
            throw IAlertError(status: 0, code: "invalid_public_key", message: "Use the app's public key (ia_pk_…); secret keys must never ship in apps.")
        }

        self.configuration = configuration
        api = ApiClient(baseURL: configuration.apiURL, publicKey: configuration.publicKey, transport: configuration.transport)
        store = Store(storage: configuration.storage, namespace: String(configuration.publicKey.suffix(12)))
        registration = store.get(Registration.self, "registration")
        seen = store.get([String].self, "seen") ?? []
    }

    /// The registered device id, or nil before `register()`.
    public var deviceId: String? {
        lock.lock()
        defer { lock.unlock() }
        return registration?.deviceId
    }

    /// Register (or re-register) this install. Safe on every launch. `pushToken` is the
    /// APNs token (hex) once native push is wired; without it a stable installation id is used.
    @discardableResult
    public func register(pushToken: String? = nil, fields: DeviceFields = DeviceFields()) async throws -> Device {
        var body = try Self.body(for: fields)
        body["platform"] = "ios"
        body["push_token"] = .string(pushToken ?? installationId())
        body["sdk_version"] = .string(Self.sdkVersion)
        if fields.locale == nil { body["locale"] = .string(Locale.current.identifier) }
        if fields.timezone == nil { body["timezone"] = .string(TimeZone.current.identifier) }

        let (device, token) = try await api.register(body)
        locked {
            registration = Registration(deviceId: device.id, deviceToken: token)
            store.set(registration, "registration")
        }

        if configuration.autoConnect {
            try connect()
        }

        return device
    }

    /// Update the external user id, tags (merged) or locale of this device.
    @discardableResult
    public func update(_ fields: DeviceFields) async throws -> Device {
        let body = try Self.body(for: fields)
        let registration = try requireRegistration()
        return try await withToken { try await self.api.update(deviceId: registration.deviceId, deviceToken: registration.deviceToken, body) }
    }

    /// Merge tags; a value of `.null` removes the tag.
    @discardableResult
    public func setTags(_ tags: [String: JSONValue]) async throws -> Device {
        try await update(DeviceFields(tags: tags))
    }

    @discardableResult
    public func setExternalUserId(_ externalUserId: String?) async throws -> Device {
        try await update(DeviceFields(externalUserId: .some(externalUserId)))
    }

    /// Stop receiving notifications; call `register()` to subscribe again.
    @discardableResult
    public func unsubscribe() async throws -> Device {
        let registration = try requireRegistration()
        disconnect()
        return try await withToken { try await self.api.unsubscribe(deviceId: registration.deviceId, deviceToken: registration.deviceToken) }
    }

    /// Open the Gateway socket (done by `register()` unless `autoConnect` is off).
    public func connect() throws {
        let registration = try requireRegistration()
        lock.lock()
        guard gateway == nil else { lock.unlock(); return }

        let gateway = GatewayConnection(
            url: configuration.gatewayURL,
            deviceToken: registration.deviceToken,
            makeSocket: configuration.webSocketFactory,
            handlers: GatewayHandlers(
                onReady: { [weak self] in
                    guard let self else { return }
                    Task { _ = try? await self.syncInbox() }
                },
                onMessage: { [weak self] in self?.receive(Self.fromGateway($0)) },
                onUnauthorized: { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    self.gateway = nil
                    self.lock.unlock()
                    self.forget()
                    self.emit(.closed)
                },
                onStateChange: { [weak self] in self?.emit($0) }
            ),
            pingInterval: configuration.pingInterval,
            minReconnect: configuration.minReconnectDelay,
            maxReconnect: configuration.maxReconnectDelay
        )
        self.gateway = gateway
        lock.unlock()
        gateway.start()
    }

    public func disconnect() {
        lock.lock()
        let gateway = self.gateway
        self.gateway = nil
        lock.unlock()
        gateway?.stop()
    }

    /// Pull unread Inbox entries and hand the new ones to listeners. Concurrent calls share one request.
    @discardableResult
    public func syncInbox() async throws -> [IAlertMessage] {
        let task: Task<[IAlertMessage], Error> = locked {
            if let running = syncTask {
                return running
            }
            let task = Task { try await self.pullInbox() }
            syncTask = task
            return task
        }

        defer {
            locked {
                if syncTask == task { syncTask = nil }
            }
        }

        return try await task.value
    }

    /// Report that the user read or clicked notifications (by notification id).
    public func ack(_ ids: [String], event: AckEvent) async throws {
        guard !ids.isEmpty else { return }
        let registration = try requireRegistration()

        let gateway = locked { self.gateway }

        if let gateway, gateway.isReady {
            gateway.ack(ids, event: event)
            return
        }

        try await withToken { try await self.api.ack(deviceId: registration.deviceId, deviceToken: registration.deviceToken, ids: ids, event: event) }
    }

    /// Listen for notifications; call the returned closure to remove the listener.
    @discardableResult
    public func onMessage(_ listener: @escaping (IAlertMessage) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        messageListeners[id] = listener
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.messageListeners[id] = nil
            self?.lock.unlock()
        }
    }

    @discardableResult
    public func onConnectionStateChange(_ listener: @escaping (ConnectionState) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        stateListeners[id] = listener
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.stateListeners[id] = nil
            self?.lock.unlock()
        }
    }

    /// Notifications as an `AsyncStream` (one stream per call).
    public func messages() -> AsyncStream<IAlertMessage> {
        AsyncStream { continuation in
            let remove = onMessage { continuation.yield($0) }
            continuation.onTermination = { _ in remove() }
        }
    }

    /// Connection states as an `AsyncStream` (one stream per call).
    public func connectionStates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let remove = onConnectionStateChange { continuation.yield($0) }
            continuation.onTermination = { _ in remove() }
        }
    }

    // MARK: Internals

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func pullInbox() async throws -> [IAlertMessage] {
        let registration = try requireRegistration()
        let entries = try await withToken { try await self.api.inbox(deviceId: registration.deviceId, deviceToken: registration.deviceToken) }
        // Oldest first, so listeners see messages in the order they were sent.
        let received = entries.reversed().map(Self.fromInbox).filter { receive($0, ack: false) }

        if configuration.autoAckDelivered {
            let undelivered = entries.filter { $0.deliveredAt == nil }.map(\.id)
            try? await ack(undelivered, event: .delivered)
        }

        return received
    }

    /// Dedupe by notification id across Gateway, Inbox and restarts.
    @discardableResult
    private func receive(_ message: IAlertMessage, ack: Bool = true) -> Bool {
        lock.lock()
        guard !seen.contains(message.id) else { lock.unlock(); return false }
        seen.append(message.id)
        seen = Array(seen.suffix(Self.seenLimit))
        store.set(seen, "seen")
        let listeners = Array(messageListeners.values)
        lock.unlock()

        listeners.forEach { $0(message) }

        if ack, configuration.autoAckDelivered {
            Task { try? await self.ack([message.id], event: .delivered) }
        }

        return true
    }

    private func emit(_ state: ConnectionState) {
        lock.lock()
        let listeners = Array(stateListeners.values)
        lock.unlock()
        listeners.forEach { $0(state) }
    }

    private func requireRegistration() throws -> Registration {
        lock.lock()
        defer { lock.unlock() }
        guard let registration else {
            throw IAlertError(status: 0, code: "not_registered", message: "Call register() first.")
        }
        return registration
    }

    private func forget() {
        lock.lock()
        registration = nil
        store.set(Optional<Registration>.none, "registration")
        lock.unlock()
    }

    /// A rejected device token means the device was deleted or unsubscribed elsewhere.
    private func withToken<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as IAlertError where error.code == "device_token_invalid" || error.status == 404 {
            disconnect()
            forget()
            throw error
        }
    }

    private func installationId() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let id = store.get(String.self, "installation") {
            return id
        }

        let id = "ia_ios_\(UUID().uuidString.lowercased())"
        store.set(id, "installation")
        return id
    }

    private static func body(for fields: DeviceFields) throws -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]

        if let externalUserId = fields.externalUserId { body["external_user_id"] = externalUserId }

        if let tags = fields.tags {
            let invalid = tags.keys.filter { key in
                tagKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) == nil
            }.sorted()

            guard invalid.isEmpty else {
                throw IAlertError(status: 0, code: "invalid_tag_key", message: "Tag keys must match [A-Za-z0-9_.:-]{1,64}: \(invalid.joined(separator: ", "))")
            }

            body["tags"] = .object(tags)
        }

        if let locale = fields.locale { body["locale"] = .string(locale) }
        if let timezone = fields.timezone { body["timezone"] = .string(timezone) }
        if let appVersion = fields.appVersion { body["app_version"] = .string(appVersion) }

        return body
    }

    private static func fromGateway(_ message: [String: JSONValue]) -> IAlertMessage {
        let id: String
        switch message["id"] {
        case let .string(value): id = value
        case let .number(value): id = String(Int(value))
        default: id = ""
        }

        return IAlertMessage(
            id: id,
            title: message["title"]?.stringValue,
            body: message["body"]?.stringValue,
            image: message["image"]?.stringValue,
            data: message["data"]?.objectValue ?? [:],
            collapseId: message["collapse_id"]?.stringValue,
            createdAt: message["created_at"]?.stringValue,
            source: .gateway
        )
    }

    private static func fromInbox(_ entry: InboxEntry) -> IAlertMessage {
        IAlertMessage(
            id: entry.id,
            title: entry.content.title,
            body: entry.content.body,
            image: entry.content.image,
            data: entry.content.data?.objectValue ?? [:],
            collapseId: entry.collapseId,
            createdAt: entry.createdAt,
            source: .inbox
        )
    }
}
