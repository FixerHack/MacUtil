import Foundation

/// Where the watched folders and their rules are kept between launches.
public enum OrganizeStore {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacUtil/Folders.json")
    }

    public static func load(from url: URL = url) -> [WatchedFolder] {
        guard let data = try? Data(contentsOf: url),
              let folders = try? JSONDecoder().decode([WatchedFolder].self, from: data)
        else { return [] }
        return folders
    }

    public static func save(_ folders: [WatchedFolder], to url: URL = url) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(folders).write(to: url)
    }
}

/// Tells you when a folder's contents change.
///
/// A file arriving is not one event but a stream of them — a download writes in pieces and
/// renames itself at the end — so the call comes once the folder has been still for a moment,
/// rather than on every write.
public final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let settle: Duration
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.fixerhack.MacUtil.folder-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var pending: DispatchWorkItem?

    public init(path: String, settle: Duration = .seconds(2), onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.settle = settle
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        stop()
        descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleCall() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func scheduleCall() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(settle.components.seconds * 1000)), execute: work)
    }
}
