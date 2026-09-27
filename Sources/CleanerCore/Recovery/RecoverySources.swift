import Foundation

/// A file that can be brought back, whatever it was found in.
public struct RecoverableFile: Sendable, Identifiable, Hashable {
    public enum Source: Sendable, Hashable {
        case trash
        /// An APFS snapshot macOS took before changes.
        case snapshot(String)
        case timeMachine(String)
    }

    public let id: String
    public let name: String
    /// Where the file sits now, inside the Trash, a mounted snapshot or a backup.
    public let path: String
    public let size: Int64
    public let modified: Date?
    public let source: Source
    public let isDirectory: Bool
}

/// Files in the Trash, and putting them back.
public enum TrashRecovery {
    public static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    public static func list() -> [RecoverableFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return RecoverableFile(
                id: url.path, name: url.lastPathComponent, path: url.path,
                size: Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0),
                modified: values?.contentModificationDate, source: .trash,
                isDirectory: values?.isDirectory ?? false
            )
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Moves an item out of the Trash. Finder's own put-back path is not readable by other
    /// apps, so the person chooses where it lands.
    public static func restore(_ file: RecoverableFile, to directory: URL) throws -> URL {
        let destination = uniqueURL(in: directory, named: file.name)
        try FileManager.default.moveItem(at: URL(filePath: file.path), to: destination)
        return destination
    }

    static func uniqueURL(in directory: URL, named name: String) -> URL {
        var candidate = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let extensionPart = (name as NSString).pathExtension
        var index = 2
        repeat {
            let suffix = extensionPart.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(extensionPart)"
            candidate = directory.appending(path: suffix)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// APFS snapshots: the copies macOS keeps of the whole volume, which Time Machine makes
/// every hour. A snapshot can be mounted read-only and files pulled out of it.
public enum SnapshotRecovery {
    public struct Mounted: Sendable, Hashable {
        public let snapshot: String
        public let mountPoint: String
    }

    public static func list(volume: String = "/") async -> [LocalSnapshots.Snapshot] {
        await LocalSnapshots.list(volume: volume)
    }

    /// Mounts a snapshot read-only. Only the kernel may do this, so it asks for a password.
    public static func mount(
        _ snapshot: LocalSnapshots.Snapshot, of volume: String = "/System/Volumes/Data"
    ) async -> (outcome: DiskOperations.Outcome, mounted: Mounted?) {
        let mountPoint = FileManager.default.temporaryDirectory
            .appending(path: "MacUtilSnapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let command = "/sbin/mount_apfs -o ro -s \(snapshot.name) \(volume) \(mountPoint.path)"
        let plain = await Command.run(
            "/sbin/mount_apfs", ["-o", "ro", "-s", snapshot.name, volume, mountPoint.path], timeout: .seconds(120)
        )
        if plain?.status == 0 {
            return (
                DiskOperations.Outcome(succeeded: true, output: plain?.text ?? "", wasCancelled: false, command: command),
                Mounted(snapshot: snapshot.name, mountPoint: mountPoint.path)
            )
        }
        let elevated = await AdminRunner.run([command], prompt: String(
            localized: "MacUtil needs your password to open this snapshot for reading."
        ))
        let outcome = DiskOperations.Outcome(
            succeeded: elevated.succeeded, output: elevated.text, wasCancelled: elevated.wasCancelled, command: command
        )
        return (outcome, elevated.succeeded ? Mounted(snapshot: snapshot.name, mountPoint: mountPoint.path) : nil)
    }

    public static func unmount(_ mounted: Mounted) async {
        let plain = await Command.run("/sbin/umount", [mounted.mountPoint], timeout: .seconds(60))
        if plain?.status != 0 {
            _ = await AdminRunner.run(["/sbin/umount \(mounted.mountPoint)"], prompt: String(
                localized: "MacUtil needs your password to close this snapshot."
            ))
        }
        try? FileManager.default.removeItem(at: URL(filePath: mounted.mountPoint))
    }

    /// Looks for files whose name contains `text` inside a mounted snapshot.
    public static func search(_ text: String, in mounted: Mounted, limit: Int = 300) async -> [RecoverableFile] {
        await find(text, root: mounted.mountPoint, source: .snapshot(mounted.snapshot), limit: limit)
    }

    /// Copies a file out of a snapshot. The snapshot itself is read-only and stays untouched.
    public static func restore(_ file: RecoverableFile, to directory: URL) throws -> URL {
        let destination = TrashRecovery.uniqueURL(in: directory, named: file.name)
        try FileManager.default.copyItem(at: URL(filePath: file.path), to: destination)
        return destination
    }
}

/// Time Machine backups on a connected backup disk.
public enum TimeMachineRecovery {
    public struct Backup: Sendable, Identifiable, Hashable {
        public let path: String
        public let date: Date?
        public var id: String { path }
    }

    /// Whether a backup disk is set up at all.
    public static func hasDestination() async -> Bool {
        let output = await Command.run("/usr/bin/tmutil", ["destinationinfo"], timeout: .seconds(30))
        return output?.status == 0 && !(output?.text.contains("No destinations") ?? true)
    }

    public static func backups() async -> [Backup] {
        guard let output = await Command.run("/usr/bin/tmutil", ["listbackups"], timeout: .seconds(120)),
              output.status == 0
        else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return output.text.split(separator: "\n").map { line in
            let path = String(line)
            let stamp = (path as NSString).lastPathComponent.replacingOccurrences(of: ".backup", with: "")
            return Backup(path: path, date: formatter.date(from: stamp))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public static func search(_ text: String, in backup: Backup, limit: Int = 300) async -> [RecoverableFile] {
        await find(text, root: backup.path, source: .timeMachine(backup.path), limit: limit)
    }

    /// `tmutil restore` keeps the file's dates and permissions, which a plain copy does not.
    public static func restore(_ file: RecoverableFile, to directory: URL) async -> DiskOperations.Outcome {
        let destination = TrashRecovery.uniqueURL(in: directory, named: file.name)
        let command = "/usr/bin/tmutil restore '\(file.path)' '\(destination.path)'"
        let plain = await Command.run(
            "/usr/bin/tmutil", ["restore", file.path, destination.path], timeout: .seconds(1800)
        )
        if plain?.status == 0 {
            return DiskOperations.Outcome(succeeded: true, output: destination.path, wasCancelled: false, command: command)
        }
        let elevated = await AdminRunner.run([command], prompt: String(
            localized: "MacUtil needs your password to restore this file from the backup."
        ))
        return DiskOperations.Outcome(
            succeeded: elevated.succeeded, output: elevated.succeeded ? destination.path : elevated.text,
            wasCancelled: elevated.wasCancelled, command: command
        )
    }
}

/// Shared search used by snapshots and backups: `find` walks far faster than Foundation here,
/// and it keeps going when a folder cannot be read.
func find(_ text: String, root: String, source: RecoverableFile.Source, limit: Int) async -> [RecoverableFile] {
    let pattern = "*\(text)*"
    guard let output = await Command.run(
        "/usr/bin/find", [root, "-iname", pattern, "-not", "-type", "l"], timeout: .seconds(300)
    ) else { return [] }

    var files: [RecoverableFile] = []
    for line in output.text.split(separator: "\n") {
        let path = String(line)
        guard path.hasPrefix(root) else { continue }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        files.append(RecoverableFile(
            id: path, name: (path as NSString).lastPathComponent, path: path,
            size: (attributes?[.size] as? Int64) ?? 0,
            modified: attributes?[.modificationDate] as? Date,
            source: source, isDirectory: isDirectory.boolValue
        ))
        if files.count >= limit { break }
    }
    return files
}
