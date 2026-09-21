import Darwin
import Foundation

public struct TrashBin: Sendable, Identifiable {
    public let path: String
    /// Name of the volume, or nil for the home folder's Trash.
    public let volumeName: String?
    public let size: Int64
    public let items: [CleanupTarget]
    /// The Trash could not be read, usually for lack of Full Disk Access.
    public let isAccessDenied: Bool

    public var id: String { path }
}

public enum TrashBins {
    /// The user's Trash and the Trash on every mounted external volume.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [TrashBin] {
        var locations: [(path: String, volume: String?)] = [(
            home.appending(path: ".Trash").path(percentEncoded: false),
            nil
        )]
        for root in SafetyGuard.volumeTrashRoots() {
            let volume = root.split(separator: "/").dropFirst().first.map(String.init)
            locations.append((root, volume))
        }

        var bins: [TrashBin] = []
        for location in locations {
            var path = location.path
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            do {
                let root = try await DiskScanner().scan(URL(filePath: path)).root
                let items = root.directories.map { CleanupTarget(path: $0.path, size: $0.allocatedSize) }
                    + root.files.filter { $0.name != ".DS_Store" }
                    .map { CleanupTarget(path: root.path(of: $0), size: $0.allocatedSize) }
                bins.append(TrashBin(
                    path: path, volumeName: location.volume, size: root.allocatedSize,
                    items: items, isAccessDenied: root.status == .denied
                ))
            } catch {
                continue
            }
        }
        return bins
    }
}
