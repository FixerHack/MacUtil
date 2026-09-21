import AppKit
import ArgumentParser
import CleanerCore
import Foundation
import SecurityCore

// Command-line front end for testing the core without the UI.
// Full Disk Access here is the terminal's, not MacCleaner.app's.

@main
struct MCCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mccli",
        abstract: "MacCleaner command-line tools.",
        version: MacCleanerInfo.version,
        subcommands: [FDA.self, Disk.self, Scan.self, Large.self, Junk.self, Security.self]
    )
}

struct FDA: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Full Disk Access for this terminal.")

    func run() throws {
        switch FullDiskAccess.status() {
        case .granted:
            print("Full Disk Access: granted")
        case .denied:
            print("Full Disk Access: NOT granted")
            print("Add your terminal app in System Settings → Privacy & Security → Full Disk Access.")
            throw ExitCode.failure
        case .unknown:
            print("Full Disk Access: unknown (no protected files found to probe)")
        }
    }
}

struct Disk: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show startup disk usage.")

    func run() throws {
        let volume = try VolumeInfo.forVolume()
        print("\(volume.name): \(bytes(volume.usedCapacity)) used of \(bytes(volume.totalCapacity)), "
            + "\(bytes(volume.availableCapacity)) available")
    }
}

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan a folder and print the largest items.")

    @Argument(help: "Folder to scan.")
    var path = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

    @Option(help: "How many levels of folders to print.")
    var depth = 2

    @Option(help: "How many items to print per folder.")
    var top = 8

    @Flag(help: "Descend into other mounted volumes.")
    var crossVolumes = false

    @Option(help: "Parallel reader threads.")
    var workers = ScanOptions().workerCount

    func run() async throws {
        var options = ScanOptions()
        options.crossesVolumes = crossVolumes
        options.workerCount = workers
        let result = try await runScan(path, options: options)
        printTree(result.root, depth: depth, top: top, indent: "")
    }

    private func printTree(_ node: DirectoryNode, depth: Int, top: Int, indent: String) {
        let marker = node.status == .scanned ? "" : "  [\(node.status)]"
        print("\(bytes(node.allocatedSize).padding(10)) \(indent)\(node.name)/\(marker)")
        guard depth > 0 else { return }
        let childIndent = indent + "  "
        for directory in node.directories.prefix(top) {
            printTree(directory, depth: depth - 1, top: top, indent: childIndent)
        }
        for file in node.files.prefix(top) {
            print("\(bytes(file.allocatedSize).padding(10)) \(childIndent)\(file.name)")
        }
    }
}

struct Large: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List large and old files.")

    @Argument(help: "Folder to scan.")
    var path = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

    @Option(help: "Minimum size in megabytes.")
    var minMB = 100

    @Option(help: "Only files not opened for this many days.")
    var olderThanDays: Int?

    @Option(help: "Maximum number of files to print.")
    var limit = 50

    func run() async throws {
        let result = try await runScan(path, options: ScanOptions())
        let minimum = Int64(minMB) * 1_000_000
        let cutoff = olderThanDays.map { Int64(Date().timeIntervalSince1970) - Int64($0) * 86400 } ?? .max
        let files = result.root.files { $0.allocatedSize >= minimum && $0.accessTime <= cutoff }
            .sorted { $0.allocatedSize > $1.allocatedSize }
        let total = files.reduce(0) { $0 + $1.allocatedSize }
        print("\(files.count) files, \(bytes(total)) total\n")
        for file in files.prefix(limit) {
            let opened = file.accessDate.formatted(date: .abbreviated, time: .omitted)
            print("\(bytes(file.allocatedSize).padding(10))  \(opened.padding(14))  \(file.path)")
        }
    }
}

struct Junk: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List junk MacCleaner would clean. Read-only: nothing is removed."
    )

    @Option(help: "Rule group: system or developer. Default: both.")
    var group: String?

    @Flag(help: "Print every item, not just category totals.")
    var items = false

    func run() async throws {
        let rules = group.flatMap(JunkRule.Group.init(rawValue:)).map(JunkCatalog.rules(in:)) ?? JunkCatalog.all
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let categories = await JunkScanner.scan(rules, context: JunkContext(runningBundleIDs: running))

        for category in categories {
            let safety = category.rule.safety == .safe ? "" : "  (review)"
            print("\(bytes(category.size).padding(10))  \(String(localized: category.rule.title))\(safety)")
            guard items else { continue }
            for item in category.items {
                let lock = item.inUseBy.map { "  [in use by \($0)]" } ?? ""
                print("\(bytes(item.size).padding(22))  \(item.path)\(lock)")
            }
        }
        let total = categories.reduce(0) { $0 + $1.removableSize }
        print("\nRemovable: \(bytes(total))")
    }
}

struct Security: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Check security settings, autostart items and app signatures.")

    func run() async throws {
        async let checksTask = SystemSecurityScanner.run()
        async let persistenceTask = PersistenceScanner().scan()
        async let appsTask = AppInventory.scan()
        let (checks, persistence, apps) = await (checksTask, persistenceTask, appsTask)

        print("Security score: \(SystemSecurityScanner.score(checks))/100\n")
        for check in checks.sorted(by: { $0.status < $1.status }) {
            let mark = switch check.status {
            case .pass: "✓"
            case .warning: "!"
            case .fail: "✗"
            case .info: "i"
            }
            print("\(mark) \(String(localized: check.title)): \(String(localized: check.summary))")
        }

        print("\nAutostart (\(persistence.count)):")
        for item in persistence {
            let findings = item.findings.map { "\($0)" }.joined(separator: ", ")
            print(
                "  [\(item.risk)] \(item.label)  \(item.executable ?? "-")\(findings.isEmpty ? "" : "  → \(findings)")"
            )
        }

        let flagged = apps.filter { $0.signature.trust != .trusted }
        print("\nApps: \(apps.count), not fully trusted: \(flagged.count)")
        for app in flagged {
            print(
                "  [\(app.signature.trust)] \(app.name)  \(app.signature.signer)  notarized=\(app.signature.isNotarized)"
            )
        }
    }
}

private func runScan(_ path: String, options: ScanOptions) async throws -> ScanResult {
    let scanner = DiskScanner(options: options)
    let reporter = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let progress = scanner.progress
            FileHandle.standardError.write(Data(
                "\r\u{1B}[KScanning… \(progress.files) files, \(bytes(progress.bytes))".utf8
            ))
        }
    }
    defer { reporter.cancel() }
    let result = try await scanner.scan(URL(filePath: path))
    reporter.cancel()
    let seconds = Double(result.duration.components.seconds)
        + Double(result.duration.components.attoseconds) / 1e18
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    print(String(
        format: "Scanned %@ in %.1f s: %d files, %d folders, %@",
        result.root.path, seconds, result.root.fileCount, result.directoryCount, bytes(result.root.allocatedSize)
    ))
    if result.inaccessibleCount > 0 {
        print("\(result.inaccessibleCount) folders could not be read (Full Disk Access?)")
    }
    print()
    return result
}

private func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file))
}

private extension String {
    func padding(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
