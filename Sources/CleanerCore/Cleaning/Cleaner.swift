import Foundation

public enum CleanupMode: String, Codable, Sendable {
    /// Move to the Trash; can be undone until the Trash is emptied.
    case trash
    /// Delete immediately; frees space at once and cannot be undone.
    case delete
}

public struct CleanupTarget: Sendable, Hashable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}

public struct RemovedItem: Codable, Sendable, Hashable {
    public let path: String
    public let size: Int64
    /// Where the item ended up in the Trash, for undo.
    public let trashPath: String?
}

public struct CleanupFailure: Codable, Sendable, Hashable {
    public let path: String
    public let reason: String
}

public struct CleanupResult: Sendable {
    public let mode: CleanupMode
    public var removed: [RemovedItem] = []
    public var failures: [CleanupFailure] = []

    public var freedBytes: Int64 {
        removed.reduce(0) { $0 + $1.size }
    }

    public var canUndo: Bool {
        mode == .trash && removed.contains { $0.trashPath != nil }
    }
}

/// Moves items to a trash. Abstracted so tests never touch the real Trash.
public protocol TrashDestination: Sendable {
    /// Returns the item's new location.
    func trash(_ url: URL) throws -> URL?
}

public struct SystemTrash: TrashDestination {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

/// Removes files after the `SafetyGuard` approves each one, and records every
/// action in the `ActionLog`.
public struct Cleaner: Sendable {
    public let safety: SafetyGuard
    public let trash: any TrashDestination
    public let log: ActionLog?

    public init(
        safety: SafetyGuard = SafetyGuard(),
        trash: any TrashDestination = SystemTrash(),
        log: ActionLog? = .standard
    ) {
        self.safety = safety
        self.trash = trash
        self.log = log
    }

    public func clean(_ targets: [CleanupTarget], mode: CleanupMode, source: String) async -> CleanupResult {
        let result = await Task.detached(priority: .userInitiated) { [self] in
            var result = CleanupResult(mode: mode)
            // Check safety first: a blocked outer folder must not hide allowed items inside it.
            var allowed: [CleanupTarget] = []
            for target in targets {
                if case let .blocked(reason) = safety.check(target.path) {
                    result.failures.append(CleanupFailure(path: target.path, reason: "Blocked: \(reason)"))
                } else {
                    allowed.append(target)
                }
            }
            for target in Self.removingNested(allowed) {
                let url = URL(filePath: target.path)
                do {
                    switch mode {
                    case .trash:
                        let trashed = try trash.trash(url)
                        result.removed.append(RemovedItem(
                            path: target.path, size: target.size, trashPath: trashed?.path(percentEncoded: false)
                        ))
                    case .delete:
                        try FileManager.default.removeItem(at: url)
                        result.removed.append(RemovedItem(path: target.path, size: target.size, trashPath: nil))
                    }
                } catch {
                    result.failures.append(CleanupFailure(path: target.path, reason: Self.describe(error)))
                }
            }
            return result
        }.value
        log?.record(ActionLog.Entry(action: mode == .trash ? "trash" : "delete", source: source, result: result))
        return result
    }

    /// Moves trashed items back to where they were.
    public func undo(_ cleanup: CleanupResult) async -> CleanupResult {
        let result = await Task.detached(priority: .userInitiated) {
            var result = CleanupResult(mode: .trash)
            let fileManager = FileManager.default
            for item in cleanup.removed {
                guard let trashPath = item.trashPath else { continue }
                do {
                    let destination = URL(filePath: item.path)
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: URL(filePath: trashPath), to: destination)
                    result.removed.append(RemovedItem(path: item.path, size: item.size, trashPath: nil))
                } catch {
                    result.failures.append(CleanupFailure(path: item.path, reason: Self.describe(error)))
                }
            }
            return result
        }.value
        log?.record(ActionLog.Entry(action: "restore", source: "undo", result: result))
        return result
    }

    /// Drops targets that live inside another target; the outer one covers them.
    static func removingNested(_ targets: [CleanupTarget]) -> [CleanupTarget] {
        // Shortest paths first, so every possible ancestor is already known.
        let sorted = Set(targets).sorted { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        var kept = Set<String>()
        var result: [CleanupTarget] = []
        for target in sorted {
            var ancestor = (target.path as NSString).deletingLastPathComponent
            var isNested = false
            while ancestor.count > 1 {
                if kept.contains(ancestor) {
                    isNested = true
                    break
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            if !isNested {
                kept.insert(target.path)
                result.append(target)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.localizedDescription
        }
        return nsError.localizedDescription
    }
}
