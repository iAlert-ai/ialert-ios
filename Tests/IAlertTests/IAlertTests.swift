import Foundation
@testable import IAlert
import XCTest

// MARK: Doubles

struct RecordedRequest {
    let method: String
    let url: String
    let headers: [String: String]
    let body: [String: JSONValue]?
}

/// HTTP double that records requests and answers from a list of responders.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Responder = (RecordedRequest) -> (Int, Any)?

    private let lock = NSLock()
    private let responders: [Responder]
    private var recorded: [RecordedRequest] = []

    init(_ responders: Responder...) {
        self.responders = responders
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ request: RecordedRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody.flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) }
        )
        record(recordedRequest)

        let (status, body) = responders.lazy.compactMap { $0(recordedRequest) }.first ?? (404, ["message": "Not found", "code": "not_found"])
        let data = try JSONSerialization.data(withJSONObject: body)

        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let registerResponder: FakeTransport.Responder = { request in
    request.method == "POST" && request.url.hasSuffix("/devices")
        ? (201, ["data": ["id": "dev_1", "platform": "ios", "tags": [:]], "device_token": "ia_dt_dev_1.sig"])
        : nil
}

func inboxResponder(_ entries: [[String: Any]]) -> FakeTransport.Responder {
    { request in
        request.method == "GET" && request.url.contains("/inbox") ? (200, ["data": entries, "links": ["next": NSNull()]]) : nil
    }
}

let ackResponder: FakeTransport.Responder = { request in
    request.url.hasSuffix("/inbox/ack") ? (200, ["acknowledged": 1]) : nil
}

func inboxEntry(_ id: String, deliveredAt: String? = nil) -> [String: Any] {
    [
        "id": id,
        "content": ["title": "title \(id)", "body": "body", "image": NSNull(), "data": ["order": 1]],
        "collapse_id": NSNull(),
        "delivered_at": deliveredAt ?? NSNull(),
        "read_at": NSNull(),
        "clicked_at": NSNull(),
        "created_at": "2026-11-09T08:00:00+00:00",
    ]
}

/// WebSocket double driven by the test.
final class FakeSocket: WebSocketClient, @unchecked Sendable {
    weak var delegate: WebSocketClientDelegate?
    let url: URL
    private let lock = NSLock()
    private var open = false
    private var frames: [[String: JSONValue]] = []

    init(url: URL) {
        self.url = url
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    var sent: [[String: JSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func connect() {}

    func send(_ text: String) {
        lock.lock()
        frames.append(try! JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)))
        lock.unlock()
    }

    func close() {
        serverDrop()
    }

    func serverOpen() {
        lock.lock()
        open = true
        lock.unlock()
        delegate?.webSocketDidOpen(self)
    }

    func serverSend(_ frame: [String: Any]) {
        let text = String(data: try! JSONSerialization.data(withJSONObject: frame), encoding: .utf8)!
        delegate?.webSocket(self, didReceive: text)
    }

    func serverDrop() {
        lock.lock()
        open = false
        lock.unlock()
        delegate?.webSocketDidClose(self)
    }
}

final class SocketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FakeSocket] = []

    var sockets: [FakeSocket] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    lazy var factory: WebSocketFactory = { [unowned self] url in
        let socket = FakeSocket(url: url)
        self.lock.lock()
        self.all.append(socket)
        self.lock.unlock()
        return socket
    }
}

final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [T] = []

    var items: [T] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    func append(_ item: T) {
        lock.lock()
        all.append(item)
        lock.unlock()
    }
}

func eventually(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)

    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met in time", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: Tests

final class IAlertTests: XCTestCase {
    let publicKey = "ia_pk_live_abcdefghijkl_secret"

    func sdk(_ transport: FakeTransport, storage: KeyValueStorage = MemoryStorage(), sockets: SocketRecorder = SocketRecorder(), autoConnect: Bool = true) throws -> IAlert {
        var configuration = IAlert.Configuration(publicKey: publicKey)
        configuration.apiURL = "https://api.test/api/v1"
        configuration.gatewayURL = URL(string: "wss://gw.test/v1/connect")!
        configuration.transport = transport
        configuration.storage = storage
        configuration.webSocketFactory = sockets.factory
        configuration.autoConnect = autoConnect
        configuration.minReconnectDelay = 0.01
        configuration.maxReconnectDelay = 0.02
        return try IAlert(configuration: configuration)
    }

    func testRefusesSecretKeys() {
        XCTAssertThrowsError(try IAlert(publicKey: "ia_sk_live_x")) { error in
            XCTAssertEqual((error as? IAlertError)?.code, "invalid_public_key")
        }
    }

    func testRegistersAsIosWithStableInstallationIdAndPublicKey() async throws {
        let transport = FakeTransport(registerResponder)
        let storage = MemoryStorage()

        try await sdk(transport, storage: storage, autoConnect: false).register(fields: DeviceFields(externalUserId: "user-42", tags: ["plan": "gold"]))
        try await sdk(transport, storage: storage, autoConnect: false).register()

        let first = transport.requests[0]
        let body = try XCTUnwrap(first.body)
        XCTAssertEqual(first.headers["Authorization"], "Bearer \(publicKey)")
        XCTAssertEqual(body["platform"], "ios")
        XCTAssertTrue(body["push_token"]?.stringValue?.hasPrefix("ia_ios_") == true)
        XCTAssertEqual(body["external_user_id"], "user-42")
        XCTAssertEqual(body["tags"], .object(["plan": "gold"]))
        XCTAssertEqual(body["sdk_version"], "0.5.1")
        XCTAssertEqual(transport.requests[1].body?["push_token"], body["push_token"])
    }

    func testSendsTheApnsTokenAndKeepsTheRegistrationAcrossRestarts() async throws {
        let transport = FakeTransport(registerResponder)
        let storage = MemoryStorage()

        try await sdk(transport, storage: storage, autoConnect: false).register(pushToken: "apns-hex-token")

        XCTAssertEqual(transport.requests[0].body?["push_token"], "apns-hex-token")
        XCTAssertEqual(try sdk(transport, storage: storage, autoConnect: false).deviceId, "dev_1")
    }

    func testRejectsInvalidTagKeysBeforeCallingTheApi() async throws {
        let transport = FakeTransport(registerResponder)

        do {
            try await sdk(transport).register(fields: DeviceFields(tags: ["bad key": 1]))
            XCTFail("expected an error")
        } catch let error as IAlertError {
            XCTAssertEqual(error.code, "invalid_tag_key")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUpdatesItsOwnDeviceWithTheDeviceToken() async throws {
        let transport = FakeTransport(registerResponder) { request in
            request.method == "PATCH" ? (200, ["data": ["id": "dev_1", "tags": ["plan": "gold"]]]) : nil
        }
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register()

        try await ialert.setTags(["plan": "gold", "old": nil])

        let patch = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(patch.url, "https://api.test/api/v1/devices/dev_1")
        XCTAssertEqual(patch.headers["X-Device-Token"], "ia_dt_dev_1.sig")
        XCTAssertEqual(patch.body, ["tags": .object(["plan": "gold", "old": .null])])
    }

    func testForgetsTheRegistrationWhenTheDeviceTokenIsRejected() async throws {
        let transport = FakeTransport(registerResponder) { request in
            request.method == "PATCH" ? (403, ["message": "Invalid", "code": "device_token_invalid"]) : nil
        }
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register()

        do {
            try await ialert.setExternalUserId("u")
            XCTFail("expected an error")
        } catch let error as IAlertError {
            XCTAssertEqual(error.status, 403)
            XCTAssertEqual(error.code, "device_token_invalid")
        }
        XCTAssertNil(ialert.deviceId)
    }

    func testGatewayAuthenticatesAnswersPingsAndDeliversEachMessageOnceWithAnAck() async throws {
        let transport = FakeTransport(registerResponder, inboxResponder([]), ackResponder)
        let sockets = SocketRecorder()
        let ialert = try sdk(transport, sockets: sockets)
        let received = Collector<IAlertMessage>()
        ialert.onMessage { received.append($0) }
        try await ialert.register()

        let socket = try XCTUnwrap(sockets.sockets.first)
        XCTAssertEqual(socket.url.absoluteString, "wss://gw.test/v1/connect")
        socket.serverOpen()
        XCTAssertEqual(socket.sent.first, ["type": "auth", "device_token": "ia_dt_dev_1.sig"])

        socket.serverSend(["type": "ready"])
        socket.serverSend(["type": "ping"])
        let message: [String: Any] = ["id": "n_1", "title": "Hi", "body": "There", "image": NSNull(), "data": ["a": 1], "collapse_id": NSNull(), "created_at": NSNull()]
        socket.serverSend(["type": "message", "message": message])
        socket.serverSend(["type": "message", "message": message])

        await eventually { socket.sent.count >= 3 }
        XCTAssertEqual(received.items.count, 1)
        XCTAssertEqual(received.items.first?.source, .gateway)
        XCTAssertEqual(received.items.first?.data, ["a": 1])
        XCTAssertEqual(Array(socket.sent.dropFirst()), [["type": "pong"], ["type": "ack", "ids": .array(["n_1"]), "event": "delivered"]])
        ialert.disconnect()
    }

    func testSyncsMissedInboxMessagesAfterReadyOldestFirstAndAcksTheUndelivered() async throws {
        let transport = FakeTransport(registerResponder, inboxResponder([inboxEntry("n_new"), inboxEntry("n_old", deliveredAt: "2026-11-09T08:00:00+00:00")]), ackResponder)
        let sockets = SocketRecorder()
        let ialert = try sdk(transport, sockets: sockets)
        let received = Collector<String>()
        ialert.onMessage { received.append("\($0.source.rawValue):\($0.id)") }
        try await ialert.register()

        let socket = try XCTUnwrap(sockets.sockets.first)
        socket.serverOpen()
        socket.serverSend(["type": "ready"])

        await eventually { socket.sent.count >= 2 }
        XCTAssertTrue(transport.requests.contains { $0.url.contains("/inbox") && $0.url.contains("unread=1") })
        XCTAssertEqual(received.items, ["inbox:n_old", "inbox:n_new"])
        XCTAssertEqual(socket.sent.last, ["type": "ack", "ids": .array(["n_new"]), "event": "delivered"])
        ialert.disconnect()
    }

    func testCarriesTheNotificationSoundFromTheInbox() async throws {
        var entry = inboxEntry("n_1")
        entry["content"] = ["title": "t", "body": "b", "image": NSNull(), "data": [:], "sound": "order.caf"]
        let transport = FakeTransport(registerResponder, inboxResponder([entry, inboxEntry("n_2")]), ackResponder)
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register()

        let messages = try await ialert.syncInbox()

        XCTAssertEqual(messages.map(\.sound), [nil, "order.caf"])
    }

    func testDoesNotShowAMessageAgainAfterARestart() async throws {
        let storage = MemoryStorage()
        let transport = FakeTransport(registerResponder, inboxResponder([inboxEntry("n_1")]), ackResponder)
        let first = try sdk(transport, storage: storage, autoConnect: false)
        try await first.register()
        let firstSync = try await first.syncInbox()
        XCTAssertEqual(firstSync.count, 1)

        let secondSync = try await sdk(transport, storage: storage, autoConnect: false).syncInbox()
        XCTAssertEqual(secondSync.count, 0)
    }

    func testAcksOverHttpWhenTheSocketIsNotReady() async throws {
        let transport = FakeTransport(registerResponder, ackResponder)
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register()

        try await ialert.ack(["n_1"], event: .clicked)

        XCTAssertEqual(transport.requests.last?.body, ["ids": .array(["n_1"]), "event": "clicked"])
        XCTAssertEqual(transport.requests.last?.headers["X-Device-Token"], "ia_dt_dev_1.sig")
    }

    func testReconnectsAfterADropButStopsWhenTheTokenIsInvalid() async throws {
        let transport = FakeTransport(registerResponder, inboxResponder([]), ackResponder)
        let sockets = SocketRecorder()
        let ialert = try sdk(transport, sockets: sockets)
        let states = Collector<ConnectionState>()
        ialert.onConnectionStateChange { states.append($0) }
        try await ialert.register()

        sockets.sockets[0].serverDrop()
        await eventually { sockets.sockets.count == 2 }

        let second = sockets.sockets[1]
        second.serverOpen()
        second.serverSend(["type": "error", "error": "device_token_invalid"])
        second.serverDrop()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sockets.sockets.count, 2)
        XCTAssertNil(ialert.deviceId)
        XCTAssertEqual(states.items.last, .closed)
    }

    func testMessagesAreAvailableAsAnAsyncStream() async throws {
        let transport = FakeTransport(registerResponder, inboxResponder([inboxEntry("n_1")]), ackResponder)
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register()
        let stream = ialert.messages()

        try await ialert.syncInbox()

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.id, "n_1")
    }

    // MARK: Native push

    func testAuthPushAnswersWithTheDeviceTokenAndKeepsTheRegistration() async throws {
        let transport = FakeTransport(registerResponder, { request in
            request.url.hasSuffix("/auth-requests/01AUTH") ? (200, ["data": ["id": "01AUTH", "status": "approved"]]) : nil
        })
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register(pushToken: "0aff0120")

        let status = try await ialert.respondToAuthRequest("01AUTH", approve: true, code: "47")
        XCTAssertEqual(status, "approved")
        let call = transport.requests.first { $0.url.contains("/auth-requests/") }
        XCTAssertEqual(call?.url, "https://api.test/api/v1/devices/dev_1/auth-requests/01AUTH")
        XCTAssertEqual(call?.headers["X-Device-Token"], "ia_dt_dev_1.sig")
        XCTAssertEqual(call?.body?["code"], .string("47"))

        do {
            try await ialert.respondToAuthRequest("missing", approve: false)
            XCTFail("expected a 404")
        } catch let error as IAlertError {
            XCTAssertEqual(error.status, 404)
        }
        XCTAssertEqual(ialert.deviceId, "dev_1")

        let message = IAlertMessage(id: "n1", title: nil, body: nil, image: nil, data: ["ialert_type": .string("auth_request"), "auth_request_id": .string("01AUTH"), "number_matching": .string("1"), "ip": .string("5.160.1.2")], collapseId: nil, createdAt: nil, source: .push)
        let info = AuthRequestInfo(message: message)
        XCTAssertEqual(info?.id, "01AUTH")
        XCTAssertEqual(info?.numberMatching, true)
        XCTAssertEqual(info?.context, ["ip": "5.160.1.2"])
    }

    func testApnsTokenIsRegisteredAsHex() async throws {
        let transport = FakeTransport(registerResponder)
        let ialert = try sdk(transport, autoConnect: false)

        try await ialert.setAPNsToken(Data([0x0a, 0xff, 0x01, 0x20]))

        XCTAssertEqual(IAlert.apnsTokenString(Data([0x00, 0xab])), "00ab")
        XCTAssertEqual(transport.requests.first?.body?["push_token"], .string("0aff0120"))
        XCTAssertEqual(transport.requests.first?.body?["platform"], .string("ios"))
    }

    func testPushesAreDeliveredOnceAndTapsAreAckedAsClicked() async throws {
        let transport = FakeTransport(registerResponder, ackResponder)
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register(pushToken: "0aff0120")
        var received: [IAlertMessage] = []
        ialert.onMessage { received.append($0) }

        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Goal", "body": "2 - 1"], "mutable-content": 1],
            "ialert": ["id": "01NOTIF", "image": "https://cdn.test/a.jpg", "data": ["match": 7]],
        ]

        XCTAssertEqual(ialert.didReceiveRemoteNotification(userInfo)?.source, .push)
        XCTAssertNil(ialert.didReceiveRemoteNotification(userInfo))
        XCTAssertNil(ialert.didReceiveRemoteNotification(["aps": ["alert": "not ours"]]))
        await ialert.didOpenNotification(userInfo)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.title, "Goal")
        XCTAssertEqual(received.first?.image, "https://cdn.test/a.jpg")
        XCTAssertEqual(received.first?.data["match"], .number(7))

        await eventually { transport.requests.filter { $0.url.hasSuffix("/inbox/ack") }.count == 2 }
        let events = transport.requests.filter { $0.url.hasSuffix("/inbox/ack") }.compactMap { $0.body?["event"]?.stringValue }
        XCTAssertEqual(Set(events), ["delivered", "clicked"])
    }

    func testBackgroundSyncShowsOnlyUndeliveredMessagesNotAlreadyOnScreen() async throws {
        let transport = FakeTransport(registerResponder, ackResponder, inboxResponder([
            inboxEntry("n_new"),
            inboxEntry("n_shown_by_apns"),
            inboxEntry("n_old", deliveredAt: "2026-11-09T08:00:00+00:00"),
        ]))
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register(pushToken: "0aff0120")
        let notifier = FakeNotifier(delivered: ["n_shown_by_apns"])

        let shown = try await ialert.backgroundSync(notifier: notifier)

        XCTAssertEqual(shown, 1)
        XCTAssertEqual(notifier.shown.map(\.id), ["n_new"])
        let acked = transport.requests.first { $0.url.hasSuffix("/inbox/ack") }?.body?["ids"]
        XCTAssertEqual(acked, .array([.string("n_new"), .string("n_shown_by_apns")]))

        let again = try await ialert.backgroundSync(notifier: FakeNotifier(delivered: []))
        XCTAssertEqual(again, 0, "already seen messages are not shown again")
    }

    func testBackgroundSyncLeavesPushedEntriesUnacknowledged() async throws {
        var pushed = inboxEntry("n_pushed")
        pushed["pushed"] = true
        let transport = FakeTransport(registerResponder, ackResponder, inboxResponder([inboxEntry("n_new"), pushed]))
        let ialert = try sdk(transport, autoConnect: false)
        try await ialert.register(pushToken: "0aff0120")
        let notifier = FakeNotifier(delivered: [])

        let shown = try await ialert.backgroundSync(notifier: notifier)

        XCTAssertEqual(shown, 1)
        XCTAssertEqual(notifier.shown.map(\.id), ["n_new"])
        let acked = transport.requests.first { $0.url.hasSuffix("/inbox/ack") }?.body?["ids"]
        XCTAssertEqual(acked, .array([.string("n_new")]))
    }
}

final class FakeNotifier: LocalNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private let delivered: Set<String>
    private var recorded: [IAlertMessage] = []

    init(delivered: Set<String>) {
        self.delivered = delivered
    }

    var shown: [IAlertMessage] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func deliveredNotificationIds() async -> Set<String> { delivered }

    func show(_ message: IAlertMessage) async throws {
        lock.lock()
        recorded.append(message)
        lock.unlock()
    }
}

