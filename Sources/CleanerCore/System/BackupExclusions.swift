import Foundation

/// Keeps rebuildable folders out of Time Machine.
///
/// A `node_modules` or `.build` folder is worth nothing in a backup: it is derived from the
/// source beside it and one command puts it back. Excluding it is gentler than deleting it —
/// the folder stays where the build tools expect it, and the backup stops carrying gigabytes
/// that would never be restored on purpose.
public enum BackupExclusions {
    public enum State: Sendable, Equatable {
        case included, excluded, unknown
    }

    public static func state(of path: String) async -> State {
        guard let output = await Command.run("/usr/bin/tmutil", ["isexcluded", path], timeout: .seconds(20))
        else { return .unknown }
        return parse(output.text)
    }

    static func parse(_ text: String) -> State {
        if text.contains("[Excluded]") { return .excluded }
        if text.contains("[Included]") { return .included }
        return .unknown
    }

    /// Excludes paths from backups, or puts them back in. No password needed for your own files.
    @discardableResult
    public static func setExcluded(_ excluded: Bool, paths: [String]) async -> Bool {
        guard !paths.isEmpty else { return true }
        let output = await Command.run(
            "/usr/bin/tmutil", [excluded ? "addexclusion" : "removeexclusion"] + paths, timeout: .seconds(120)
        )
        return output?.status == 0
    }
}
