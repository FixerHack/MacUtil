import Foundation

/// macOS's own Dock: what is pinned in it, and hiding it while UniMacHub's Dock is on.
///
/// The system Dock cannot be removed: its process also runs Mission Control, ⌘Tab and the
/// desktop switching, and lives on the sealed system volume. It can be told to hide itself,
/// though: automatic hiding with a delay of a thousand seconds means it never comes up. Before
/// that is done, the two settings involved are written down exactly as they were, so turning
/// UniMacHub's Dock off, or quitting, puts them back, including "not set at all".
public enum SystemDock {
    public static let domain = "com.apple.dock"

    /// The settings UniMacHub changes, as they were. Nil means the key was not there.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var autohide: Bool?
        public var delay: Double?

        public init(autohide: Bool?, delay: Double?) {
            self.autohide = autohide
            self.delay = delay
        }
    }

    /// A delay so long the system Dock never comes up.
    public static let hiddenDelay: Double = 1000

    /// Where the snapshot is kept, so a crash or a forced quit can still be undone on the
    /// next launch.
    public static var snapshotFile: URL { AppPaths.file("system-dock.json") }

    public static func readSnapshot() -> Snapshot {
        let defaults = UserDefaults(suiteName: domain)
        return Snapshot(
            autohide: defaults?.object(forKey: "autohide") as? Bool,
            delay: (defaults?.object(forKey: "autohide-delay") as? NSNumber)?.doubleValue
        )
    }

    /// Whether the system Dock is hidden the way UniMacHub hides it.
    public static func isHiddenByUs(_ snapshot: Snapshot) -> Bool {
        snapshot.autohide == true && (snapshot.delay ?? 0) >= hiddenDelay
    }

    /// The `defaults` commands that hide it.
    public static func hideCommands() -> [[String]] {
        [
            ["write", domain, "autohide", "-bool", "true"],
            ["write", domain, "autohide-delay", "-float", String(Int(hiddenDelay))],
        ]
    }

    /// The `defaults` commands that put a snapshot back, deleting what was not there.
    public static func restoreCommands(_ snapshot: Snapshot) -> [[String]] {
        var commands: [[String]] = []
        if let autohide = snapshot.autohide {
            commands.append(["write", domain, "autohide", "-bool", autohide ? "true" : "false"])
        } else {
            commands.append(["delete", domain, "autohide"])
        }
        if let delay = snapshot.delay {
            commands.append(["write", domain, "autohide-delay", "-float", String(delay)])
        } else {
            commands.append(["delete", domain, "autohide-delay"])
        }
        return commands
    }

    /// Runs `defaults` and restarts the Dock, waiting for both: this also runs while the app
    /// is quitting, when nothing asynchronous would get the chance to finish.
    public static func apply(_ commands: [[String]]) {
        for arguments in commands {
            run("/usr/bin/defaults", arguments)
        }
        run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: - Hiding and bringing back

    /// Hides the system Dock, writing down how it was first. Does nothing if it is already
    /// hidden by an earlier run, so the snapshot from before that run is kept.
    public static func hide() {
        let current = readSnapshot()
        if !FileManager.default.fileExists(atPath: snapshotFile.path) {
            // Hidden already with nothing written down: macOS's own defaults are the best guess.
            let before = isHiddenByUs(current) ? Snapshot(autohide: nil, delay: nil) : current
            try? FileManager.default.createDirectory(at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(before).write(to: snapshotFile, options: .atomic)
        }
        if !isHiddenByUs(current) { apply(hideCommands()) }
    }

    /// Puts the system Dock back the way it was, if UniMacHub hid it.
    public static func restore() {
        guard let data = try? Data(contentsOf: snapshotFile),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        apply(restoreCommands(snapshot))
        try? FileManager.default.removeItem(at: snapshotFile)
    }

    public static var isHidden: Bool {
        FileManager.default.fileExists(atPath: snapshotFile.path)
    }

    // MARK: - What is pinned

    /// The apps pinned in the system Dock, in order, from its preferences.
    public static func pinnedApps() -> [URL] {
        guard let defaults = UserDefaults(suiteName: domain),
              let apps = defaults.array(forKey: "persistent-apps")
        else { return [] }
        return pinnedApps(from: apps)
    }

    /// Reads the `persistent-apps` list: each entry's tile data names the app by file URL.
    public static func pinnedApps(from entries: [Any]) -> [URL] {
        entries.compactMap { entry in
            guard let tile = (entry as? [String: Any])?["tile-data"] as? [String: Any],
                  let file = tile["file-data"] as? [String: Any],
                  let string = file["_CFURLString"] as? String
            else { return nil }
            let url = string.hasPrefix("file://") ? URL(string: string) : URL(filePath: string)
            guard let url, url.pathExtension == "app" else { return nil }
            return URL(filePath: url.path(percentEncoded: false))
        }
    }
}

/// How the icons grow under the pointer, the way the system Dock's do.
public enum DockMagnification {
    /// How far from the pointer, in icon widths, an icon still grows.
    public static let reach: CGFloat = 2.6

    /// The scale for an icon whose centre is `distance` points along the Dock from the
    /// pointer: the full magnification right under it, easing to none at the edge of reach.
    public static func scale(distance: CGFloat, iconSize: CGFloat, magnification: CGFloat) -> CGFloat {
        guard magnification > 1, iconSize > 0 else { return 1 }
        let range = iconSize * reach
        let distance = abs(distance)
        guard distance < range else { return 1 }
        let closeness = cos(distance / range * .pi / 2)
        return 1 + (magnification - 1) * closeness * closeness
    }
}
