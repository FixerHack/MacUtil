import Foundation

/// A file that is in iCloud and also still taking up room on this Mac.
public struct CloudFile: Sendable, Identifiable, Hashable {
    public let path: String
    public let size: Int64
    /// When it was last opened, which is what decides whether keeping it is worth the space.
    public let lastUsed: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

/// Finds files that iCloud already holds, which are only here for speed.
///
/// With Optimise Mac Storage on, macOS does this by itself when the disk fills up, but only
/// then and only by its own reckoning. Asking for it directly frees the space now, and
/// nothing is lost: the file keeps its place in the Finder and comes back when opened.
public enum CloudFiles {
    public static var drive: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
            .path(percentEncoded: false)
    }

    public static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: drive)
    }

    /// Downloaded files in iCloud Drive, biggest first.
    ///
    /// Only what is fully downloaded counts: a file already kept in the cloud alone takes no
    /// space to free, and one still downloading must not be interrupted.
    public static func downloaded(
        in folder: String? = nil, atLeast: Int64 = 1_000_000, limit: Int = 500
    ) async -> [CloudFile] {
        let root = folder ?? drive
        guard FileManager.default.fileExists(atPath: root) else { return [] }

        return await Task.detached {
            let keys: [URLResourceKey] = [
                .isRegularFileKey, .totalFileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey,
                .contentAccessDateKey, .isUbiquitousItemKey,
            ]
            guard let walker = FileManager.default.enumerator(
                at: URL(filePath: root), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { return [] }

            var found: [CloudFile] = []
            for case let url as URL in walker.allObjects {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isUbiquitousItem == true,
                      values.ubiquitousItemDownloadingStatus == .current,
                      let size = values.totalFileAllocatedSize, Int64(size) >= atLeast
                else { continue }
                found.append(CloudFile(
                    path: url.path(percentEncoded: false),
                    size: Int64(size),
                    lastUsed: values.contentAccessDate
                ))
                if found.count >= limit * 4 { break }
            }
            return Array(found.sorted { $0.size > $1.size }.prefix(limit))
        }.value
    }

    /// Asks iCloud to keep these in the cloud only, freeing what they take here.
    ///
    /// The file stays visible and downloads again when opened, so this removes nothing.
    public static func evict(_ files: [CloudFile]) async -> (freed: Int64, failures: [CleanupFailure]) {
        var freed: Int64 = 0
        var failures: [CleanupFailure] = []
        for file in files {
            do {
                try FileManager.default.evictUbiquitousItem(at: URL(filePath: file.path))
                freed += file.size
            } catch {
                failures.append(CleanupFailure(
                    path: file.path, reason: (error as NSError).localizedDescription
                ))
            }
        }
        return (freed, failures)
    }
}
