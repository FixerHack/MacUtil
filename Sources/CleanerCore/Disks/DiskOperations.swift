import Foundation

/// File systems MacUtil can format a volume with.
public enum DiskFormat: String, Sendable, CaseIterable, Identifiable {
    case apfs = "APFS"
    case apfsCaseSensitive = "APFSX"
    case macOSExtended = "JHFS+"
    case exFAT = "ExFAT"
    case fat32 = "MS-DOS FAT32"

    public var id: String { rawValue }

    /// What the format is good for, in plain words.
    public var summary: String {
        switch self {
        case .apfs: String(localized: "Best for Macs and SSDs. Snapshots, cloning, encryption.")
        case .apfsCaseSensitive: String(localized: "APFS that tells Readme and README apart. Only for development.")
        case .macOSExtended: String(localized: "For older Macs and hard drives.")
        case .exFAT: String(localized: "Read and write on Mac, Windows and cameras. No permissions.")
        case .fat32: String(localized: "Works everywhere, but no file larger than 4 GB.")
        }
    }
}

/// Changes to disks and volumes, all through `diskutil`.
///
/// Every call refuses to touch the volumes macOS runs from, and asks for an administrator
/// password only when the plain command was not allowed to do the work.
public enum DiskOperations {
    public struct Outcome: Sendable {
        public let succeeded: Bool
        public let output: String
        public let wasCancelled: Bool
        /// The command that ran, so the interface can show it before and after.
        public let command: String

        public static func refused(_ reason: String) -> Outcome {
            Outcome(succeeded: false, output: reason, wasCancelled: false, command: "")
        }
    }

    // MARK: - Reading and mounting

    public static func mount(_ volume: StorageVolume) async -> Outcome {
        await run(["mount", volume.id], prompt: mountPrompt(volume))
    }

    public static func unmount(_ volume: StorageVolume, force: Bool = false) async -> Outcome {
        guard !volume.isSystemOwned else { return .refused(systemVolumeReason(volume)) }
        return await run(["unmount"] + (force ? ["force"] : []) + [volume.id], prompt: mountPrompt(volume))
    }

    public static func eject(_ disk: StorageDisk) async -> Outcome {
        guard !disk.isStartupDisk else { return .refused(startupDiskReason(disk)) }
        return await run(["eject", disk.id], prompt: String(localized: "MacUtil needs your password to eject this disk."))
    }

    /// Checks the file system without changing anything.
    public static func verify(_ volume: StorageVolume) async -> Outcome {
        await run(["verifyVolume", volume.id], prompt: firstAidPrompt, timeout: .seconds(900))
    }

    /// Repairs the file system. The volume is unmounted while this runs.
    public static func repair(_ volume: StorageVolume) async -> Outcome {
        guard !volume.isStartup else {
            return .refused(String(
                localized: "The startup volume can only be repaired from Recovery. Restart holding the power button, then open Disk Utility there."
            ))
        }
        return await run(["repairVolume", volume.id], prompt: firstAidPrompt, timeout: .seconds(1800))
    }

    // MARK: - Changing volumes

    public static func rename(_ volume: StorageVolume, to name: String) async -> Outcome {
        guard !volume.isSystemOwned else { return .refused(systemVolumeReason(volume)) }
        guard isValidName(name) else { return .refused(invalidNameReason) }
        return await run(["rename", volume.id, name], prompt: String(
            localized: "MacUtil needs your password to rename this volume."
        ))
    }

    /// File systems this volume can be erased to. A volume inside an APFS container stays
    /// APFS; only a whole partition can change file system.
    public static func formats(for volume: StorageVolume) -> [DiskFormat] {
        volume.containerID != nil ? [.apfs, .apfsCaseSensitive] : DiskFormat.allCases
    }

    /// Erases a volume and puts a fresh file system on it. Everything on it is gone.
    public static func erase(_ volume: StorageVolume, format: DiskFormat, name: String) async -> Outcome {
        guard !volume.isSystemOwned else { return .refused(systemVolumeReason(volume)) }
        guard isValidName(name) else { return .refused(invalidNameReason) }
        guard formats(for: volume).contains(format) else {
            return .refused(String(
                localized: "A volume inside an APFS container stays APFS. To use another file system, erase the whole disk."
            ))
        }
        return await run(
            ["eraseVolume", format.rawValue, name, volume.id],
            prompt: String(localized: "MacUtil needs your password to erase this volume."),
            timeout: .seconds(900)
        )
    }

    /// Adds a volume to an APFS container. It shares the container's free space,
    /// so nothing has to be resized. A quota caps how much it may take.
    public static func addVolume(container: String, name: String, quota: Int64? = nil) async -> Outcome {
        guard isValidName(name) else { return .refused(invalidNameReason) }
        var arguments = ["apfs", "addVolume", container, "APFS", name]
        if let quota { arguments += ["-quota", "\(quota)"] }
        return await run(arguments, prompt: String(
            localized: "MacUtil needs your password to add a volume to this container."
        ))
    }

    public static func deleteVolume(_ volume: StorageVolume) async -> Outcome {
        guard !volume.isSystemOwned else { return .refused(systemVolumeReason(volume)) }
        return await run(["apfs", "deleteVolume", volume.id], prompt: String(
            localized: "MacUtil needs your password to delete this volume."
        ))
    }

    /// Caps how much of the container a volume may use, or lifts the cap with nil.
    public static func setQuota(_ quota: Int64?, for volume: StorageVolume) async -> Outcome {
        guard !volume.isSystemOwned else { return .refused(systemVolumeReason(volume)) }
        return await run(
            ["apfs", "resizeVolume", volume.id, quota.map(String.init) ?? "none"],
            prompt: String(localized: "MacUtil needs your password to change this volume's limit.")
        )
    }

    // MARK: - Changing partitions

    /// Grows or shrinks an APFS container. macOS moves the data itself; the container
    /// cannot shrink below what its volumes already hold.
    public static func resizeContainer(_ container: String, to size: Int64, startupDisk: Bool) async -> Outcome {
        guard !startupDisk else {
            return .refused(String(
                localized: "MacUtil does not resize the disk macOS runs from. Do that from Recovery, with a backup at hand."
            ))
        }
        return await run(
            ["apfs", "resizeContainer", container, "\(size)"],
            prompt: String(localized: "MacUtil needs your password to resize this container."),
            timeout: .seconds(3600)
        )
    }

    /// Lays out a whole disk from scratch. Everything on the disk is gone.
    public static func partition(
        _ disk: StorageDisk, scheme: PartitionScheme, parts: [(name: String, format: DiskFormat, size: Int64?)]
    ) async -> Outcome {
        guard !disk.isStartupDisk else { return .refused(startupDiskReason(disk)) }
        guard !parts.isEmpty else { return .refused(String(localized: "Describe at least one partition.")) }
        guard parts.allSatisfy({ isValidName($0.name) }) else { return .refused(invalidNameReason) }

        var arguments = ["partitionDisk", disk.id, "\(parts.count)", scheme.rawValue]
        for part in parts {
            arguments += [part.format.rawValue, part.name, part.size.map { "\($0)B" } ?? "R"]
        }
        return await run(
            arguments,
            prompt: String(localized: "MacUtil needs your password to repartition this disk."),
            timeout: .seconds(3600)
        )
    }

    public enum PartitionScheme: String, Sendable, CaseIterable, Identifiable {
        /// What every Mac uses.
        case guid = "GPT"
        /// For old devices that expect a PC layout.
        case masterBootRecord = "MBR"

        public var id: String { rawValue }
    }

    // MARK: - Running the command

    /// Runs `diskutil`, and only asks for a password when it was turned away.
    static func run(_ arguments: [String], prompt: String, timeout: Duration = .seconds(180)) async -> Outcome {
        let command = "diskutil " + arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let plain = await Command.run("/usr/sbin/diskutil", arguments, timeout: timeout)
        if plain?.status == 0 {
            return Outcome(succeeded: true, output: plain?.text ?? "", wasCancelled: false, command: command)
        }
        guard needsAdministrator(plain?.text ?? "") else {
            return Outcome(succeeded: false, output: plain?.text ?? "", wasCancelled: false, command: command)
        }
        let escaped = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let elevated = await AdminRunner.run(["/usr/sbin/diskutil " + escaped], prompt: prompt)
        return Outcome(
            succeeded: elevated.succeeded, output: elevated.text,
            wasCancelled: elevated.wasCancelled, command: command
        )
    }

    static func needsAdministrator(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return ["permission denied", "must be root", "requires root", "operation not permitted", "not permitted"]
            .contains { lowercased.contains($0) }
    }

    /// Volume names live in the file system, so keep them short and free of separators.
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 127 && !trimmed.contains("/") && !trimmed.contains(":")
    }

    private static let invalidNameReason = String(
        localized: "Pick a name of up to 127 characters, without a slash or a colon."
    )
    private static let firstAidPrompt = String(localized: "MacUtil needs your password to check this volume.")

    private static func mountPrompt(_ volume: StorageVolume) -> String {
        String(localized: "MacUtil needs your password to mount or unmount \(volume.name).")
    }

    private static func systemVolumeReason(_ volume: StorageVolume) -> String {
        String(localized: "\(volume.name) is part of macOS, so MacUtil leaves it alone.")
    }

    private static func startupDiskReason(_ disk: StorageDisk) -> String {
        String(localized: "This is the disk macOS runs from, so MacUtil leaves it alone.")
    }
}
