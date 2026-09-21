import Darwin
import Foundation

/// A file inside a scanned directory. Only the name is stored; the full path
/// comes from the parent `DirectoryNode`, which keeps memory low on big disks.
public struct FileEntry: Sendable, Hashable {
    public enum EntryType: UInt8, Sendable {
        case regular, symlink, other
    }

    public let name: String
    public let type: EntryType
    /// Space the file occupies on disk. Zero for extra hard links to an already
    /// counted file and for iCloud files that are not downloaded.
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let modificationTime: Int64
    public let accessTime: Int64
    public let flags: UInt32

    public var isHidden: Bool {
        name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
    }

    /// Cloud file whose contents are not on this Mac.
    public var isDataless: Bool {
        flags & UInt32(SF_DATALESS) != 0
    }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modificationTime))
    }

    public var accessDate: Date {
        Date(timeIntervalSince1970: TimeInterval(accessTime))
    }

    public var kind: FileKind {
        FileKind(fileName: name)
    }
}

/// A scanned directory with its files and subdirectories.
///
/// Thread safety: during a scan each node is filled by exactly one worker and
/// published through the scanner's locked work queue; after `scan` returns the
/// tree must only be touched from one thread at a time (the main actor in the app).
public final class DirectoryNode: @unchecked Sendable, Identifiable {
    public enum Status: Sendable {
        case scanned
        /// macOS refused access, usually because Full Disk Access is missing.
        case denied
        case unreadable
        /// Another volume mounted here; not scanned unless crossing volumes is enabled.
        case mountPoint
        /// iCloud folder whose contents are not downloaded; reading it would download them.
        case dataless
        case excluded
    }

    public let path: String
    public let name: String
    public let modificationTime: Int64
    public internal(set) weak var parent: DirectoryNode?
    public internal(set) var status = Status.scanned
    /// Sorted by size, largest first.
    public internal(set) var directories: [DirectoryNode] = []
    /// Sorted by size, largest first.
    public internal(set) var files: [FileEntry] = []
    /// Total allocated size of everything below this directory.
    public internal(set) var allocatedSize: Int64 = 0
    /// Number of files below this directory, recursively.
    public internal(set) var fileCount = 0

    init(path: String, name: String, parent: DirectoryNode?, modificationTime: Int64) {
        self.path = path
        self.name = name
        self.parent = parent
        self.modificationTime = modificationTime
    }

    /// Bundles such as apps and photo libraries that Finder shows as a single file.
    public var isPackage: Bool {
        Self.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public func path(of file: FileEntry) -> String {
        Self.join(path, file.name)
    }

    /// This node and its ancestors, from the scan root down to this node.
    public var lineage: [DirectoryNode] {
        var nodes: [DirectoryNode] = []
        var node: DirectoryNode? = self
        while let current = node {
            nodes.append(current)
            node = current.parent
        }
        return nodes.reversed()
    }

    /// All files below this directory that match `predicate`.
    public func files(where predicate: (FileEntry) -> Bool) -> [FileItem] {
        var result: [FileItem] = []
        var stack = [self]
        while let node = stack.popLast() {
            for file in node.files where predicate(file) {
                result.append(FileItem(directory: node.path, entry: file))
            }
            stack.append(contentsOf: node.directories)
        }
        return result
    }

    /// Totals sizes and file counts bottom-up and sorts children by size.
    func aggregate() {
        var order: [DirectoryNode] = []
        var stack = [self]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.directories)
        }
        for node in order.reversed() {
            var size: Int64 = 0
            var count = node.files.count
            for file in node.files {
                size += file.allocatedSize
            }
            for directory in node.directories {
                size += directory.allocatedSize
                count += directory.fileCount
            }
            node.allocatedSize = size
            node.fileCount = count
            node.files.sort { $0.allocatedSize > $1.allocatedSize }
            node.directories.sort { $0.allocatedSize > $1.allocatedSize }
        }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "qlgenerator", "saver",
        "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary", "fcpbundle", "logicx",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "dsym", "docarchive", "logarchive",
        "rtfd", "pages", "numbers", "key", "sparsebundle", "band", "imovielibrary", "lrlibrary",
    ]
}

/// A file with its full path, for flat lists such as Large & Old Files.
public struct FileItem: Sendable, Hashable, Identifiable {
    public let path: String
    public let directory: String
    public let entry: FileEntry

    public init(directory: String, entry: FileEntry) {
        self.directory = directory
        self.entry = entry
        path = DirectoryNode.join(directory, entry.name)
    }

    public var id: String { path }
    public var name: String { entry.name }
    public var allocatedSize: Int64 { entry.allocatedSize }
    public var accessDate: Date { entry.accessDate }
    public var modificationDate: Date { entry.modificationDate }
    public var kind: FileKind { entry.kind }
}
