import Darwin
import Foundation

/// Last line of defense before anything is moved to the Trash or deleted.
///
/// A path is allowed only if it lies strictly inside one of the allowed roots
/// (the home folder and trash bins), is not one of the well-known folders
/// themselves, and is not inside protected data such as keychains, iCloud Drive,
/// mail, photo libraries or git repositories. Symlinks in the parent path are
/// resolved first, so a link cannot smuggle a system path past the checks.
public struct SafetyGuard: Sendable {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case blocked(String)
    }

    public let home: String
    private let allowedRoots: [String]
    private let protectedExact: Set<String>
    private let protectedPrefixes: [String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, extraAllowedRoots: [String] = []) {
        let home = Self.resolve(home.path(percentEncoded: false))
        self.home = home
        allowedRoots = [home] + extraAllowedRoots.map(Self.resolve) + Self.volumeTrashRoots()

        let wellKnownFolders = [
            "", "Library", "Library/Caches", "Library/Logs", "Library/Logs/DiagnosticReports",
            "Library/Application Support", "Library/Containers", "Library/Group Containers",
            "Library/Preferences", "Library/Saved Application State", "Library/Developer",
            "Library/Developer/Xcode", "Library/Developer/CoreSimulator", "Library/Mail",
            "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Public",
            "Applications", "Developer", ".Trash", ".cache", ".npm", ".gradle", ".cargo", "go",
        ]
        protectedExact = Set(wellKnownFolders.map { $0.isEmpty ? home : home + "/" + $0 })
            .union(["/Applications", "/Applications/Utilities", "/Library", "/Users"])

        let protectedData = [
            "Library/Keychains", "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail",
            "Library/Messages", "Library/Calendars", "Library/Application Support/AddressBook",
            "Library/Application Support/MobileSync", "Library/Group Containers/group.com.apple.notes",
            "Library/Accounts", "Library/Cookies", "Library/Safari", "Library/Photos",
            ".ssh", ".gnupg", ".aws", ".kube", ".docker",
        ]
        protectedPrefixes = protectedData.map { home + "/" + $0 } + [
            "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/Library/Apple",
        ]
    }

    public func check(_ path: String) -> Verdict {
        guard path.hasPrefix("/") else { return .blocked("not an absolute path") }
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else {
            return .blocked("relative components in path")
        }
        let resolved = Self.resolveParent(of: path)

        if components.contains(where: { $0 == ".git" || $0.lowercased().hasSuffix(".photoslibrary") }) {
            return .blocked("inside a git repository or photo library")
        }
        if protectedExact.contains(resolved) {
            return .blocked("a standard folder")
        }
        if let prefix = protectedPrefixes.first(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return .blocked("protected location \(prefix)")
        }
        guard allowedRoots.contains(where: { resolved.hasPrefix($0 + "/") }) else {
            return .blocked("outside the allowed locations")
        }
        if Self.isMountPoint(resolved) {
            return .blocked("a mounted volume")
        }
        return .allowed
    }

    /// `/Volumes/<name>/.Trashes/<uid>` for every mounted external volume.
    static func volumeTrashRoots() -> [String] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes
            .map { $0.path(percentEncoded: false) }
            .filter { $0.hasPrefix("/Volumes/") }
            .map { resolve(($0 as NSString).appendingPathComponent(".Trashes/\(getuid())")) }
    }

    /// `realpath` of the path, or the path itself (minus trailing slashes) if it does not exist.
    static func resolve(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if let real = realpath(trimmed, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        return trimmed
    }

    /// Resolves symlinks in the parent folder but not in the last component:
    /// trashing a symlink moves the link, never its target.
    static func resolveParent(of path: String) -> String {
        let nsPath = path as NSString
        let parent = nsPath.deletingLastPathComponent
        let name = nsPath.lastPathComponent
        let resolvedParent = resolve(parent)
        return resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
    }

    private static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return mountPoint == path
    }
}
