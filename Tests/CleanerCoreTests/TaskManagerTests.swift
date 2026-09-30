@testable import CleanerCore
import Foundation
import Testing

struct TaskManagerTests {
    @Test func readsEveryColumnOfPsOutput() throws {
        let line = "  501   1  12.5  65536 fixerhack   0 S /Applications/Safari.app/Contents/MacOS/Safari"
        let process = try #require(TaskManager.parse(line).first)

        #expect(process.pid == 501)
        #expect(process.parentPID == 1)
        #expect(process.cpu == 12.5)
        #expect(process.user == "fixerhack")
        #expect(process.state == .sleeping)
        #expect(process.niceness == 0)
        #expect(process.name == "Safari")
        #expect(process.isApp)
        #expect(process.appBundlePath == "/Applications/Safari.app")
        // A process id that is not running has no kernel data, so no start time either.
        #expect(process.startedAt == nil)
    }

    @Test func keepsSpacesInsideAPath() throws {
        let line = "  77   1  0,0  1024 root   0 R /Applications/My App.app/Contents/MacOS/My App"
        let process = try #require(TaskManager.parse(line).first)

        #expect(process.path == "/Applications/My App.app/Contents/MacOS/My App")
        #expect(process.name == "My App")
        #expect(process.state == .running)
        #expect(!process.isOwnedByUser)
    }

    @Test func readsNumbersWrittenWithACommaToo() {
        // In Ukrainian and many other languages ps prints 0,3 rather than 0.3.
        #expect(TaskManager.number("12,5") == 12.5)
        #expect(TaskManager.number("12.5") == 12.5)
    }

    @Test func skipsLinesItCannotRead() {
        #expect(TaskManager.parse("nonsense\n\n").isEmpty)
    }

    @Test func samplesTheRunningSystem() async throws {
        let (processes, load) = await TaskManager().sample()

        #expect(processes.count > 20)
        let me = try #require(processes.filter { $0.pid == ProcessInfo.processInfo.processIdentifier }.first)
        #expect(me.memory > 1_000_000)
        #expect(me.threads > 0)
        #expect(me.startedAt != nil)
        #expect(me.isOwnedByUser)

        #expect(!load.cores.isEmpty)
        #expect(load.memory?.total ?? 0 > 0)
        #expect(load.loadAverage.count == 3)
        #expect(load.uptime > 0)
        #expect(load.threadCount > load.processCount)
    }

    @Test func measuresDiskRatesBetweenSamples() async {
        let manager = TaskManager()
        let (first, _) = await manager.sample()
        var previous: [Int32: (read: Int64, written: Int64)] = [:]
        for process in first { previous[process.pid] = (process.diskRead, process.diskWritten) }

        // Write a file so the sample has some disk traffic to see.
        let file = FileManager.default.temporaryDirectory.appending(path: "mu-io-\(UUID().uuidString)")
        try? Data(repeating: 7, count: 4_000_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (_, load) = await manager.sample(previous: previous, interval: 1)
        #expect(load.diskWritten >= 0)
        #expect(load.diskRead >= 0)
    }
}

struct DiskInventoryTests {
    @Test func readsTheDisksOfThisMac() async throws {
        let disks = await DiskInventory.load()
        #expect(!disks.isEmpty)

        let startup = try #require(disks.filter(\.isStartupDisk).first)
        #expect(startup.size > 0)
        #expect(startup.isInternal)
        #expect(!startup.partitions.isEmpty)

        let system = try #require(startup.volumes.filter { $0.mountPoint == "/" }.first)
        #expect(system.fileSystem == "APFS")
        #expect(system.isSystemOwned)
        #expect(system.used > 0)
        #expect(system.containerID != nil)
    }

    @Test func showsTheStartupVolumeAtTheRoot() {
        // While macOS stages an update it mounts the system volume in a second place as well.
        let points = [
            "disk3s1": "/System/Volumes/Update/mnt1",
            "disk3s1s1": "/",
            "disk3s5": "/System/Volumes/Data",
        ]
        #expect(DiskInventory.mountPoint(of: "disk3s1", in: points) == "/")
        #expect(DiskInventory.mountPoint(of: "disk3s5", in: points) == "/System/Volumes/Data")
        #expect(DiskInventory.mountPoint(of: "disk9s1", in: points) == nil)
    }

    @Test func namesFileSystemsInPlainWords() {
        #expect(DiskInventory.fileSystemName("Apple_HFS") == "Mac OS Extended")
        #expect(DiskInventory.fileSystemName("Apple_APFS") == "APFS")
        #expect(DiskInventory.fileSystemName("Whatever") == "Whatever")
    }

    @Test func aPlainDataVolumeIsNotSystemOwned() {
        let volume = StorageVolume(
            id: "disk9s1", name: "Backup", fileSystem: "APFS", mountPoint: "/Volumes/Backup",
            size: 100, used: 10, isEncrypted: false, roles: [], containerID: "disk9"
        )
        #expect(!volume.isSystemOwned)
        #expect(volume.free == 90)
    }
}

/// Disk work is tried on a disk image made for the test, never on a real disk.
@Suite(.serialized) struct DiskOperationsTests {
    private func withImage(_ body: (StorageDisk, StorageVolume) async throws -> Void) async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "mu-disk-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: image) }

        let created = await DiskImages.create(at: image, volumeName: "MUTest", size: 200 * 1024 * 1024)
        try #require(created.succeeded)
        let (outcome, attached) = await DiskImages.attach(image)
        try #require(outcome.succeeded)
        let device = try #require(attached?.device)
        defer { Task { _ = await DiskImages.detach(device, force: true) } }

        let disks = await DiskInventory.load()
        let disk = try #require(disks.filter { $0.volumes.contains { $0.name == "MUTest" } }.first)
        let volume = try #require(disk.volumes.filter { $0.name == "MUTest" }.first)
        try await body(disk, volume)
        _ = await DiskImages.detach(device, force: true)
    }

    @Test func seesAnAttachedImageAsADiskWithAVolume() async throws {
        try await withImage { disk, volume in
            #expect(disk.isDiskImage)
            #expect(!disk.isStartupDisk)
            #expect(volume.isMounted)
            #expect(!volume.isSystemOwned)
            #expect(volume.fileSystem == "APFS")
        }
    }

    @Test func renamesAndErasesAVolume() async throws {
        try await withImage { _, volume in
            let renamed = await DiskOperations.rename(volume, to: "MURenamed")
            #expect(renamed.succeeded)
            #expect(renamed.command.contains("diskutil rename"))

            let wrongFormat = await DiskOperations.erase(volume, format: .macOSExtended, name: "MUErased")
            #expect(!wrongFormat.succeeded)
            #expect(DiskOperations.formats(for: volume) == [.apfs, .apfsCaseSensitive])

            let erased = await DiskOperations.erase(volume, format: .apfs, name: "MUErased")
            #expect(erased.succeeded)

            let after = await DiskInventory.load()
            #expect(after.contains { $0.volumes.contains { $0.name == "MUErased" } })
        }
    }

    @Test func measuresTheSpeedOfAVolume() async throws {
        try await withImage { _, volume in
            let mountPoint = try #require(volume.mountPoint)
            let result = try await DiskBenchmark.measure(at: URL(filePath: mountPoint), bytes: 16 * 1024 * 1024)
            #expect(result.write > 0)
            #expect(result.read > 0)
            #expect(result.bytes == 16 * 1024 * 1024)
        }
    }

    @Test func refusesToTouchTheVolumesMacOSRunsFrom() async {
        let system = StorageVolume(
            id: "disk3s1", name: "Macintosh HD", fileSystem: "APFS", mountPoint: "/",
            size: 100, used: 10, isEncrypted: true, roles: ["System"], containerID: "disk3"
        )
        let erased = await DiskOperations.erase(system, format: .apfs, name: "Nope")
        #expect(!erased.succeeded)
        #expect(erased.command.isEmpty)

        let renamed = await DiskOperations.rename(system, to: "Nope")
        #expect(!renamed.succeeded)

        let deleted = await DiskOperations.deleteVolume(system)
        #expect(!deleted.succeeded)
    }

    @Test func refusesAnImpossibleName() async {
        let volume = StorageVolume(
            id: "disk9s1", name: "Data", fileSystem: "APFS", mountPoint: nil,
            size: 100, used: 1, isEncrypted: false, roles: [], containerID: "disk9"
        )
        #expect(await !DiskOperations.rename(volume, to: "with/slash").succeeded)
        #expect(await !DiskOperations.rename(volume, to: "  ").succeeded)
    }

    @Test func spotsWhenACommandNeedsAPassword() {
        #expect(DiskOperations.needsAdministrator("diskutil: Permission denied"))
        #expect(DiskOperations.needsAdministrator("You must be root to do that"))
        #expect(!DiskOperations.needsAdministrator("Error: -69493: You can't add any more APFS Volumes"))
    }
}
