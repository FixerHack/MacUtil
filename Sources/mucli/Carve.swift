import ArgumentParser
import CleanerCore
import Foundation

/// Scans a disk for deleted files. MacUtil runs this through an administrator prompt,
/// because reading a physical disk needs root, and it reports back through the output folder.
struct Carve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "carve",
        abstract: "Recover deleted files from a disk by reading it byte by byte."
    )

    @Argument(help: "Device to read, such as disk4 or /dev/rdisk4.")
    var device: String

    @Option(name: .long, help: "Folder for the recovered files. It must be on another disk.")
    var out: String

    @Option(name: .long, help: "Give the recovered files to this user instead of root.")
    var uid: Int32?

    @Option(name: .long, help: "Stop after this many files.")
    var limit = 5000

    @Flag(name: .long, help: "Print one line of JSON per file instead of plain text.")
    var json = false

    func run() async throws {
        let raw = device.hasPrefix("/dev/") ? device : "/dev/r" + device
        let output = URL(filePath: out)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // MacUtil watches this file to show progress while the scan runs as root, and
        // creates the stop file to end a scan it cannot signal, because this runs as root.
        let progressFile = output.appending(path: ".macutil-progress.json")
        let stopFile = output.appending(path: ".macutil-stop")
        try? FileManager.default.removeItem(at: stopFile)
        let owner = uid
        // Running as root would leave root-owned files behind, so each one is handed back.
        let give: @Sendable (URL) -> Void = { url in
            guard let owner else { return }
            try? FileManager.default.setAttributes(
                [.ownerAccountID: NSNumber(value: owner)], ofItemAtPath: url.path
            )
        }
        give(output)

        let scan = Task { () -> [CarvedFile] in
            try await FileCarver().scan(device: raw, output: output, limit: limit) { progress in
            let payload: [String: Any] = [
                "bytesScanned": progress.bytesScanned, "totalBytes": progress.totalBytes, "found": progress.found,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: progressFile, options: .atomic)
                give(progressFile)
            }
            } found: { file in
                if let path = file.recoveredTo { give(URL(filePath: path)) }
                if json, let data = try? JSONEncoder().encode(FoundLine(file)) {
                    print(String(decoding: data, as: UTF8.self))
                }
            }
        }
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if FileManager.default.fileExists(atPath: stopFile.path) { scan.cancel() }
            }
        }
        let found = try await scan.value
        watcher.cancel()

        try? FileManager.default.removeItem(at: progressFile)
        try? FileManager.default.removeItem(at: stopFile)
        if !json {
            print("Recovered \(found.count) files into \(out)")
        }
    }

    /// What MacUtil reads back from each line.
    private struct FoundLine: Encodable, Sendable {
        let signature: String
        let fileExtension: String
        let size: Int64
        let offset: Int64
        let sha256: String
        let path: String?

        init(_ file: CarvedFile) {
            signature = file.signature
            fileExtension = file.fileExtension
            size = file.size
            offset = file.offset
            sha256 = file.sha256
            path = file.recoveredTo
        }
    }
}
