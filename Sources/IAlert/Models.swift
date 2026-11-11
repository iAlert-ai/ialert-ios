import Foundation

/// Any JSON value (notification `data`, tag values, device fields).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

/// Device as returned by the iAlert API (the push token itself is never returned).
public struct Device: Decodable, Equatable, Sendable {
    public let id: String
    public let platform: String?
    public let externalUserId: String?
    public let tags: [String: JSONValue]?
    public let locale: String?
    public let timezone: String?
    public let appVersion: String?
    public let sdkVersion: String?
    public let subscribed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, platform, tags, locale, timezone, subscribed
        case externalUserId = "external_user_id"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
    }
}

/// A notification from the Gateway or the Inbox; `id` is the notification id.
public struct IAlertMessage: Equatable, Sendable {
    public enum Source: String, Sendable { case gateway, inbox, push }

    public let id: String
    public let title: String?
    public let body: String?
    public let image: String?
    public let data: [String: JSONValue]
    public let collapseId: String?
    public let createdAt: String?
    /// Where the SDK got it first.
    public let source: Source
}

public enum AckEvent: String, Sendable { case delivered, read, clicked }

public enum ConnectionState: String, Sendable { case idle, connecting, ready, closed }

/// Fields for `register` / `update`. `nil` leaves a field unchanged; a tag set to `.null` is removed.
public struct DeviceFields: Sendable {
    public var externalUserId: JSONValue?
    public var tags: [String: JSONValue]?
    public var locale: String?
    public var timezone: String?
    public var appVersion: String?

    public init(externalUserId: String?? = nil, tags: [String: JSONValue]? = nil, locale: String? = nil, timezone: String? = nil, appVersion: String? = nil) {
        self.externalUserId = externalUserId.map { $0.map(JSONValue.string) ?? .null }
        self.tags = tags
        self.locale = locale
        self.timezone = timezone
        self.appVersion = appVersion
    }
}

/// Error from the iAlert API (`{ message, code, errors? }`) or from local validation (status 0).
public struct IAlertError: Error, Equatable, Sendable, LocalizedError {
    public let status: Int
    public let code: String
    public let message: String
    public let errors: [String: [String]]?

    public init(status: Int, code: String, message: String, errors: [String: [String]]? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.errors = errors
    }

    public var errorDescription: String? { message }
}
