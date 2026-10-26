import Foundation

/// A record macOS keeps of something installed from a `.pkg`.
public struct InstallerReceipt: Sendable, Identifiable, Hashable {
    public let packageID: String
    public let version: String
    /// The volume it was installed on, usually "/".
    public let volume: String
    /// Where under the volume its files were laid down.
    public let location: String
    public let installedAt: Date?

    public var id: String { packageID }

    /// Apple's own packages describe parts of macOS, so they are shown and never offered.
    public var isApple: Bool {
        packageID.hasPrefix("com.apple.")
    }

    /// The folder its relative paths hang from.
    var root: String {
        let joined = (volume as NSString).appendingPathComponent(location)
        return joined.hasSuffix("/") && joined.count > 1 ? String(joined.dropLast()) : joined
    }
}

/// Everything one receipt put on the disk.
public struct ReceiptContents: Sendable {
    public let receipt: InstallerReceipt
    /// Absolute paths of the files, those that are still there.
    public let files: [String]
    /// How many the receipt lists that are gone already.
    public let missing: Int
    public let size: Int64
}

/// Reads what `.pkg` installers left behind, from the receipts macOS keeps for them.
///
/// This is the one place on a Mac where an uninstall needs no guessing: the installer wrote
/// down every file it laid down, and `pkgutil` reads that list back. Everything else about
/// removing software — matching names, bundle identifiers, folders in the Library — is
/// inference next to this.
public enum InstallerReceipts {
    /// Paths no package may be allowed to take away, whatever its receipt says. A receipt can
    /// name a file that something else now depends on, and these are where that is fatal.
    static let untouchable = [
        "/System", "/usr/bin", "/usr/lib", "/usr/sbin", "/usr/share", "/bin", "/sbin",
        "/private/etc", "/private/var/db", "/Library/Apple",
    ]

    public static func list(includingApple: Bool = false) async -> [InstallerReceipt] {
        guard let output = await Command.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: .seconds(60))
        else { return [] }
        let ids = output.text.split(separator: "\n").map(String.init)
            .filter { includingApple || !$0.hasPrefix("com.apple.") }

        var receipts: [InstallerReceipt] = []
        for id in ids {
            guard let info = await Command.run("/usr/sbin/pkgutil", ["--pkg-info", id], timeout: .seconds(30)),
                  let receipt = parseInfo(info.text, packageID: id)
            else { continue }
            receipts.append(receipt)
        }
        return receipts.sorted { ($0.installedAt ?? .distantPast) > ($1.installedAt ?? .distantPast) }
    }

    static func parseInfo(_ text: String, packageID: String) -> InstallerReceipt? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard !fields.isEmpty else { return nil }
        return InstallerReceipt(
            packageID: fields["package-id"] ?? packageID,
            version: fields["version"] ?? "",
            volume: fields["volume"] ?? "/",
            location: fields["location"] ?? "",
            installedAt: fields["install-time"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        )
    }

    /// The files a receipt lists, as they stand now.
    ///
    /// Only files: the receipt also names the folders it created, and those are shared with
    /// everything else that ever used them.
    public static func contents(of receipt: InstallerReceipt) async -> ReceiptContents {
        guard let output = await Command.run(
            "/usr/sbin/pkgutil", ["--only-files", "--files", receipt.packageID], timeout: .seconds(120)
        ) else {
            return ReceiptContents(receipt: receipt, files: [], missing: 0, size: 0)
        }

        let fileManager = FileManager.default
        var present: [String] = []
        var missing = 0
        var size: Int64 = 0
        for relative in output.text.split(separator: "\n") {
            let path = (receipt.root as NSString).appendingPathComponent(String(relative))
            guard let values = try? URL(filePath: path).resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else {
                if !fileManager.fileExists(atPath: path) { missing += 1 }
                continue
            }
            present.append(path)
            size += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return ReceiptContents(receipt: receipt, files: present, missing: missing, size: size)
    }

    /// Paths this will not remove, however they got onto the list.
    public static func refused(in files: [String]) -> [String] {
        files.filter { path in
            untouchable.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    /// Removes a package's files and the receipt itself, with one password prompt.
    ///
    /// These files live outside the home folder, so this cannot go through the ordinary
    /// safety check; the refused list above stands in its place, and Apple's own packages
    /// are never accepted at all.
    public static func remove(_ contents: ReceiptContents) async -> AdminRunner.Output {
        guard !contents.receipt.isApple else {
            return AdminRunner.Output(succeeded: false, text: "an Apple package", wasCancelled: false)
        }
        let allowed = contents.files.filter { refused(in: [$0]).isEmpty }
        guard !allowed.isEmpty else {
            return AdminRunner.Output(succeeded: false, text: "nothing left to remove", wasCancelled: false)
        }
        let commands = allowed.map { "/bin/rm -f \(shellQuoted($0))" }
            + ["/usr/sbin/pkgutil --forget \(shellQuoted(contents.receipt.packageID))"]
        return await AdminRunner.run(
            commands,
            prompt: String(localized: "UniMacHub needs your password to remove what this installer put on your Mac.")
        )
    }

    /// Drops the record without touching a file, for when the software is long gone.
    public static func forget(_ receipt: InstallerReceipt) async -> AdminRunner.Output {
        await AdminRunner.run(
            ["/usr/sbin/pkgutil --forget \(shellQuoted(receipt.packageID))"],
            prompt: String(localized: "UniMacHub needs your password to forget this installer receipt.")
        )
    }

    /// Single quotes, with any quote of its own closed and reopened around an escape.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
