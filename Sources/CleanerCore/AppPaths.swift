import Foundation

/// Where the app keeps what it has to remember between launches.
///
/// The app was called MacUtil before it was called UniMacHub, and the folder it wrote to was
/// named after it. Renaming the app must not orphan a person's cleanup history, clipboard,
/// protected places and watched folders, so the old folder is moved across once, the first
/// time the new one is asked for.
public enum AppPaths {
    public static let folderName = "UniMacHub"
    static let previousFolderName = "MacUtil"

    /// The support folder, moved over from the old name if that is what is there.
    public static var support: URL {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")
        let current = library.appending(path: folderName)
        migrateIfNeeded(from: library.appending(path: previousFolderName), to: current)
        return current
    }

    public static func file(_ name: String) -> URL {
        support.appending(path: name)
    }

    /// Moves the old folder to the new name, once and only when nothing is in the way.
    ///
    /// If both exist, the old one is left alone: merging two sets of records is not something
    /// to attempt silently, and keeping them apart loses nothing.
    static func migrateIfNeeded(from old: URL, to new: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: new.path(percentEncoded: false)),
              fileManager.fileExists(atPath: old.path(percentEncoded: false))
        else { return }
        try? fileManager.createDirectory(
            at: new.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: old, to: new)
    }
}
