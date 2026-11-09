import Foundation

/// Key/value storage for the registration and dedupe ids. `UserDefaults` is the default.
public protocol KeyValueStorage: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults`-backed storage (pass a suite for an App Group).
public final class UserDefaultsStorage: KeyValueStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// In-memory storage for tests.
public final class MemoryStorage: KeyValueStorage, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[key]
    }

    public func set(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        items[key] = value
    }
}

/// Namespaced JSON helpers over a KeyValueStorage.
struct Store {
    let storage: KeyValueStorage
    let prefix: String

    init(storage: KeyValueStorage, namespace: String) {
        self.storage = storage
        prefix = "ialert:\(namespace):"
    }

    func get<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let raw = storage.string(forKey: prefix + key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func set<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            storage.set(nil, forKey: prefix + key)
            return
        }
        storage.set(String(data: data, encoding: .utf8), forKey: prefix + key)
    }
}
