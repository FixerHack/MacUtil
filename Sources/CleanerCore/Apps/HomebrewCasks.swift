import Foundation

/// An app Homebrew installed and still keeps track of.
public struct HomebrewCask: Sendable, Identifiable, Hashable {
    public let token: String
    public let version: String
    /// What the cask put in place: "Ghostty.app", "Prism Launcher.app", "ngrok".
    public let artifacts: [String]

    public var id: String { token }

    public var apps: [String] { artifacts.filter { $0.hasSuffix(".app") } }
}

/// Finds which apps belong to Homebrew, so they can be removed the way they were installed.
///
/// Deleting a cask's app by hand leaves Homebrew believing it is still there: `brew list`
/// shows it, `brew upgrade` tries to update what is gone. The cure is to let Homebrew do the
/// removing, which also runs the cask's own clean-up.
///
/// Nothing here asks Homebrew anything. The Caskroom says it all on disk — a folder per cask,
/// a folder per version inside it, and the installed artifacts by name — and reading that
/// takes no time, while `brew info` takes tens of seconds.
public enum HomebrewCasks {
    static let prefixes = ["/opt/homebrew", "/usr/local"]

    public static var brew: String? {
        prefixes.map { $0 + "/bin/brew" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { brew != nil }

    public static func installed() -> [HomebrewCask] {
        let fileManager = FileManager.default
        var casks: [HomebrewCask] = []
        for caskroom in prefixes.map({ $0 + "/Caskroom" }) {
            guard let tokens = try? fileManager.contentsOfDirectory(atPath: caskroom) else { continue }
            for token in tokens where !token.hasPrefix(".") {
                let folder = "\(caskroom)/\(token)"
                // Versions sit alongside a hidden .metadata folder.
                let versions = ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                guard let version = versions.last else { continue }
                let artifacts = ((try? fileManager.contentsOfDirectory(atPath: "\(folder)/\(version)")) ?? [])
                    .filter { !$0.hasPrefix(".") }
                casks.append(HomebrewCask(token: token, version: version, artifacts: artifacts))
            }
        }
        return casks.sorted { $0.token < $1.token }
    }

    /// The cask that put this app in place, by the name of its bundle.
    public static func cask(forAppAt path: String, in casks: [HomebrewCask]) -> HomebrewCask? {
        let name = (path as NSString).lastPathComponent
        return casks.first { $0.apps.contains(name) }
    }

    /// Hands the removal back to Homebrew.
    ///
    /// `zap` also runs the clean-up the cask itself describes — caches, preferences, launch
    /// agents — which is thorough and goes further than `uninstall` alone.
    public static func uninstall(_ cask: HomebrewCask, zap: Bool = false) async -> Command.Output? {
        guard let brew else { return nil }
        return await Command.run(
            brew,
            ["uninstall", "--cask"] + (zap ? ["--zap"] : []) + [cask.token],
            timeout: .seconds(600),
            // Homebrew must not stop to ask anything: there is nobody at the terminal, and
            // an auto-update here would turn a removal into a long wait.
            environment: [
                "NONINTERACTIVE": "1",
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
            ]
        )
    }
}
