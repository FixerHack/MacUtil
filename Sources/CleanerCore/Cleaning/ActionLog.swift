import Foundation
import Synchronization

/// Append-only history of everything MacCleaner removed or restored,
/// one JSON object per line.
public final class ActionLog: Sendable {
    public struct Entry: Codable, Sendable {
        public let date: Date
        /// "trash", "delete" or "restore".
        public let action: String
        /// What triggered it, for example a module or rule id.
        public let source: String
        public let freedBytes: Int64
        public let removed: [RemovedItem]
        public let failures: [CleanupFailure]

        public init(action: String, source: String, result: CleanupResult, date: Date = Date()) {
            self.date = date
            self.action = action
            self.source = source
            freedBytes = result.freedBytes
            removed = result.removed
            failures = result.failures
        }
    }

    public static let standard = ActionLog(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacCleaner/History.jsonl")
    )

    public let url: URL
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    public func record(_ entry: Entry) {
        guard !entry.removed.isEmpty || !entry.failures.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)

        lock.withLock { _ in
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    public func entries() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = lock.withLock({ _ in try? Data(contentsOf: url) }) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }
}
