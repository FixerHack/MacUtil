import Foundation

/// One contributor to what macOS files under "System Data".
public struct SystemDataItem: Sendable, Identifiable, Hashable {
    public let name: String
    public let path: String
    public let size: Int64
    /// Where it lives, in words: application support, containers, caches.
    public let place: String

    public var id: String { path }
}

/// Explains the storage figure macOS shows as "System Data".
///
/// Most of it is not the system at all: it is what apps keep in your Library. Steam's games,
/// Docker's disk image and a browser's caches all land in that number, which is why it looks
/// unexplainable in System Settings.
public enum SystemDataBreakdown {
    static let roots: [(place: String, path: String)] = [
        (String(localized: "App data"), "Library/Application Support"),
        (String(localized: "Containers"), "Library/Containers"),
        (String(localized: "Group containers"), "Library/Group Containers"),
        (String(localized: "Caches"), "Library/Caches"),
    ]

    /// The biggest things in those places, largest first.
    public static func scan(limit: Int = 12, atLeast: Int64 = 100_000_000) async -> [SystemDataItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [SystemDataItem] = []
        for root in roots {
            let directory = home.appending(path: root.path).path
            guard FileManager.default.fileExists(atPath: directory) else { continue }
            items += await children(of: directory, place: root.place)
        }
        return items
            .filter { $0.size >= atLeast }
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    /// `du` walks a folder far faster than Foundation can, and it is already on every Mac.
    static func children(of directory: String, place: String) async -> [SystemDataItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        guard !names.isEmpty else { return [] }

        let paths = names.map { "\(directory)/\($0)" }
        guard let sizes = await Command.run("/usr/bin/du", ["-sk"] + paths, timeout: .seconds(300)) else { return [] }
        return parse(sizes.text, place: place)
    }

    static func parse(_ output: String, place: String) -> [SystemDataItem] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kilobytes = Int64(parts[0].trimmingCharacters(in: .whitespaces))
            else { return nil }
            let path = String(parts[1])
            return SystemDataItem(
                name: (path as NSString).lastPathComponent, path: path,
                size: kilobytes * 1024, place: place
            )
        }
    }
}
