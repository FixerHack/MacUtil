@testable import CleanerCore
import Foundation
import Testing

struct VolumeInfoTests {
    @Test func usedCapacityIsTotalMinusAvailable() {
        let volume = VolumeInfo(name: "Test", totalCapacity: 1000, availableCapacity: 250)
        #expect(volume.usedCapacity == 750)
        #expect(volume.usedFraction == 0.75)
    }

    @Test func emptyVolumeDoesNotDivideByZero() {
        let volume = VolumeInfo(name: "Empty", totalCapacity: 0, availableCapacity: 0)
        #expect(volume.usedFraction == 0)
    }

    @Test func startupDiskHasCapacity() throws {
        let volume = try VolumeInfo.forVolume()
        #expect(volume.totalCapacity > 0)
        #expect(volume.availableCapacity <= volume.totalCapacity)
    }
}

struct FullDiskAccessTests {
    @Test func missingProbeFilesMeanUnknown() throws {
        let emptyHome = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        #expect(FullDiskAccess.status(home: emptyHome) == .unknown)
    }

    @Test func readableProbeMeansGranted() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let mail = home.appending(path: "Library/Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(FullDiskAccess.status(home: home) == .granted)
    }
}
