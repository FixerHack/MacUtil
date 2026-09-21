import Foundation
import Security
import Synchronization

/// Stores the VirusTotal API key in the login keychain, never in files.
public enum VirusTotalKey {
    private static let service = "com.fixerhack.MacUtil.virustotal"
    private static let account = "api-key"

    public static func load() -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a key is stored. Reads only the item's attributes, so unlike `load()`
    /// it never makes macOS ask for Keychain access.
    public static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "MacUtil VirusTotal API key",
            kSecValueData as String: Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Remembers lookups for a week so rescans do not spend the daily API quota.
public final class VirusTotalCache: Sendable {
    private struct Entry: Codable {
        let date: Date
        let lookup: VirusTotalLookup
    }

    public static let standard = VirusTotalCache(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacUtil/VirusTotalCache.json")
    )

    private let url: URL
    private let maxAge: TimeInterval
    private let entries: Mutex<[String: Entry]>

    public init(url: URL, maxAge: TimeInterval = 7 * 86400) {
        self.url = url
        self.maxAge = maxAge
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: Entry].self, from: $0) }
        entries = Mutex(stored ?? [:])
    }

    public func lookup(sha256: String, now: Date = Date()) -> VirusTotalLookup? {
        entries.withLock { entries in
            guard let entry = entries[sha256], now.timeIntervalSince(entry.date) < maxAge else { return nil }
            return entry.lookup
        }
    }

    public func store(_ lookup: VirusTotalLookup, sha256: String, now: Date = Date()) {
        let snapshot = entries.withLock { entries in
            entries[sha256] = Entry(date: now, lookup: lookup)
            return entries
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
