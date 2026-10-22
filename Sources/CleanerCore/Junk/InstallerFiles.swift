import Foundation

/// A disk image or package left over from installing something.
public struct InstallerFile: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let size: Int64
    public let modified: Date?
    /// The installed app this installer appears to have delivered, if one was found.
    public let installedApp: String?

    public var id: String { path }

    /// The app is already in place, so the installer has done its job.
    public var isSpent: Bool { installedApp != nil }
}

/// Finds installers people download, run once and never think about again.
///
/// A `.dmg` or `.pkg` is only a delivery wrapper: once the app is in Applications the
/// wrapper is dead weight, and these are among the largest files in a Downloads folder.
/// Whether the app actually arrived is checked rather than assumed, because an installer
/// for something not installed may still be wanted.
public enum InstallerFiles {
    /// Where downloads pile up. Relative to the home folder.
    static let places = ["Downloads", "Desktop", "Documents"]

    /// Only wrappers whose whole purpose is installing. `.zip` is deliberately absent:
    /// it carries anything at all, so it cannot be called an installer by its name.
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        apps: [AppRecord]? = nil,
        protected: ProtectedPaths = .current()
    ) async -> [InstallerFile] {
        let installed = if let apps { apps } else { await AppCatalog.scan() }
        let names = installed.map { (key: key(for: $0.name), name: $0.name) }.filter { !$0.key.isEmpty }

        var found: [InstallerFile] = []
        for place in places {
            let directory = home.appending(path: place)
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where extensions.contains(url.pathExtension.lowercased()) {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                else { continue }
                found.append(InstallerFile(
                    path: url.path(percentEncoded: false),
                    name: url.lastPathComponent,
                    size: Int64(values.totalFileAllocatedSize ?? 0),
                    modified: values.contentModificationDate,
                    installedApp: match(url.deletingPathExtension().lastPathComponent, against: names)
                ))
            }
        }
        return found.filter { !protected.covers($0.path) }.sorted { $0.size > $1.size }
    }

    /// Reduces a name to letters and digits in lower case, so "Visual Studio Code" and
    /// "VSCode-darwin-arm64" can be compared at all.
    static func key(for name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The installed app whose name opens the installer's file name.
    ///
    /// Installers are named "App-1.2.3", "App_arm64", "AppInstaller" and worse, so the app
    /// name has to be a prefix rather than the whole thing. Short names like "Go" would match
    /// far too much, hence the length floor.
    static func match(_ fileName: String, against apps: [(key: String, name: String)]) -> String? {
        let stripped = key(for: fileName)
        guard stripped.count >= 3 else { return nil }
        return apps
            .filter { $0.key.count >= 4 && stripped.hasPrefix($0.key) }
            // The longest match wins: "slack" beats "sl" for "slack-4.35".
            .max { $0.key.count < $1.key.count }?
            .name
    }
}
