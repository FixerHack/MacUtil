import Foundation

/// Capacity of a mounted volume.
public struct VolumeInfo: Sendable, Equatable {
    public let name: String
    public let totalCapacity: Int64
    /// Free space including purgeable data (local snapshots, evictable iCloud files),
    /// which is the number Finder shows.
    public let availableCapacity: Int64

    public init(name: String, totalCapacity: Int64, availableCapacity: Int64) {
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    public var usedCapacity: Int64 {
        max(totalCapacity - availableCapacity, 0)
    }

    public var usedFraction: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0
    }

    /// The volume that contains `url`. Defaults to the startup disk.
    public static func forVolume(containing url: URL = URL(filePath: "/")) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeInfo(
            name: values.volumeLocalizedName ?? url.lastPathComponent,
            totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
            availableCapacity: available
        )
    }
}
