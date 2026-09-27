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
    private var scanTask: Task<Void, Never>?
    private var scanWork: Task<Result<[CarvedFile], any Error>, Never>?

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
    func scan(device: String, output: URL) {
        guard scanTask == nil else { return }
        carved = []
        message = nil
        scanProgress = FileCarver.Progress()

        // The scan runs off the main thread and reports back through a stream.
        let (updates, progress) = AsyncStream<FileCarver.Progress>.makeStream()
        let work = Task.detached { () -> Result<[CarvedFile], any Error> in
            defer { progress.finish() }
            do {
                return try .success(await FileCarver().scan(device: "/dev/r\(device)", output: output) {
                    progress.yield($0)
                })
            } catch {
                return .failure(error)
            }
        }
        scanWork = work
        scanTask = Task { [weak self] in
            for await update in updates { self?.scanProgress = update }
            switch await work.value {
            case let .success(found):
                self?.carved = found
                self?.message = found.isEmpty
                    ? String(localized: "Nothing recognisable was found on this disk.")
                    : String(localized: "Recovered \(found.count) files into \(FinderActions.abbreviate(output.path))")
            case let .failure(error):
                self?.message = Task.isCancelled ? nil : error.localizedDescription
            }
            self?.scanTask = nil
            self?.scanWork = nil
            self?.scanProgress = nil
        }
    }

    func cancelScan() {
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
