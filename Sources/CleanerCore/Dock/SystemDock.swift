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
        /// The edge. Written down since 0.10.4's second beta; a snapshot from before that
        /// leaves it alone when it is put back.
        public var orientation: String?
        public var recordsPlacement: Bool

        public init(autohide: Bool?, delay: Double?, orientation: String? = nil, recordsPlacement: Bool = false) {
            self.autohide = autohide
            self.delay = delay
            self.orientation = orientation
            self.recordsPlacement = recordsPlacement
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            autohide = try container.decodeIfPresent(Bool.self, forKey: .autohide)
            delay = try container.decodeIfPresent(Double.self, forKey: .delay)
            orientation = try container.decodeIfPresent(String.self, forKey: .orientation)
            recordsPlacement = try container.decodeIfPresent(Bool.self, forKey: .recordsPlacement) ?? false
        }
    }

    /// Mission Control always shows the system Dock, hidden or not, while UniMacHub's Dock
    /// steps out of it; so the system one is kept on the same edge, where the Dock belongs.

    /// A delay so long the system Dock never comes up.
    public static let hiddenDelay: Double = 1000

    /// Where the snapshot is kept, so a crash or a forced quit can still be undone on the
    /// next launch.
    public static var snapshotFile: URL { AppPaths.file("system-dock.json") }

    public static func readSnapshot() -> Snapshot {
        let defaults = UserDefaults(suiteName: domain)
        return Snapshot(
            autohide: defaults?.object(forKey: "autohide") as? Bool,
            delay: (defaults?.object(forKey: "autohide-delay") as? NSNumber)?.doubleValue,
            orientation: defaults?.string(forKey: "orientation"),
            recordsPlacement: true
        )
    }

    /// Whether the system Dock is hidden the way UniMacHub hides it.
    public static func isHiddenByUs(_ snapshot: Snapshot) -> Bool {
        snapshot.autohide == true && (snapshot.delay ?? 0) >= hiddenDelay
    }

    /// The `defaults` commands that hide it, on the edge UniMacHub's Dock is on.
    public static func hideCommands(edge: String = "bottom") -> [[String]] {
        [
            ["write", domain, "autohide", "-bool", "true"],
            ["write", domain, "autohide-delay", "-float", String(Int(hiddenDelay))],
            ["write", domain, "orientation", "-string", edge],
        ]
    }

    /// The `defaults` commands that put a snapshot back, deleting what was not there.
    public static func restoreCommands(_ snapshot: Snapshot) -> [[String]] {
        var commands: [[String]] = []
        func put(_ key: String, _ value: String?, type: String) {
            if let value {
                commands.append(["write", domain, key, type, value])
            } else {
                commands.append(["delete", domain, key])
            }
        }
        put("autohide", snapshot.autohide.map { $0 ? "true" : "false" }, type: "-bool")
        put("autohide-delay", snapshot.delay.map { String($0) }, type: "-float")
        if snapshot.recordsPlacement {
            put("orientation", snapshot.orientation, type: "-string")
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

    /// Hides the system Dock, writing down how it was first. A snapshot from an earlier run
    /// is kept, as it holds how things were before UniMacHub touched them.
    public static func hide(edge: String = "bottom") {
        let current = readSnapshot()
        var saved = storedSnapshot()
        if saved == nil {
            // Hidden already with nothing written down: macOS's own defaults are the best guess.
            saved = isHiddenByUs(current)
                ? Snapshot(autohide: nil, delay: nil, orientation: nil, recordsPlacement: true)
                : current
        } else if saved?.recordsPlacement == false {
            // Written by an earlier version, before the edge was moved: it is still the
            // person's own.
            saved?.orientation = current.orientation
            saved?.recordsPlacement = true
        }
        if let saved, saved != storedSnapshot() {
            try? FileManager.default.createDirectory(at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: snapshotFile, options: .atomic)
        }
        let inPlace = isHiddenByUs(current) && current.orientation == edge
        if !inPlace { apply(hideCommands(edge: edge)) }
    }

    static func storedSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Puts the system Dock back the way it was, if UniMacHub hid it.
    public static func restore() {
        guard let snapshot = storedSnapshot() else { return }
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
