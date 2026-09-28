import ArgumentParser
import CleanerCore
import Foundation

/// Sorts recovered pictures by whether they actually open: whole ones stay, the rest move aside.
struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check recovered pictures and set aside the ones that do not open."
    )

    @Argument(help: "Folder with recovered files.")
    var folder: String

    @Flag(name: .long, help: "Only report; do not move anything.")
    var dryRun = false

    func run() async throws {
        let root = URL(filePath: folder)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ImageSalvage.supported.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var whole = 0, partial = 0, damaged = 0
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            switch ImageSalvage.inspect(data, fileExtension: file.pathExtension.lowercased()) {
            case .whole:
                whole += 1
            case let .partial(rescued):
                partial += 1
                guard !dryRun else { continue }
                let folder = root.appending(path: "partly recovered")
                let broken = root.appending(path: "damaged")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
                try rescued.write(to: folder.appending(path: file.lastPathComponent))
                // The original is kept: it is what was found on the disk, and nothing here throws
                // away something that cannot be got again.
                try? FileManager.default.moveItem(at: file, to: broken.appending(path: file.lastPathComponent))
            case .damaged:
                damaged += 1
                guard !dryRun else { continue }
                let folder = root.appending(path: "damaged")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
        }
        print("whole \(whole), partly recovered \(partial), damaged \(damaged), of \(files.count) pictures")
    }
}
