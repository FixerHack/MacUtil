import ArgumentParser
import CleanerCore
import Foundation

/// Reads the records an exFAT card keeps about its files and brings the deleted ones back by
/// name. MacUtil runs this through an administrator prompt, because a real card belongs to root.
struct Undelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undelete",
        abstract: "List or restore deleted files using the records of an exFAT disk."
    )

    @Argument(help: "Device to read, such as disk4s1 or /dev/rdisk4s1.")
    var device: String

    @Option(name: .long, help: "Folder for the restored files. It must be on another disk.")
    var out: String?

    @Option(name: .long, help: "Give the restored files to this user instead of root.")
    var uid: Int32?

    @Flag(name: .long, help: "Only list what can be brought back.")
    var list = false

    @Flag(name: .long, help: "Print one line of JSON per file instead of plain text.")
    var json = false

    func run() async throws {
        let raw = device.hasPrefix("/dev/") ? device : "/dev/r" + device
        let recovery = ExFATRecovery()
        let files = try recovery.scan(device: raw)

        guard !list else {
            for file in files { report(file, restoredTo: nil) }
            if !json { print("\(files.count) deleted files are still listed on this disk") }
            return
        }
        guard let out else { throw ValidationError("Pass --out with a folder, or --list.") }

        let output = URL(filePath: out)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        give(output)

        var restored = 0
        for file in files {
            guard let url = try? recovery.restore(file, device: raw, to: output) else { continue }
            give(url)
            restored += 1
            report(file, restoredTo: url.path)
        }
        if !json { print("Restored \(restored) of \(files.count) files into \(out)") }
    }

    /// Running as root would leave root-owned files behind, so each one is handed back.
    private func give(_ url: URL) {
        guard let uid else { return }
        try? FileManager.default.setAttributes([.ownerAccountID: NSNumber(value: uid)], ofItemAtPath: url.path)
    }

    private func report(_ file: RecordedFile, restoredTo path: String?) {
        guard json else {
            print("\(file.path)  \(file.size) bytes")
            return
        }
        let line = Line(
            name: file.name, folder: file.folder, size: file.size,
            modified: file.modified?.timeIntervalSince1970, cluster: file.firstCluster,
            contiguous: file.isContiguous, path: path
        )
        if let data = try? JSONEncoder().encode(line) {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private struct Line: Encodable, Sendable {
        let name: String
        let folder: String
        let size: Int64
        let modified: Double?
        let cluster: UInt32
        let contiguous: Bool
        let path: String?
    }
}
