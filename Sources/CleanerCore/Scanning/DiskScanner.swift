import Darwin
import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Descend into other volumes mounted inside the scanned folder.
    public var crossesVolumes = false
    /// Absolute paths of folders to skip.
    public var excludedPaths: Set<String> = []
    public var workerCount = min(ProcessInfo.processInfo.activeProcessorCount, 8)

    public init() {}
}

public struct ScanProgress: Sendable, Equatable {
    public var files = 0
    public var directories = 0
    public var bytes: Int64 = 0
    public var inaccessible = 0
    public var currentPath = ""

    public init() {}
}

public struct ScanResult: Sendable, Identifiable {
    public let id = UUID()
    public let root: DirectoryNode
    public let duration: Duration
    public let directoryCount: Int
    /// Folders macOS did not let us read.
    public let inaccessibleCount: Int
}

public enum ScanError: LocalizedError {
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .notADirectory(path): "Not a folder: \(path)"
        }
    }
}

/// Walks a folder tree in parallel and builds a `DirectoryNode` tree with sizes.
///
/// Sizes are allocated (on-disk) sizes. Hard links are counted once, iCloud
/// files that are not downloaded count as zero and are never downloaded, and
/// other volumes are skipped unless `crossesVolumes` is set.
public final class DiskScanner: Sendable {
    public let options: ScanOptions
    private let counters = Counters()
    private let hardLinks = Mutex(Set<HardLinkKey>())

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public var progress: ScanProgress {
        counters.snapshot()
    }

    public func cancel() {
        counters.cancelled.store(true, ordering: .relaxed)
    }

    public var isCancelled: Bool {
        counters.cancelled.load(ordering: .relaxed)
    }

    public func scan(_ url: URL) async throws -> ScanResult {
        // Not standardizedFileURL: it rewrites /private/var to /var, and paths must
        // match what other code (like SafetyGuard.resolve) produces.
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ScanError.notADirectory(path)
        }
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        let root = DirectoryNode(path: path, name: name, parent: nil, modificationTime: Int64(info.st_mtimespec.tv_sec))
        let start = ContinuousClock.now

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let queue = WorkQueue(root: root, isCancelled: { [counters] in
                    counters.cancelled.load(ordering: .relaxed)
                })
                let group = DispatchGroup()
                for _ in 0 ..< max(options.workerCount, 1) {
                    DispatchQueue.global(qos: .userInitiated).async(group: group) {
                        self.work(queue)
                    }
                }
                group.notify(queue: .global(qos: .userInitiated)) {
                    if !self.isCancelled {
                        root.aggregate()
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            cancel()
        }

        if isCancelled {
            throw CancellationError()
        }
        let progress = progress
        return ScanResult(
            root: root,
            duration: ContinuousClock.now - start,
            directoryCount: progress.directories,
            inaccessibleCount: progress.inaccessible
        )
    }

    private func work(_ queue: WorkQueue) {
        // Never download iCloud files as a side effect of looking at them.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )
        let reader = DirectoryReader()
        while let directory = queue.next() {
            queue.finish(read(directory, with: reader))
        }
    }

    /// Fills `directory` and returns the subdirectories that still need scanning.
    private func read(_ directory: DirectoryNode, with reader: DirectoryReader) -> [DirectoryNode] {
        var files: [FileEntry] = []
        var pending: [DirectoryNode] = []
        var bytes: Int64 = 0

        let error = reader.read(path: directory.path) { raw in
            if raw.type == .directory {
                let child = DirectoryNode(
                    path: DirectoryNode.join(directory.path, raw.name),
                    name: raw.name,
                    parent: directory,
                    modificationTime: raw.modificationTime
                )
                if raw.isMountPoint, !options.crossesVolumes {
                    child.status = .mountPoint
                } else if raw.flags & UInt32(SF_DATALESS) != 0 {
                    child.status = .dataless
                } else if options.excludedPaths.contains(child.path) {
                    child.status = .excluded
                } else {
                    pending.append(child)
                }
                directory.directories.append(child)
                return
            }

            var allocated = raw.allocatedSize
            if raw.linkCount > 1 {
                let key = HardLinkKey(device: raw.device, fileID: raw.fileID)
                let isFirst = hardLinks.withLock { $0.insert(key).inserted }
                if !isFirst {
                    allocated = 0
                }
            }
            bytes += allocated
            files.append(FileEntry(
                name: raw.name,
                type: raw.type == .regular ? .regular : raw.type == .symlink ? .symlink : .other,
                allocatedSize: allocated,
                logicalSize: raw.logicalSize,
                modificationTime: raw.modificationTime,
                accessTime: raw.accessTime,
                flags: raw.flags
            ))
        }

        directory.files = files
        if error != 0 {
            // EINTR comes from macOS's app data protection: without Full Disk Access,
            // opening another app's container blocks for a few seconds, then fails.
            directory.status = error == EPERM || error == EACCES || error == EINTR ? .denied : .unreadable
            counters.inaccessible.add(1, ordering: .relaxed)
        }
        counters.files.add(files.count, ordering: .relaxed)
        counters.directories.add(1, ordering: .relaxed)
        counters.bytes.add(bytes, ordering: .relaxed)
        counters.currentPath.withLock { $0 = directory.path }
        return pending
    }
}

private struct HardLinkKey: Hashable {
    let device: Int32
    let fileID: UInt64
}

private final class Counters: Sendable {
    let files = Atomic<Int>(0)
    let directories = Atomic<Int>(0)
    let bytes = Atomic<Int64>(0)
    let inaccessible = Atomic<Int>(0)
    let cancelled = Atomic<Bool>(false)
    let currentPath = Mutex("")

    func snapshot() -> ScanProgress {
        var progress = ScanProgress()
        progress.files = files.load(ordering: .relaxed)
        progress.directories = directories.load(ordering: .relaxed)
        progress.bytes = bytes.load(ordering: .relaxed)
        progress.inaccessible = inaccessible.load(ordering: .relaxed)
        progress.currentPath = currentPath.withLock { $0 }
        return progress
    }
}

/// Shared stack of directories waiting to be read. Workers stop when the stack is
/// empty and no worker is still reading (it could add more), or on cancellation.
private final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [DirectoryNode]
    private var active = 0
    private let isCancelled: @Sendable () -> Bool

    init(root: DirectoryNode, isCancelled: @escaping @Sendable () -> Bool) {
        pending = [root]
        self.isCancelled = isCancelled
    }

    func next() -> DirectoryNode? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty, active > 0, !isCancelled() {
            condition.wait()
        }
        guard !isCancelled(), let directory = pending.popLast() else {
            condition.broadcast()
            return nil
        }
        active += 1
        return directory
    }

    func finish(_ subdirectories: [DirectoryNode]) {
        condition.lock()
        pending.append(contentsOf: subdirectories)
        active -= 1
        condition.broadcast()
        condition.unlock()
    }
}
