import CleanerCore
import Foundation
import Observation

/// Getting deleted files back, from the Trash, a snapshot, a backup, or the disk itself.
@MainActor
@Observable
final class RecoveryStore {
    enum Source: String, CaseIterable, Identifiable {
        case trash, snapshots, timeMachine, scan

        var id: String { rawValue }
    }

    private(set) var trashItems: [RecoverableFile] = []
    private(set) var snapshots: [LocalSnapshots.Snapshot] = []
    private(set) var mountedSnapshot: SnapshotRecovery.Mounted?
    private(set) var backups: [TimeMachineRecovery.Backup] = []
    private(set) var hasBackupDisk = false
    private(set) var results: [RecoverableFile] = []
    private(set) var busy = false
    private(set) var message: String?

    /// Devices worth scanning: everything but the disk macOS runs from.
    private(set) var scannableDisks: [StorageDisk] = []
    private(set) var carved: [CarvedFile] = []
    private(set) var scanProgress: FileCarver.Progress?
    private(set) var scanStartedAt: Date?
    private var scanOutput: URL?

    /// Reading speed and time left, once there is enough to judge by.
    var scanRate: (speed: String, remaining: String)? {
        guard let scanProgress, let scanStartedAt, scanProgress.bytesScanned > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(scanStartedAt)
        guard elapsed > 3 else { return nil }
        let bytesPerSecond = Double(scanProgress.bytesScanned) / elapsed
        let left = Double(max(0, scanProgress.totalBytes - scanProgress.bytesScanned))
        let seconds = bytesPerSecond > 0 ? left / bytesPerSecond : 0
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return (
            "\(Int64(bytesPerSecond).formatted(.byteCount(style: .file)))/s",
            formatter.string(from: seconds) ?? ""
        )
    }
    private var scanTask: Task<Void, Never>?
    private var scanWork: Task<Result<[CarvedFile], any Error>, Never>?
    /// Lets the scan, which runs off the main thread, add files as it finds them.
    @MainActor private static weak var shared: RecoveryStore?

    var source = Source.trash
    var search = ""
    var selectedSnapshot: LocalSnapshots.Snapshot?
    var selectedBackup: TimeMachineRecovery.Backup?
    var selectedDevice: String?

    func load() async {
        trashItems = TrashRecovery.list()
        snapshots = await SnapshotRecovery.list()
        hasBackupDisk = await TimeMachineRecovery.hasDestination()
        if hasBackupDisk { backups = await TimeMachineRecovery.backups() }
        scannableDisks = await DiskInventory.load().filter { !$0.isStartupDisk }
        if selectedDevice == nil { selectedDevice = scannableDisks.first?.id }
        if selectedSnapshot == nil { selectedSnapshot = snapshots.first }
        if selectedBackup == nil { selectedBackup = backups.first }
    }

    // MARK: - Trash

    func restoreFromTrash(_ file: RecoverableFile, to directory: URL) {
        do {
            let url = try TrashRecovery.restore(file, to: directory)
            message = String(localized: "Restored to \(FinderActions.abbreviate(url.path))")
            FinderActions.reveal([url.path])
            trashItems = TrashRecovery.list()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Snapshots

    func openSnapshot(_ snapshot: LocalSnapshots.Snapshot) async {
        busy = true
        defer { busy = false }
        if let mountedSnapshot { await SnapshotRecovery.unmount(mountedSnapshot) }
        let (outcome, mounted) = await SnapshotRecovery.mount(snapshot)
        mountedSnapshot = mounted
        message = mounted == nil && !outcome.wasCancelled ? outcome.output : nil
    }

    func closeSnapshot() async {
        guard let mountedSnapshot else { return }
        await SnapshotRecovery.unmount(mountedSnapshot)
        self.mountedSnapshot = nil
        results = []
    }

    // MARK: - Searching a snapshot or a backup

    func runSearch() async {
        guard search.count >= 2 else { return }
        busy = true
        defer { busy = false }
        switch source {
        case .snapshots:
            guard let mountedSnapshot else {
                message = String(localized: "Open a snapshot first.")
                return
            }
            results = await SnapshotRecovery.search(search, in: mountedSnapshot)
        case .timeMachine:
            guard let selectedBackup else { return }
            results = await TimeMachineRecovery.search(search, in: selectedBackup)
        case .trash, .scan:
            break
        }
        if results.isEmpty { message = String(localized: "Nothing found with that name.") }
    }

    func restore(_ file: RecoverableFile, to directory: URL) async {
        busy = true
        defer { busy = false }
        switch file.source {
        case .trash:
            restoreFromTrash(file, to: directory)
        case .snapshot:
            do {
                let url = try SnapshotRecovery.restore(file, to: directory)
                message = String(localized: "Restored to \(FinderActions.abbreviate(url.path))")
                FinderActions.reveal([url.path])
            } catch {
                message = error.localizedDescription
            }
        case .timeMachine:
            let outcome = await TimeMachineRecovery.restore(file, to: directory)
            message = outcome.succeeded
                ? String(localized: "Restored to \(FinderActions.abbreviate(outcome.output))")
                : outcome.output
            if outcome.succeeded { FinderActions.reveal([outcome.output]) }
        }
    }

    // MARK: - Scanning a disk for deleted files

    var isScanning: Bool { scanTask != nil }

    /// Scans the raw device for file shapes and writes what it finds into `output`,
    /// which must sit on a different disk than the one being scanned.
    ///
    /// Physical disks belong to root, so when MacUtil is not allowed to read one itself it runs
    /// the same scan through the bundled command-line tool with an administrator prompt, and
    /// follows along through the progress file that tool writes.
    func scan(device: String, output: URL) {
        guard scanTask == nil else { return }
        carved = []
        message = nil
        scanProgress = FileCarver.Progress()
        scanStartedAt = Date()
        scanOutput = output
        try? FileManager.default.removeItem(at: output.appending(path: ".macutil-stop"))

        let (updates, progress) = AsyncStream<FileCarver.Progress>.makeStream()
        let work = Task.detached { () -> Result<[CarvedFile], any Error> in
            defer { progress.finish() }
            do {
                return try .success(await FileCarver().scan(device: "/dev/r\(device)", output: output) {
                    progress.yield($0)
                } found: { file in
                    Task { @MainActor in RecoveryStore.shared?.carved.append(file) }
                })
            } catch {
                return .failure(error)
            }
        }
        scanWork = work
        scanTask = Task { [weak self] in
            RecoveryStore.shared = self
            for await update in updates { self?.scanProgress = update }
            switch await work.value {
            case let .success(found):
                self?.carved = found
                self?.message = found.isEmpty
                    ? String(localized: "Nothing recognisable was found on this disk.")
                    : String(localized: "Recovered \(found.count) files into \(FinderActions.abbreviate(output.path))")
            case let .failure(error):
                if case FileCarver.Failure.notAllowed = error {
                    await self?.scanAsAdministrator(device: device, output: output)
                } else {
                    self?.message = Task.isCancelled ? nil : error.localizedDescription
                }
            }
            self?.scanTask = nil
            self?.scanWork = nil
            self?.scanProgress = nil
            self?.scanStartedAt = nil
        }
    }

    /// The same scan, run by the bundled tool with a password, because the disk belongs to root.
    private func scanAsAdministrator(device: String, output: URL) async {
        guard let tool = Bundle.main.url(forResource: "mucli", withExtension: nil) else {
            message = String(localized: "The scanning tool is missing from this copy of MacUtil.")
            return
        }
        scanProgress = FileCarver.Progress()
        scanStartedAt = Date()
        let watcher = Task { [weak self] in
            // The tool writes its progress into the output folder as it goes.
            let file = output.appending(path: ".macutil-progress.json")
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let data = try? Data(contentsOf: file),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                var progress = FileCarver.Progress()
                progress.bytesScanned = payload["bytesScanned"] as? Int64 ?? 0
                progress.totalBytes = payload["totalBytes"] as? Int64 ?? 0
                progress.found = payload["found"] as? Int ?? 0
                await MainActor.run { self?.scanProgress = progress }
            }
        }
        defer { watcher.cancel() }

        let command = "'\(tool.path)' carve \(device) --out '\(output.path)' --uid \(getuid()) --json"
        let result = await AdminRunner.run([command], prompt: String(
            localized: "MacUtil needs your password to read this disk. Nothing is written to it."
        ))
        try? FileManager.default.removeItem(at: output.appending(path: ".macutil-progress.json"))
        guard !result.wasCancelled else { return }
        guard result.succeeded else {
            message = result.text
            return
        }
        carved = Self.parse(result.text)
        message = carved.isEmpty
            ? String(localized: "Nothing recognisable was found on this disk.")
            : String(localized: "Recovered \(carved.count) files into \(FinderActions.abbreviate(output.path))")
    }

    /// Reads back the one line of JSON the tool prints for each recovered file.
    static func parse(_ output: String) -> [CarvedFile] {
        struct Line: Decodable {
            let signature: String
            let fileExtension: String
            let size: Int64
            let offset: Int64
            let sha256: String
            let path: String?
        }
        return output.split(separator: "\n").compactMap { text in
            guard let data = text.data(using: .utf8), let line = try? JSONDecoder().decode(Line.self, from: data)
            else { return nil }
            return CarvedFile(
                id: UUID(), signature: line.signature, fileExtension: line.fileExtension,
                offset: line.offset, size: line.size, sha256: line.sha256,
                recoveredTo: line.path, isStillOnDisk: false
            )
        }
    }

    func cancelScan() {
        // The scan may be running as root, where a signal is not an option: it watches for this
        // file in the folder it writes to and stops when it appears.
        if let folder = scanOutput {
            FileManager.default.createFile(atPath: folder.appending(path: ".macutil-stop").path, contents: nil)
        }
        scanWork?.cancel()
        scanTask?.cancel()
        scanWork = nil
        scanTask = nil
        scanProgress = nil
    }

    func clearMessage() {
        message = nil
    }
}
