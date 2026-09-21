import Foundation

/// Detects whether the current process has Full Disk Access.
///
/// macOS has no public API for this, so we try to open files that TCC protects
/// and that exist on practically every Mac. The permission belongs to the
/// responsible process: for `mccli` that is the terminal app it runs in.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case denied
        /// None of the probe files exist, so we cannot tell.
        case unknown
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    public static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// Paths relative to the home folder that are readable only with Full Disk Access.
    static let probePaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/Bookmarks.plist",
        "Library/Safari",
        "Library/Mail",
    ]

    public static func status(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        var sawDenied = false
        for relativePath in probePaths {
            let path = home.appending(path: relativePath).path(percentEncoded: false)
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            if errno == EPERM || errno == EACCES {
                sawDenied = true
            }
        }
        return sawDenied ? .denied : .unknown
    }
}
