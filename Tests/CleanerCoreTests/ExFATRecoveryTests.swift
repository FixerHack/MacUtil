@testable import CleanerCore
import CryptoKit
import Foundation
import Testing

/// Everything here happens on a disk image the test makes, never on a real card.
@Suite(.serialized) struct ExFATRecoveryTests {
    private func photo(seed: UInt8, bytes: Int) -> Data {
        var data = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0x00])
        data.append(Data((0 ..< bytes).map { UInt8(($0 &* Int(seed) &+ 11) % 251) }))
        data.append(Data([0xFF, 0xD9]))
        return data
    }

    @Test func findsDeletedFilesByTheirRealNames() async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "mu-exfat-\(UUID().uuidString).dmg")
        let output = FileManager.default.temporaryDirectory.appending(path: "mu-exfat-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: image)
            try? FileManager.default.removeItem(at: output)
        }

        let created = await DiskImages.create(
            at: image, volumeName: "MUCARD", size: 120 * 1024 * 1024, format: .exFAT
        )
        try #require(created.succeeded)
        let (outcome, attached) = await DiskImages.attach(image)
        try #require(outcome.succeeded)
        let device = try #require(attached?.device)
        let mountPoint = try #require(attached?.mountPoint)
        defer { Task { _ = await DiskImages.detach(device, force: true) } }

        // A card as a camera leaves it: a folder with photos in it.
        let folder = URL(filePath: mountPoint).appending(path: "DCIM")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = photo(seed: 31, bytes: 300_000)
        let second = photo(seed: 17, bytes: 900_000)
        try first.write(to: folder.appending(path: "DSC_0001.JPG"))
        try second.write(to: folder.appending(path: "Відпустка.jpg"))
        try FileManager.default.removeItem(at: folder.appending(path: "DSC_0001.JPG"))
        try FileManager.default.removeItem(at: folder.appending(path: "Відпустка.jpg"))

        // Unmounted, so nothing writes to it while it is read.
        _ = await DiskOperations.run(["unmount", device], prompt: "")
        let raw = "/dev/r" + (device as NSString).lastPathComponent

        let recovery = ExFATRecovery()
        let found = try recovery.scan(device: raw)
        #expect(found.count >= 2)

        let names = Set(found.map(\.name))
        #expect(names.contains("DSC_0001.JPG"))
        #expect(names.contains("Відпустка.jpg"))

        let record = try #require(found.filter { $0.name == "Відпустка.jpg" }.first)
        #expect(record.size == Int64(second.count))
        #expect(record.folder == "DCIM")
        #expect(record.isDeleted)
        #expect(record.modified != nil)

        let restored = try recovery.restore(record, device: raw, to: output)
        #expect(restored.lastPathComponent == "Відпустка.jpg")
        #expect(try Data(contentsOf: restored) == second)
        _ = await DiskImages.detach(device, force: true)
    }

    @Test func refusesADiskThatIsNotExFAT() async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "mu-hfs-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: image) }

        let created = await DiskImages.create(
            at: image, volumeName: "MUHFS", size: 60 * 1024 * 1024, format: .macOSExtended
        )
        try #require(created.succeeded)
        let (outcome, attached) = await DiskImages.attach(image)
        try #require(outcome.succeeded)
        let device = try #require(attached?.device)
        defer { Task { _ = await DiskImages.detach(device, force: true) } }

        let raw = "/dev/r" + (device as NSString).lastPathComponent
        #expect(throws: ExFATRecovery.Failure.notExFAT(raw)) {
            _ = try ExFATRecovery().scan(device: raw)
        }
        _ = await DiskImages.detach(device, force: true)
    }

    @Test func leavesOutTheFilesMacOSLeavesBehind() {
        #expect(ExFATRecovery.isHousekeeping("._DSC_0001.JPG"))
        #expect(ExFATRecovery.isHousekeeping(".DS_Store"))
        #expect(ExFATRecovery.isHousekeeping(".Spotlight-V100"))
        #expect(!ExFATRecovery.isHousekeeping("DSC_0001.JPG"))
        #expect(!ExFATRecovery.isHousekeeping("Відпустка.jpg"))
    }

    @Test func readsDatesTheWayExFATWritesThem() throws {
        // 28 September 2026, 10:30:00
        let raw: UInt32 = (UInt32(46) << 25) | (UInt32(9) << 21) | (UInt32(28) << 16)
            | (UInt32(10) << 11) | (UInt32(30) << 5)
        let date = try #require(ExFATRecovery.dosDate(raw))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 28)
        #expect(parts.hour == 10)
        #expect(parts.minute == 30)
    }
}
