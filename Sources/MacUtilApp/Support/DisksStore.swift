import CleanerCore
import Foundation
import Observation

/// Disks, volumes and the changes MacUtil can make to them.
@MainActor
@Observable
final class DisksStore {
    struct Job: Equatable {
        let title: String
        var command: String?
        var output: String?
        var succeeded: Bool?
    }

    private(set) var disks: [StorageDisk] = []
    private(set) var loading = false
    private(set) var job: Job?
    private(set) var benchmark: DiskBenchmark.Result?
    private(set) var benchmarkProgress: Double?
    private(set) var snapshots: [LocalSnapshots.Snapshot] = []
    /// What macOS left behind after updating itself.
    private(set) var leftovers: [SystemLeftover] = []
    private(set) var scanningLeftovers = false

    var selection: String?

    var selectedVolume: StorageVolume? {
        disks.flatMap(\.volumes).first { $0.id == selection }
    }

    var selectedDisk: StorageDisk? {
        disks.first { $0.id == selection } ?? disks.first { $0.volumes.contains { $0.id == selection } }
    }

    /// Looks for update leftovers. It reads sizes of large folders, so it is asked for, not automatic.
    func findLeftovers() async {
        scanningLeftovers = true
        defer { scanningLeftovers = false }
        leftovers = await SystemLeftovers.scan()
    }

    func remove(_ leftover: SystemLeftover) async {
        await run(String(localized: "Removing \(leftover.title)")) { await SystemLeftovers.remove(leftover) }
        await findLeftovers()
    }

    func load() async {
        loading = disks.isEmpty
        disks = await DiskInventory.load()
        snapshots = await LocalSnapshots.list()
        loading = false
        if selection == nil { selection = disks.first(where: \.isStartupDisk)?.volumes.first(where: \.isStartup)?.id }
    }

    // MARK: - Volume work

    func mount(_ volume: StorageVolume) async {
        await run(String(localized: "Mounting \(volume.name)")) { await DiskOperations.mount(volume) }
    }

    func unmount(_ volume: StorageVolume) async {
        await run(String(localized: "Unmounting \(volume.name)")) { await DiskOperations.unmount(volume) }
    }

    func eject(_ disk: StorageDisk) async {
        await run(String(localized: "Ejecting \(disk.model)")) { await DiskOperations.eject(disk) }
    }

    func rename(_ volume: StorageVolume, to name: String) async {
        await run(String(localized: "Renaming \(volume.name)")) { await DiskOperations.rename(volume, to: name) }
    }

    func verify(_ volume: StorageVolume) async {
        await run(String(localized: "Checking \(volume.name)")) { await DiskOperations.verify(volume) }
    }

    func repair(_ volume: StorageVolume) async {
        await run(String(localized: "Repairing \(volume.name)")) { await DiskOperations.repair(volume) }
    }

    func erase(_ volume: StorageVolume, format: DiskFormat, name: String) async {
        await run(String(localized: "Erasing \(volume.name)")) {
            await DiskOperations.erase(volume, format: format, name: name)
        }
    }

    func addVolume(container: String, name: String, quota: Int64?) async {
        await run(String(localized: "Adding volume \(name)")) {
            await DiskOperations.addVolume(container: container, name: name, quota: quota)
        }
    }

    func deleteVolume(_ volume: StorageVolume) async {
        await run(String(localized: "Deleting \(volume.name)")) { await DiskOperations.deleteVolume(volume) }
    }

    func deleteSnapshot(_ snapshot: LocalSnapshots.Snapshot) async {
        await run(String(localized: "Deleting snapshot")) { await LocalSnapshots.delete(snapshot) }
    }

    // MARK: - Disk images

    func createImage(at url: URL, name: String, size: Int64, kind: DiskImages.Kind, format: DiskFormat) async {
        await run(String(localized: "Creating disk image")) {
            await DiskImages.create(at: url, volumeName: name, size: size, kind: kind, format: format)
        }
    }

    func attachImage(_ url: URL) async {
        await run(String(localized: "Opening disk image")) { await DiskImages.attach(url).outcome }
    }

    // MARK: - Speed test

    func measureSpeed(of volume: StorageVolume) async {
        guard let mountPoint = volume.mountPoint else { return }
        benchmark = nil
        benchmarkProgress = 0
        defer { benchmarkProgress = nil }
        do {
            benchmark = try await Task.detached {
                try await DiskBenchmark.measure(at: URL(filePath: mountPoint)) { fraction in
                    Task { @MainActor in self.benchmarkProgress = fraction }
                }
            }.value
        } catch {
            job = Job(title: String(localized: "Speed test"), command: nil, output: error.localizedDescription, succeeded: false)
        }
    }

    func dismissJob() {
        job = nil
    }

    private func run(_ title: String, _ work: () async -> DiskOperations.Outcome) async {
        job = Job(title: title)
        let outcome = await work()
        guard !outcome.wasCancelled else {
            job = nil
            return
        }
        job = Job(
            title: title, command: outcome.command.isEmpty ? nil : outcome.command,
            output: outcome.output.trimmingCharacters(in: .whitespacesAndNewlines), succeeded: outcome.succeeded
        )
        await load()
    }
}
