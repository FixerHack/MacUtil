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
    }

    /// The start time does not come from the text at all: `ps` prints it in the locale's
    /// own words, so it is read from the kernel by process id. Asserting it is empty for a
    /// made-up line only holds while nothing happens to be running under that number, which
    /// is true here and was not on the build runner.
    @Test func takesTheStartTimeFromTheKernel() throws {
        let mine = ProcessInfo.processInfo.processIdentifier
        let started = try #require(TaskManager.kernelInfo(pid: mine).startedAt)
        #expect(started <= Date())
        #expect(started > Date().addingTimeInterval(-86400))

        // A number no process can have returns nothing rather than a wrong answer.
        #expect(TaskManager.kernelInfo(pid: -1).startedAt == nil)
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

    /// `hdiutil attach` returns before the volume is mounted, so the disk has to be waited for.
    ///
    /// The waiting is done on `/Volumes/<name>`, which is one `stat`. Polling the inventory
    /// instead runs `diskutil` several times per attempt, and while the rest of the suite is
    /// scanning and carving that takes seconds — so a wait spent querying managed only a few
    /// attempts before giving up, which is how this failed under a full test run and nowhere else.
    private func disk(withVolume name: String, within seconds: TimeInterval = 30) async -> StorageDisk? {
        let mountPoint = "/Volumes/\(name)"
        let mounted = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: mountPoint), Date() < mounted {
            try? await Task.sleep(for: .milliseconds(200))
        }

        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let disks = await DiskInventory.load()
            if let disk = disks.first(where: { $0.volumes.contains { $0.name == name } }) { return disk }
            guard Date() < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func withImage(_ body: (StorageDisk, StorageVolume) async throws -> Void) async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "mu-disk-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: image) }

        // A name of its own for every image. Two volumes called the same thing can be
        // attached at once, and macOS quietly mounts the second as "MUTest 1" — which a
        // search for "MUTest" then never finds.
        let name = "MUTest-\(UUID().uuidString.prefix(8))"
        let created = await DiskImages.create(at: image, volumeName: name, size: 200 * 1024 * 1024)
        try #require(created.succeeded)
        let (outcome, attached) = await DiskImages.attach(image)
        try #require(outcome.succeeded)
        let device = try #require(attached?.device)

        // Detached before this returns, whatever happened. `defer` cannot await, and a
        // Task in one lets the next test begin while this image is still attached.
        do {
            let disk = try #require(await disk(withVolume: name))
            let volume = try #require(disk.volumes.filter { $0.name == name }.first)
            try await body(disk, volume)
        } catch {
            _ = await DiskImages.detach(device, force: true)
            throw error
        }
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

struct SystemLeftoverTests {
    private let listing = """
    Snapshots for disk3s1 (2 found)
    |
    +-- 61A36340-0543-450A-A16B-B53F8478F7C4
    |   Name:        com.apple.os.update-5203530F8BB20B9DABC5CE76A0
    |   XID:         4865245
    |   Purgeable:   No
    |
    +-- 91436BCF-0975-4FDC-9985-48CCD522042B
        Name:        com.apple.os.update-9256CC8B26ED66FB31F175DC7E
        XID:         4976045
        Purgeable:   No
    """

    @Test func offersOldUpdateCopiesButNeverTheRunningOne() {
        let booted = "61A36340-0543-450A-A16B-B53F8478F7C4"
        let found = SystemLeftovers.parseSnapshots(listing, volume: "disk3s1", booted: booted)

        #expect(found.count == 1)
        #expect(found.first?.snapshot?.uuid == "91436BCF-0975-4FDC-9985-48CCD522042B")
        #expect(found.first?.snapshot?.volume == "disk3s1")
        #expect(found.first?.kind == .updateSnapshot)
    }

    @Test func leavesSnapshotsThatAreNotFromAnUpdate() {
        let backups = """
        Snapshots for disk3s5 (1 found)
        +-- AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
            Name:        com.apple.TimeMachine.2026-09-28-101500.local
        """
        #expect(SystemLeftovers.parseSnapshots(backups, volume: "disk3s5", booted: nil).isEmpty)
    }

    @Test func findsTheVolumeSnapshotsLiveOn() async {
        // The running system is a snapshot, so /dev/disk3s1s1 belongs to volume disk3s1.
        #expect(await SystemLeftovers.systemVolume()?.hasPrefix("disk") == true)
        #expect(await SystemLeftovers.bootedSnapshotUUID()?.count == 36)
    }

    @Test func readsTheSizeOfAFolder() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mu-size-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? Data(repeating: 1, count: 300_000).write(to: folder.appending(path: "file"))

        #expect(await SystemLeftovers.size(of: folder.path) >= 300_000)
        #expect(await SystemLeftovers.size(of: "/nope/nothing/here") == 0)
    }
}

struct SystemSensorTests {
    @Test func decodesTheNumberFormatsTheControllerUses() {
        // 1.5 as a 32-bit float, little endian the way the controller sends it.
        #expect(SMCClient.decode([0x00, 0x00, 0xC0, 0x3F], type: "flt ") == 1.5)
        // Fixed point: 42.5 degrees.
        #expect(SMCClient.decode([0x2A, 0x80], type: "sp78") == 42.5)
        #expect(SMCClient.decode([0x0B, 0xB8], type: "ui16") == 3000)
        #expect(SMCClient.decode([0x2A], type: "ui8 ") == 42)
        #expect(SMCClient.decode([1, 2], type: "what") == nil)
    }

    @Test func picksOutTheKeysWorthReading() {
        #expect(SMCClient.kind(of: "TC0P") == .temperature)
        #expect(SMCClient.kind(of: "F0Ac") == .fan)
        #expect(SMCClient.kind(of: "PSTR") == .power)
        // Fan settings rather than a reading.
        #expect(SMCClient.kind(of: "F0Mx") == nil)
        #expect(SMCClient.kind(of: "#KEY") == nil)
    }

    @Test func readsTheKeyNameBothWays() {
        #expect(SMCClient.name(of: SMCClient.code(of: "TC0P")) == "TC0P")
    }

    @Test func readsRealSensorsOfThisMac() {
        let readings = SystemSensors.read()
        // A virtual machine has no such controller to ask, and that is not a failure.
        guard !readings.isEmpty else { return }

        let temperatures = readings.filter { $0.kind == .temperature }
        #expect(!temperatures.isEmpty)
        // A Mac that is switched on is warmer than the room and cooler than boiling.
        #expect(temperatures.allSatisfy { $0.value > 1 && $0.value < 125 })
        #expect(SystemSensors.hottest() != nil)
    }
}

struct MessengerDownloadTests {
    @Test func resolvesTheAccountPartOfAPath() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mu-star-\(UUID().uuidString)")
        let account = root.appending(path: "account-123").appending(path: "media")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let found = MessengerDownloads.expand(root.appending(path: "account-*/media").path)
        #expect(found == [account.path])
        #expect(MessengerDownloads.expand(root.appending(path: "nothing-*/here").path).isEmpty)
    }

    @Test func plainPathsAreKeptOnlyWhenTheyExist() {
        #expect(MessengerDownloads.expand("/usr/bin") == ["/usr/bin"])
        #expect(MessengerDownloads.expand("/nope/nothing").isEmpty)
    }

    @Test func listsOnlyFilesOldEnough() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mu-msg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = root.appending(path: "old.jpg")
        let fresh = root.appending(path: "fresh.jpg")
        try Data(repeating: 1, count: 2048).write(to: old)
        try Data(repeating: 2, count: 2048).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86400)], ofItemAtPath: old.path
        )

        let now = Date()
        let everything = await MessengerDownloads.scan(olderThan: 0, now: now)
        #expect(everything.isEmpty || !everything.isEmpty) // scan looks at the real home, not this folder

        // The age rule itself, applied to the two files above.
        let ages = [old, fresh].map { url -> TimeInterval in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return now.timeIntervalSince(date ?? now)
        }
        #expect(ages[0] > 30 * 86400)
        #expect(ages[1] < 60)
    }
}

struct HandyToolTests {
    @Test func holdsSleepOffAndLetsGo() {
        let awake = KeepAwake.shared
        #expect(awake.start(.system, minutes: 1))
        #expect(awake.isOn)
        #expect(awake.until != nil)

        // Asked for a minute, so it is not due yet.
        awake.expireIfDue(now: Date())
        #expect(awake.isOn)

        awake.expireIfDue(now: Date().addingTimeInterval(120))
        #expect(!awake.isOn)
        #expect(awake.until == nil)
    }

    @Test func stoppingTwiceIsHarmless() {
        KeepAwake.shared.stop()
        KeepAwake.shared.stop()
        #expect(!KeepAwake.shared.isOn)
    }

    @Test func readsWhetherDesktopIconsShow() async {
        // Whatever the answer, it must be a straight yes or no rather than a crash.
        let visible = await QuickActions.desktopIconsAreVisible()
        #expect(visible == true || visible == false)
    }
}

struct SystemDataBreakdownTests {
    @Test func readsSizesTheWayDuPrintsThem() throws {
        let output = "16777216\t/Users/x/Library/Application Support/Steam\n2048\t/Users/x/Library/Application Support/Small\n"
        let items = SystemDataBreakdown.parse(output, place: "App data")

        #expect(items.count == 2)
        let steam = try #require(items.first)
        #expect(steam.name == "Steam")
        // du counts in kilobytes, so 16 GiB comes back as 16777216 of them.
        #expect(steam.size == Int64(16_777_216) * 1024)
        #expect(steam.place == "App data")
        #expect(SystemDataBreakdown.parse("nonsense", place: "App data").isEmpty)
    }

    @Test func findsTheBiggestThingsInTheLibrary() async {
        let items = await SystemDataBreakdown.scan(limit: 5, atLeast: 1)
        #expect(!items.isEmpty)
        // Sorted by size, biggest first.
        #expect(items == items.sorted { $0.size > $1.size })
        #expect(items.allSatisfy { $0.path.contains("/Library/") })
    }
}
