import Foundation

/// Sends one HTTP request; `URLSession` implements it. Inject a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        return (data, http)
    }
}

struct InboxEntry: Decodable {
    struct Content: Decodable {
        let title: String?
        let body: String?
        let image: String?
        let url: String?
        let data: JSONValue?
        let sound: String?
    }

    let id: String
    let content: Content
    let collapseId: String?
    /// APNs/FCM/Web Push already took it, so the system showed it.
    let pushed: Bool?
    let deliveredAt: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, content, pushed
        case collapseId = "collapse_id"
        case deliveredAt = "delivered_at"
        case createdAt = "created_at"
    }
}

/// Thin REST client for the public-key endpoints of API v1.
struct ApiClient: Sendable {
    let baseURL: String
    let publicKey: String
    let transport: HTTPTransport

    private struct Wrapped<T: Decodable>: Decodable { let data: T }
    private struct Registered: Decodable {
        let data: Device
        let deviceToken: String
        enum CodingKeys: String, CodingKey { case data, deviceToken = "device_token" }
    }
    private struct InboxPage: Decodable {
        struct Links: Decodable { let next: String? }
        let data: [InboxEntry]
        let links: Links?
    }
    private struct Acknowledged: Decodable { let acknowledged: Int }
    private struct ErrorBody: Decodable {
        let message: String?
        let code: String?
        let errors: [String: [String]]?
    }

    init(baseURL: String, publicKey: String, transport: HTTPTransport) {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.publicKey = publicKey
        self.transport = transport
    }

    func register(_ body: [String: JSONValue]) async throws -> (Device, String) {
        let result: Registered = try await request("POST", "/devices", body: body)
        return (result.data, result.deviceToken)
    }

    func update(deviceId: String, deviceToken: String, _ body: [String: JSONValue]) async throws -> Device {
        let result: Wrapped<Device> = try await request("PATCH", "/devices/\(escape(deviceId))", body: body, deviceToken: deviceToken)
        return result.data
    }

    func unsubscribe(deviceId: String, deviceToken: String) async throws -> Device {
        let result: Wrapped<Device> = try await request("POST", "/devices/\(escape(deviceId))/unsubscribe", deviceToken: deviceToken)
        return result.data
    }

    /// Every unread Inbox page (newest first), following `links.next`, up to `maxPages`.
    func inbox(deviceId: String, deviceToken: String, maxPages: Int = 5) async throws -> [InboxEntry] {
        var entries: [InboxEntry] = []
        var next: String? = "\(baseURL)/devices/\(escape(deviceId))/inbox?per_page=100&unread=1"
        var page = 0

        while let url = next, page < maxPages {
            let result: InboxPage = try await request("GET", url, deviceToken: deviceToken)
            entries += result.data
            next = result.links?.next
            page += 1
        }

        return entries
    }

    func ack(deviceId: String, deviceToken: String, ids: [String], event: AckEvent) async throws {
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start ..< min(start + 100, ids.count)])
            let _: Acknowledged = try await request(
                "POST",
                "/devices/\(escape(deviceId))/inbox/ack",
                body: ["ids": .array(chunk.map(JSONValue.string)), "event": .string(event.rawValue)],
                deviceToken: deviceToken
            )
        }
    }

    /// Approve or deny an Auth Push request; returns its recorded status.
    func respondToAuthRequest(deviceId: String, deviceToken: String, requestId: String, approve: Bool, code: String?) async throws -> String {
        var body: [String: JSONValue] = ["decision": .string(approve ? "approve" : "deny")]
        if let code { body["code"] = .string(code) }
        let result: Wrapped<[String: JSONValue]> = try await request("POST", "/devices/\(escape(deviceId))/auth-requests/\(escape(requestId))", body: body, deviceToken: deviceToken)
        return result.data["status"]?.stringValue ?? "pending"
    }

    private func request<T: Decodable>(_ method: String, _ pathOrURL: String, body: [String: JSONValue]? = nil, deviceToken: String? = nil) async throws -> T {
        guard let url = URL(string: pathOrURL.hasPrefix("http") ? pathOrURL : baseURL + pathOrURL) else {
            throw IAlertError(status: 0, code: "network_error", message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(publicKey)", forHTTPHeaderField: "Authorization")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        if let deviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        }

        let data: Data
        let response: HTTPURLResponse

        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw IAlertError(status: 0, code: "network_error", message: error.localizedDescription)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            let payload = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw IAlertError(
                status: response.statusCode,
                code: payload?.code ?? "server_error",
                message: payload?.message ?? "HTTP \(response.statusCode)",
                errors: payload?.errors
            )
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IAlertError(status: response.statusCode, code: "invalid_response", message: error.localizedDescription)
        }
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
