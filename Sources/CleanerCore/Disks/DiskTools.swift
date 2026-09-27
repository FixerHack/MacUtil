import Darwin
import Foundation

/// Disk images: a file that behaves like a disk. Handy for a safe sandbox, a portable
/// volume or an encrypted container.
public enum DiskImages {
    public struct Attached: Sendable, Hashable {
        /// `/dev/disk9`, the device the image became.
        public let device: String
        public let mountPoint: String?
    }

    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        /// Fixed size, one file.
        case readWrite = "UDIF"
        /// Grows as you fill it.
        case sparse = "SPARSE"
        /// Grows in chunks; best for large images and backups.
        case sparseBundle = "SPARSEBUNDLE"
        /// Compressed and read-only, for sharing. Made by converting an image, not created empty.
        case compressed = "UDZO"

        public var id: String { rawValue }

        public var fileExtension: String {
            switch self {
            case .sparse: "sparseimage"
            case .sparseBundle: "sparsebundle"
            default: "dmg"
            }
        }
    }

    public static func create(
        at url: URL, volumeName: String, size: Int64, kind: Kind = .readWrite, format: DiskFormat = .apfs
    ) async -> DiskOperations.Outcome {
        // Compressed images are made by converting a finished one, never created empty.
        let type = kind == .compressed ? Kind.readWrite.rawValue : kind.rawValue
        // hdiutil counts in 512-byte blocks when the size ends in "b".
        let blocks = max(1, size / 512)
        let arguments = [
            "create", "-size", "\(blocks)b", "-fs", format.rawValue, "-volname", volumeName,
            "-type", type, "-layout", "GPTSPUD", url.path,
        ]
        return await run(arguments, timeout: .seconds(600))
    }

    /// Attaches an image and says where it landed.
    public static func attach(_ url: URL, readOnly: Bool = false) async -> (outcome: DiskOperations.Outcome, attached: Attached?) {
        var arguments = ["attach", url.path, "-plist", "-nobrowse"]
        if readOnly { arguments.append("-readonly") }
        let outcome = await run(arguments, timeout: .seconds(300))
        guard outcome.succeeded,
              let data = outcome.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return (outcome, nil) }

        let mounted = entities.first { $0["mount-point"] is String }
        let device = (mounted?["dev-entry"] as? String)
            ?? entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
        guard let device else { return (outcome, nil) }
        return (outcome, Attached(device: device, mountPoint: mounted?["mount-point"] as? String))
    }

    public static func detach(_ device: String, force: Bool = false) async -> DiskOperations.Outcome {
        await run(["detach", device] + (force ? ["-force"] : []), timeout: .seconds(120))
    }

    /// Checks that the image is whole and readable.
    public static func verify(_ url: URL) async -> DiskOperations.Outcome {
        await run(["verify", url.path], timeout: .seconds(1800))
    }

    /// Writes the image out in another format, for example compressed for sharing.
    public static func convert(_ url: URL, to kind: Kind, output: URL) async -> DiskOperations.Outcome {
        await run(["convert", url.path, "-format", kind.rawValue, "-o", output.path], timeout: .seconds(1800))
    }

    static func run(_ arguments: [String], timeout: Duration) async -> DiskOperations.Outcome {
        let command = "hdiutil " + arguments.joined(separator: " ")
        let output = await Command.run("/usr/bin/hdiutil", arguments, timeout: timeout)
        return DiskOperations.Outcome(
            succeeded: output?.status == 0, output: output?.text ?? "", wasCancelled: false, command: command
        )
    }
}

/// Measures how fast a volume reads and writes, the way a disk benchmark does.
public enum DiskBenchmark {
    public struct Result: Sendable, Equatable {
        /// Bytes per second.
        public let write: Double
        public let read: Double
        public let bytes: Int64
    }

    public enum Failure: LocalizedError {
        case notWritable(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case let .notWritable(name):
                String(localized: "MacUtil cannot write to \(name), so it cannot measure its speed.")
            case let .failed(message):
                message
            }
        }
    }

    /// Writes a file, flushes it to the drive, then reads it back with the cache turned off,
    /// so the numbers describe the disk rather than memory.
    public static func measure(
        at directory: URL, bytes: Int64 = 256 * 1024 * 1024, progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw Failure.notWritable(directory.lastPathComponent)
        }
        let file = directory.appending(path: ".macutil-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let chunkSize = 8 * 1024 * 1024
        let chunk = Data(repeating: 0xAB, count: chunkSize)
        let chunks = max(1, Int(bytes) / chunkSize)

        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: file)
        else { throw Failure.notWritable(directory.lastPathComponent) }

        let writeStart = Date()
        for index in 0 ..< chunks {
            try writer.write(contentsOf: chunk)
            progress(Double(index + 1) / Double(chunks) / 2)
        }
        // Without this the numbers would describe the write cache, not the disk.
        _ = fcntl(writer.fileDescriptor, F_FULLFSYNC)
        try writer.close()
        let written = Date().timeIntervalSince(writeStart)

        guard let reader = try? FileHandle(forReadingFrom: file) else {
            throw Failure.failed(String(localized: "The test file could not be read back."))
        }
        // F_NOCACHE makes macOS read from the drive instead of the file cache.
        _ = fcntl(reader.fileDescriptor, F_NOCACHE, 1)
        let readStart = Date()
        var index = 0
        while let piece = try reader.read(upToCount: chunkSize), !piece.isEmpty {
            index += 1
            progress(0.5 + Double(index) / Double(chunks) / 2)
        }
        try reader.close()
        let read = Date().timeIntervalSince(readStart)

        let total = Int64(chunks * chunkSize)
        return Result(
            write: written > 0 ? Double(total) / written : 0,
            read: read > 0 ? Double(total) / read : 0,
            bytes: total
        )
    }
}

/// Local Time Machine snapshots, which quietly hold on to disk space.
public enum LocalSnapshots {
    public struct Snapshot: Sendable, Identifiable, Hashable {
        public let name: String
        public let date: Date?
        public var id: String { name }
    }

    public static func list(volume: String = "/") async -> [Snapshot] {
        guard let output = await Command.run("/usr/bin/tmutil", ["listlocalsnapshots", volume], timeout: .seconds(60))
        else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return output.text.split(separator: "\n").compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.contains("com.apple.TimeMachine") else { return nil }
            let stamp = name.split(separator: ".").last.map(String.init) ?? ""
            return Snapshot(name: name, date: formatter.date(from: stamp))
        }
    }

    /// Deletes one snapshot. The backups on a Time Machine disk are untouched.
    public static func delete(_ snapshot: Snapshot, volume: String = "/") async -> DiskOperations.Outcome {
        let stamp = snapshot.name.split(separator: ".").last.map(String.init) ?? snapshot.name
        let command = "/usr/bin/tmutil deletelocalsnapshots \(stamp)"
        let plain = await Command.run("/usr/bin/tmutil", ["deletelocalsnapshots", stamp], timeout: .seconds(300))
        if plain?.status == 0 {
            return DiskOperations.Outcome(succeeded: true, output: plain?.text ?? "", wasCancelled: false, command: command)
        }
        let elevated = await AdminRunner.run([command], prompt: String(
            localized: "MacUtil needs your password to delete this local snapshot."
        ))
        return DiskOperations.Outcome(
            succeeded: elevated.succeeded, output: elevated.text, wasCancelled: elevated.wasCancelled, command: command
        )
    }
}
