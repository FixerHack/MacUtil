import Foundation

/// A volume you can see in Finder, or one macOS keeps to itself.
public struct StorageVolume: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let fileSystem: String
    public let mountPoint: String?
    public let size: Int64
    public let used: Int64
    public let isEncrypted: Bool
    /// What macOS uses the volume for: System, Data, Preboot, Recovery, VM, Update…
    public let roles: [String]
    public let containerID: String?

    public var isMounted: Bool { mountPoint != nil }
    public var free: Int64 { max(0, size - used) }
    public var usedFraction: Double { size > 0 ? Double(used) / Double(size) : 0 }
    public var isStartup: Bool { mountPoint == "/" || mountPoint == "/System/Volumes/Data" }

    /// Volumes macOS runs from. MacUtil never offers to change these.
    public var isSystemOwned: Bool {
        isStartup || !roles.filter { ["System", "Data", "Preboot", "Recovery", "VM", "Update", "xART", "Hardware"].contains($0) }.isEmpty
    }
}

/// A slice of a physical disk: one partition of the partition map.
public struct StoragePartition: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    /// Partition type, such as `Apple_APFS`, `Apple_HFS`, `EFI`, `Microsoft Basic Data`.
    public let content: String
    public let size: Int64
    /// The APFS container this partition holds, when it holds one.
    public let containerID: String?
    public var volumes: [StorageVolume]

    public var isContainer: Bool { containerID != nil }
}

/// A physical disk, or a disk image pretending to be one.
public struct StorageDisk: Sendable, Identifiable, Hashable {
    public let id: String
    public let model: String
    public let size: Int64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isSolidState: Bool
    /// USB, Thunderbolt, Apple Fabric, Disk Image…
    public let bus: String
    /// What `diskutil` reports from the drive's own self-check.
    public let smart: String?
    /// GUID_partition_scheme, FDisk_partition_scheme (MBR), or none.
    public let partitionScheme: String?
    public var partitions: [StoragePartition]

    public var isDiskImage: Bool { bus == "Disk Image" }
    public var isStartupDisk: Bool { partitions.contains { $0.volumes.contains(where: \.isStartup) } }
    public var volumes: [StorageVolume] { partitions.flatMap(\.volumes) }
    public var freeSpace: Int64 { max(0, size - partitions.reduce(0) { $0 + $1.size }) }
    public var healthIsGood: Bool { smart == nil || smart == "Verified" || smart == "Not Supported" }
}

/// Reads what is attached to the Mac, using `diskutil`'s own property lists.
public enum DiskInventory {
    public static func load() async -> [StorageDisk] {
        async let listing = plist(["list", "-plist"])
        async let apfs = plist(["apfs", "list", "-plist"])
        let (list, containers) = await (listing, apfs)
        guard let list else { return [] }

        let volumesByContainer = apfsVolumes(containers, mountPoints: mountPoints(list))
        // An APFS container is its own synthesized disk; this maps it back to the partition it lives on.
        var containerByStore: [String: String] = [:]
        for container in containers?["Containers"] as? [[String: Any]] ?? [] {
            guard let reference = container["ContainerReference"] as? String else { continue }
            for store in container["PhysicalStores"] as? [[String: Any]] ?? [] {
                if let id = store["DeviceIdentifier"] as? String { containerByStore[id] = reference }
            }
            if let store = container["DesignatedPhysicalStore"] as? String { containerByStore[store] = reference }
        }

        var disks: [StorageDisk] = []
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let id = entry["DeviceIdentifier"] as? String else { continue }
            // Skip the synthesized disks: their volumes are shown under the partition they sit on.
            if entry["APFSPhysicalStores"] != nil { continue }
            guard let info = await plist(["info", "-plist", id]) else { continue }

            var partitions: [StoragePartition] = []
            for part in entry["Partitions"] as? [[String: Any]] ?? [] {
                guard let partID = part["DeviceIdentifier"] as? String else { continue }
                let container = containerByStore[partID]
                var volumes = container.flatMap { volumesByContainer[$0] } ?? []
                if container == nil, part["VolumeName"] is String {
                    volumes = await plainVolume(id: partID, fallback: part)
                }
                partitions.append(StoragePartition(
                    id: partID,
                    name: part["VolumeName"] as? String,
                    content: part["Content"] as? String ?? "",
                    size: part["Size"] as? Int64 ?? 0,
                    containerID: container,
                    volumes: volumes
                ))
            }
            // A disk formatted without a partition map holds one volume directly.
            if partitions.isEmpty {
                let container = containerByStore[id]
                var volumes = container.flatMap { volumesByContainer[$0] } ?? []
                if volumes.isEmpty { volumes = await plainVolume(id: id, fallback: entry) }
                if let volume = volumes.first {
                    partitions.append(StoragePartition(
                        id: id, name: volume.name, content: entry["Content"] as? String ?? "",
                        size: entry["Size"] as? Int64 ?? volume.size, containerID: container, volumes: volumes
                    ))
                }
            }

            disks.append(StorageDisk(
                id: id,
                model: (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                size: entry["Size"] as? Int64 ?? 0,
                isInternal: info["Internal"] as? Bool ?? false,
                isRemovable: (info["Removable"] as? Bool ?? false) || (info["RemovableMedia"] as? Bool ?? false),
                isSolidState: info["SolidState"] as? Bool ?? false,
                bus: info["BusProtocol"] as? String ?? "",
                smart: (info["SMARTStatus"] as? String).flatMap { $0 == "Not Supported" ? nil : $0 },
                partitionScheme: info["Content"] as? String,
                partitions: partitions
            ))
        }
        return disks
    }

    /// Where each volume is mounted. `diskutil apfs list` does not say, but `diskutil list` does.
    /// A macOS system volume is mounted through a snapshot, so disk3s1 is served by disk3s1s1.
    static func mountPoints(_ list: [String: Any]) -> [String: String] {
        var points: [String: String] = [:]
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            let groups = [entry] + (entry["Partitions"] as? [[String: Any]] ?? [])
                + (entry["APFSVolumes"] as? [[String: Any]] ?? [])
            for item in groups {
                guard let id = item["DeviceIdentifier"] as? String,
                      let point = item["MountPoint"] as? String, !point.isEmpty
                else { continue }
                points[id] = point
            }
        }
        return points
    }

    static func mountPoint(of id: String, in points: [String: String]) -> String? {
        if let direct = points[id] { return direct }
        // The system volume's snapshot: disk3s1 is mounted as disk3s1s1.
        return points.first { $0.key.hasPrefix(id + "s") }?.value
    }

    /// APFS volumes of every container, keyed by container reference.
    static func apfsVolumes(_ containers: [String: Any]?, mountPoints points: [String: String] = [:]) -> [String: [StorageVolume]] {
        var result: [String: [StorageVolume]] = [:]
        for container in containers?["Containers"] as? [[String: Any]] ?? [] {
            guard let reference = container["ContainerReference"] as? String else { continue }
            result[reference] = (container["Volumes"] as? [[String: Any]] ?? []).map { volume in
                StorageVolume(
                    id: volume["DeviceIdentifier"] as? String ?? "",
                    name: volume["Name"] as? String ?? "",
                    fileSystem: "APFS",
                    mountPoint: mountPoint(of: volume["DeviceIdentifier"] as? String ?? "", in: points),
                    // An APFS volume may grow to the whole container, so that is its size.
                    size: container["CapacityCeiling"] as? Int64 ?? 0,
                    used: volume["CapacityInUse"] as? Int64 ?? 0,
                    isEncrypted: volume["Encryption"] as? Bool ?? volume["FileVault"] as? Bool ?? false,
                    roles: volume["Roles"] as? [String] ?? [],
                    containerID: reference
                )
            }
        }
        return result
    }

    /// HFS+, ExFAT, FAT and NTFS, where the partition is the volume. `diskutil list` does not
    /// say which file system it really is or how full it is, so the volume is asked directly.
    static func plainVolume(id: String, fallback: [String: Any]) async -> [StorageVolume] {
        let info = await plist(["info", "-plist", id]) ?? fallback
        guard let name = (info["VolumeName"] as? String) ?? (fallback["VolumeName"] as? String) else { return [] }
        let size = info["Size"] as? Int64 ?? fallback["Size"] as? Int64 ?? 0
        let mountPoint = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A mounted volume knows its own free space better than diskutil does.
        var free = info["FreeSpace"] as? Int64 ?? 0
        if let mountPoint,
           let values = try? URL(filePath: mountPoint).resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity
        {
            free = Int64(available)
        }
        let fileSystem = (info["FilesystemName"] as? String)
            ?? (info["FilesystemType"] as? String)
            ?? fileSystemName(info["Content"] as? String ?? "")
        return [StorageVolume(
            id: id, name: name, fileSystem: fileSystem, mountPoint: mountPoint,
            size: size, used: max(0, size - free),
            isEncrypted: info["Encryption"] as? Bool ?? false, roles: [], containerID: nil
        )]
    }

    /// A file system name people recognise, instead of the partition type code.
    public static func fileSystemName(_ content: String) -> String {
        switch content {
        case "Apple_HFS": "Mac OS Extended"
        case "Apple_APFS": "APFS"
        case "Microsoft Basic Data", "Windows_NTFS": "ExFAT, FAT or NTFS"
        case "Windows_FAT_32": "FAT32"
        case "EFI": "EFI"
        case "Apple_Boot": "Recovery"
        default: content
        }
    }

    static func plist(_ arguments: [String]) async -> [String: Any]? {
        guard let output = await Command.run("/usr/sbin/diskutil", arguments, timeout: .seconds(60)),
              let data = output.text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }
}
