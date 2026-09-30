import Foundation

/// Something macOS itself left behind, which only an administrator may remove.
public struct SystemLeftover: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        /// Installers macOS downloaded for an update.
        case downloadedUpdate
        /// Working files of an update that was prepared or installed.
        case stagedUpdate
        /// A copy of the system taken before an update, kept in case it has to go back.
        case updateSnapshot
        /// The file the Mac writes memory into before it sleeps deeply.
        case sleepImage
        /// Reports macOS keeps about crashes and performance.
        case diagnostics
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// What it is and what removing it means, in plain words.
    public let detail: String
    public let size: Int64
    /// Paths to remove, or empty for a snapshot, which is removed by its own command.
    public let paths: [String]
    /// Set for a snapshot: the volume it lives on and its identifier.
    public let snapshot: (volume: String, uuid: String)?

    public static func == (lhs: SystemLeftover, rhs: SystemLeftover) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Finds what macOS keeps after updating itself, and removes it on request.
///
/// Everything here belongs to root, so removing anything asks for a password. The copy of the
/// system the Mac is running from is never offered, and neither is the recovery system.
public enum SystemLeftovers {
    public static func scan() async -> [SystemLeftover] {
        async let downloads = downloadedUpdates()
        async let staged = stagedUpdates()
        async let snapshots = updateSnapshots()
        async let sleep = sleepImage()
        async let reports = diagnostics()
        return await (downloads + staged + snapshots + sleep + reports).sorted { $0.size > $1.size }
    }

    /// Update packages macOS downloaded. They are downloaded again if ever needed.
    static func downloadedUpdates() async -> [SystemLeftover] {
        let root = "/Library/Updates"
        let size = await size(of: root)
        guard size > 10_000_000 else { return [] }
        return [SystemLeftover(
            id: "updates.downloaded", kind: .downloadedUpdate,
            title: String(localized: "Downloaded update files"),
            detail: String(
                localized: "Installers macOS downloaded for a system update. If an update is still waiting, it is downloaded again before it installs."
            ),
            size: size, paths: [root], snapshot: nil
        )]
    }

    /// Scratch folders an update left in the place macOS prepares updates.
    static func stagedUpdates() async -> [SystemLeftover] {
        let root = "/System/Volumes/Update"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        // mnt1 is the running system mounted for the updater, and SFR is the recovery system.
        let leftovers = names.filter { $0.hasPrefix("softwareupdate.") || $0 == "lastOTA" }
        var items: [SystemLeftover] = []
        for name in leftovers {
            let path = "\(root)/\(name)"
            let size = await size(of: path)
            guard size > 10_000_000 else { continue }
            items.append(SystemLeftover(
                id: "updates.staged.\(name)", kind: .stagedUpdate,
                title: String(localized: "Leftovers of a prepared update"),
                detail: String(
                    localized: "Working files of an update that has already been installed or cancelled. macOS does not clean them up on its own."
                ),
                size: size, paths: [path], snapshot: nil
            ))
        }
        return items
    }

    /// Copies of the system taken around updates. The one the Mac booted from is left alone.
    static func updateSnapshots() async -> [SystemLeftover] {
        guard let volume = await systemVolume() else { return [] }
        let booted = await bootedSnapshotUUID()
        let output = await Command.run("/usr/sbin/diskutil", ["apfs", "listSnapshots", volume], timeout: .seconds(60))
        return parseSnapshots(output?.text ?? "", volume: volume, booted: booted)
    }

    static func parseSnapshots(_ text: String, volume: String, booted: String?) -> [SystemLeftover] {
        var items: [SystemLeftover] = []
        var uuid: String?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "+-| \t"))
            if trimmed.count == 36, trimmed.split(separator: "-").count == 5 {
                uuid = trimmed
            } else if trimmed.hasPrefix("Name:"), let uuid {
                let name = trimmed.replacingOccurrences(of: "Name:", with: "").trimmingCharacters(in: .whitespaces)
                // Only the ones an update left, and never the system that is running.
                if name.hasPrefix("com.apple.os.update-"), uuid != booted {
                    items.append(SystemLeftover(
                        id: "snapshot.\(uuid)", kind: .updateSnapshot,
                        title: String(localized: "Copy of the system from an earlier update"),
                        detail: String(
                            localized: "macOS takes this before it updates, so it can go back. Once the new version runs well, it only holds space. The copy this Mac is running from is never touched."
                        ),
                        size: 0, paths: [], snapshot: (volume, uuid)
                    ))
                }
            }
        }
        return items
    }

    /// The file the Mac writes its memory into before sleeping deeply. macOS makes a new one.
    static func sleepImage() async -> [SystemLeftover] {
        let path = "/private/var/vm/sleepimage"
        let size = await size(of: path)
        guard size > 100_000_000 else { return [] }
        return [SystemLeftover(
            id: "vm.sleepimage", kind: .sleepImage,
            title: String(localized: "Sleep image"),
            detail: String(
                localized: "What the Mac writes its memory into before it sleeps deeply. It is written again on the next deep sleep, so the space comes back."
            ),
            size: size, paths: [path], snapshot: nil
        )]
    }

    static func diagnostics() async -> [SystemLeftover] {
        let path = "/private/var/db/diagnostics"
        let size = await size(of: path)
        guard size > 200_000_000 else { return [] }
        return [SystemLeftover(
            id: "logs.diagnostics", kind: .diagnostics,
            title: String(localized: "System diagnostic reports"),
            detail: String(
                localized: "Records macOS keeps about crashes and performance. Useful when something is being investigated, and of no use otherwise."
            ),
            size: size, paths: [path], snapshot: nil
        )]
    }

    // MARK: - Removing

    /// Removes one leftover. Everything here belongs to root, so this asks for a password.
    public static func remove(_ leftover: SystemLeftover) async -> DiskOperations.Outcome {
        let command: String
        if let snapshot = leftover.snapshot {
            command = "/usr/sbin/diskutil apfs deleteSnapshot \(snapshot.volume) -uuid \(snapshot.uuid)"
        } else {
            guard !leftover.paths.isEmpty else { return .refused(String(localized: "There is nothing to remove.")) }
            // Delete what is inside, so the folders macOS expects stay where they are.
            command = leftover.paths
                .map { "/bin/rm -rf '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
                .joined(separator: " ; ")
        }
        let result = await AdminRunner.run([command], prompt: String(
            localized: "MacUtil needs your password to remove what macOS left after updating."
        ))
        return DiskOperations.Outcome(
            succeeded: result.succeeded, output: result.text, wasCancelled: result.wasCancelled, command: command
        )
    }

    // MARK: - Reading sizes

    /// The system volume, which is where update snapshots live.
    static func systemVolume() async -> String? {
        guard let output = await Command.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: .seconds(30)),
              let data = output.text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        // The running system is a snapshot of the volume, whose name drops the last part.
        guard let node = plist["DeviceNode"] as? String else { return nil }
        let identifier = (node as NSString).lastPathComponent
        guard let range = identifier.range(of: "s", options: .backwards), range.lowerBound > identifier.startIndex
        else { return identifier }
        return String(identifier[identifier.startIndex ..< range.lowerBound])
    }

    /// The snapshot the Mac booted from, which must stay.
    static func bootedSnapshotUUID() async -> String? {
        guard let output = await Command.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: .seconds(30)),
              let data = output.text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["DiskUUID"] as? String
    }

    static func size(of path: String) async -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        guard let output = await Command.run("/usr/bin/du", ["-sk", path], timeout: .seconds(120)),
              let kilobytes = Int64(output.text.split(separator: "\t").first?.trimmingCharacters(in: .whitespaces) ?? "")
        else { return 0 }
        return kilobytes * 1024
    }
}
