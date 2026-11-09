import Foundation

/// An encrypted volume kept in one file: carried on a stick, synced, backed up like any file.
///
/// macOS already does the hard part. An encrypted disk image is AES-256, opens with a
/// password and mounts like a disk, so a vault here is exactly that and nothing of our own:
/// the file opens in Disk Utility on any Mac, with or without UniMacHub. A sparse image is
/// used because it is one file that grows as it fills, where a sparse bundle is a folder.
public enum Vault {
    public static let fileExtension = "sparseimage"

    public enum Failure: Error, Sendable, Equatable {
        case wrongPassword
        case alreadyExists
        case failed(String)
    }

    /// Makes a new vault. The password goes to hdiutil on its standard input, never as an
    /// argument, so it does not show up in the process list.
    public static func create(
        at url: URL, volumeName: String, size: Int64, password: String
    ) async -> Result<URL, Failure> {
        let file = url.pathExtension == fileExtension ? url : url.appendingPathExtension(fileExtension)
        guard !FileManager.default.fileExists(atPath: file.path) else { return .failure(.alreadyExists) }
        let blocks = max(1, size / 512)
        let output = await Command.run("/usr/bin/hdiutil", [
            "create", "-size", "\(blocks)b", "-fs", "APFS", "-volname", volumeName,
            "-encryption", "AES-256", "-stdinpass", "-type", "SPARSE", file.path,
        ], timeout: .seconds(600), input: passphrase(password))
        guard let output, output.status == 0 else {
            return .failure(.failed(output?.text ?? ""))
        }
        return .success(file)
    }

    /// Opens a vault and says where it is mounted. It shows in the Finder like any disk.
    ///
    /// The password is tried first on its own, without attaching anything. hdiutil words a
    /// wrong password in the Mac's language, and only says it by number when verbose — and a
    /// verbose attach that succeeds leaves its helper holding the output open, so the call
    /// would never return. Checking with `imageinfo` gives the number and mounts nothing.
    public static func open(_ path: String, password: String) async -> Result<String, Failure> {
        let check = await Command.run(
            "/usr/bin/hdiutil", ["imageinfo", path, "-stdinpass", "-verbose"],
            timeout: .seconds(60), input: passphrase(password)
        )
        guard let check, check.status == 0 else {
            let text = check?.text ?? ""
            return .failure(isWrongPassword(text) ? .wrongPassword : .failed(text))
        }
        // The password is right by now, so a refusal here is the disk system being busy —
        // "no mountable file systems" straight after another image came or went. Once more,
        // a moment later, settles it; a second refusal is real.
        var attempt = await attach(path, password: password)
        if attempt?.status != 0 {
            try? await Task.sleep(for: .seconds(1))
            attempt = await attach(path, password: password)
        }
        guard let output = attempt, output.status == 0 else {
            let text = attempt?.text ?? ""
            return .failure(isWrongPassword(text) ? .wrongPassword : .failed(text))
        }
        guard let mountPoint = mountPoint(inAttachOutput: output.text) else {
            return .failure(.failed(output.text))
        }
        return .success(mountPoint)
    }

    private static func attach(_ path: String, password: String) async -> Command.Output? {
        await Command.run(
            "/usr/bin/hdiutil", ["attach", path, "-stdinpass", "-plist"],
            timeout: .seconds(120), input: passphrase(password)
        )
    }

    /// Closes a vault. Forcing it closes even when an app has a file open inside, which is
    /// what locking on sleep or on a vanished drive needs; a plain close asks politely.
    @discardableResult
    public static func close(_ path: String, force: Bool = false) async -> Bool {
        guard let device = await attached()[standardized(path)]?.device else { return true }
        let output = await Command.run(
            "/usr/bin/hdiutil", ["detach", device] + (force ? ["-force"] : []), timeout: .seconds(60)
        )
        return output?.status == 0
    }

    public static func changePassword(_ path: String, from old: String, to new: String) async -> Result<Void, Failure> {
        // Both passwords on standard input, each ended by a null byte, old one first.
        let output = await Command.run("/usr/bin/hdiutil", [
            "chpass", path, "-oldstdinpass", "-newstdinpass", "-verbose",
        ], timeout: .seconds(60), input: passphrase(old) + passphrase(new))
        guard let output, output.status == 0 else {
            let text = output?.text ?? ""
            return .failure(isWrongPassword(text) ? .wrongPassword : .failed(text))
        }
        return .success(())
    }

    /// Where an open vault is mounted, or nil while it is locked.
    public static func mountPoint(of path: String) async -> String? {
        await attached()[standardized(path)]?.mountPoint
    }

    // MARK: - Reading hdiutil

    struct Attachment: Equatable {
        let device: String
        let mountPoint: String?
    }

    /// Every attached image, by the path of its file.
    static func attached() async -> [String: Attachment] {
        guard let output = await Command.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: .seconds(30)),
              output.status == 0
        else { return [:] }
        return parseInfo(output.text)
    }

    static func parseInfo(_ text: String) -> [String: Attachment] {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [:] }
        var result: [String: Attachment] = [:]
        for image in images {
            guard let path = image["image-path"] as? String,
                  let entities = image["system-entities"] as? [[String: Any]]
            else { continue }
            let mounted = entities.first { $0["mount-point"] is String }
            // The whole disk is the shortest device name; detaching it takes every volume.
            guard let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count })
            else { continue }
            result[standardized(path)] = Attachment(device: device, mountPoint: mounted?["mount-point"] as? String)
        }
        return result
    }

    static func mountPoint(inAttachOutput text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    /// Error 80 is EAUTH. Verbose hdiutil reports it by number, whatever the Mac's language.
    static func isWrongPassword(_ text: String) -> Bool {
        text.contains("result: 80") || text.contains("returned 80")
    }

    static func passphrase(_ password: String) -> Data {
        Data(password.utf8) + Data([0])
    }

    /// Paths compared as the system writes them: /var and /private/var are one place.
    static func standardized(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
