import Foundation

struct GatewayHandlers {
    var onReady: () -> Void
    var onMessage: ([String: JSONValue]) -> Void
    /// The token was rejected: reconnecting would not help.
    var onUnauthorized: () -> Void
    var onStateChange: (ConnectionState) -> Void
}

/// One WebSocket to the iAlert Gateway: authenticates with the device token,
/// answers pings, sends acks and reconnects with jittered exponential backoff.
final class GatewayConnection: WebSocketClientDelegate, @unchecked Sendable {
    private let url: URL
    private let deviceToken: String
    private let makeSocket: WebSocketFactory
    private let handlers: GatewayHandlers
    private let pingInterval: TimeInterval
    private let minReconnect: TimeInterval
    private let maxReconnect: TimeInterval

    private let lock = NSRecursiveLock()
    private var socket: WebSocketClient?
    private var stopped = true
    private var ready = false
    private var attempt = 0
    /// Bumped to cancel pending reconnect / ping timers.
    private var generation = 0
    private var pendingAcks: [(ids: [String], event: AckEvent)] = []

    init(url: URL, deviceToken: String, makeSocket: @escaping WebSocketFactory, handlers: GatewayHandlers, pingInterval: TimeInterval, minReconnect: TimeInterval, maxReconnect: TimeInterval) {
        self.url = url
        self.deviceToken = deviceToken
        self.makeSocket = makeSocket
        self.handlers = handlers
        self.pingInterval = pingInterval
        self.minReconnect = minReconnect
        self.maxReconnect = maxReconnect
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func start() {
        lock.lock()
        guard stopped else { lock.unlock(); return }
        stopped = false
        lock.unlock()
        open()
    }

    func stop() {
        lock.lock()
        stopped = true
        ready = false
        generation += 1
        let socket = self.socket
        self.socket = nil
        lock.unlock()
        socket?.close()
        handlers.onStateChange(.closed)
    }

    /// Sends an ack now, or once the socket is ready again.
    func ack(_ ids: [String], event: AckEvent) {
        lock.lock()
        defer { lock.unlock() }

        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start ..< min(start + 100, ids.count)])

            if !ready || !send(ackFrame(chunk, event)) {
                pendingAcks.append((chunk, event))
            }
        }
    }

    private func open() {
        handlers.onStateChange(.connecting)
        let socket = makeSocket(url)
        socket.delegate = self
        lock.lock()
        self.socket = socket
        lock.unlock()
        socket.connect()
    }

    // MARK: WebSocketClientDelegate

    func webSocketDidOpen(_ socket: WebSocketClient) {
        lock.lock()
        defer { lock.unlock() }
        guard socket === self.socket else { return }
        send(["type": "auth", "device_token": .string(deviceToken)])
    }

    func webSocket(_ socket: WebSocketClient, didReceive text: String) {
        lock.lock()
        guard socket === self.socket, let data = text.data(using: .utf8), let frame = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            lock.unlock()
            return
        }

        switch frame["type"]?.stringValue {
        case "ready":
            ready = true
            attempt = 0
            schedulePing(generation: generation)
            flushAcks()
            lock.unlock()
            handlers.onStateChange(.ready)
            handlers.onReady()
        case "message":
            lock.unlock()
            if let message = frame["message"]?.objectValue {
                handlers.onMessage(message)
            }
        case "ping":
            send(["type": "pong"])
            lock.unlock()
        case "error":
            let error = frame["error"]?.stringValue
            if error == "device_token_invalid" || error == "auth_required" {
                stopped = true
                generation += 1
                lock.unlock()
                handlers.onUnauthorized()
            } else {
                lock.unlock()
            }
        default:
            lock.unlock()
        }
    }

    func webSocketDidClose(_ socket: WebSocketClient) {
        lock.lock()
        guard socket === self.socket else { lock.unlock(); return }
        self.socket = nil
        ready = false
        generation += 1
        let reconnect = !stopped
        lock.unlock()

        if reconnect {
            scheduleReconnect()
        }
    }

    // MARK: Internals (call with the lock held where noted)

    /// Lock held.
    @discardableResult
    private func send(_ frame: [String: JSONValue]) -> Bool {
        guard let socket, socket.isOpen, let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else {
            return false
        }
        socket.send(text)
        return true
    }

    private func ackFrame(_ ids: [String], _ event: AckEvent) -> [String: JSONValue] {
        ["type": "ack", "ids": .array(ids.map(JSONValue.string)), "event": .string(event.rawValue)]
    }

    /// Lock held.
    private func flushAcks() {
        let pending = pendingAcks
        pendingAcks = []

        for chunk in pending where !send(ackFrame(chunk.ids, chunk.event)) {
            pendingAcks.append(chunk)
        }
    }

    /// Lock held.
    private func schedulePing(generation: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == generation, self.ready else { return }
            self.send(["type": "ping"])
            self.schedulePing(generation: generation)
        }
    }

    private func scheduleReconnect() {
        handlers.onStateChange(.connecting)
        lock.lock()
        let ceiling = min(maxReconnect, minReconnect * pow(2, Double(attempt)))
        let delay = ceiling / 2 + Double.random(in: 0 ... (ceiling / 2))
        attempt += 1
        let generation = self.generation
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldOpen = !self.stopped && self.generation == generation
            self.lock.unlock()
            if shouldOpen {
                self.open()
            }
        }
    }
}
