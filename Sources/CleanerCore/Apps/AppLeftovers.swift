import Foundation

/// Data an app keeps outside its bundle.
public struct Leftover: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case applicationSupport, caches, preferences, containers, groupContainers
        case savedState, webData, logs, launchItems, other
    }

    public enum Match: Sendable {
        /// Named after the bundle ID: certainly the app's.
        case bundleID
        /// Named after the app: very likely, but worth a look.
        case name
    }

    public let path: String
    public let size: Int64
    public let kind: Kind
    public let match: Match
    /// Lives in /Library and needs administrator rights to remove.
    public let requiresAdmin: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum AppLeftovers {
    private enum Pattern {
        /// The name equals the key, or starts with "key." ("com.app.helper").
        case identifier
        /// Preference files: "key.plist" and "key.anything.plist".
        case plist
        /// Any name containing the key (group containers).
        case contains
    }

    private struct Place {
        let folder: String
        let kind: Leftover.Kind
        let pattern: Pattern
        let byName: Bool
    }

    private static func places(home: String) -> [Place] {
        let user = home + "/Library"
        return [
            Place(folder: user + "/Application Support", kind: .applicationSupport, pattern: .identifier, byName: true),
            Place(folder: user + "/Caches", kind: .caches, pattern: .identifier, byName: true),
            Place(folder: user + "/Preferences", kind: .preferences, pattern: .plist, byName: false),
            Place(folder: user + "/Preferences/ByHost", kind: .preferences, pattern: .plist, byName: false),
            Place(folder: user + "/Containers", kind: .containers, pattern: .identifier, byName: false),
            Place(folder: user + "/Group Containers", kind: .groupContainers, pattern: .contains, byName: false),
            Place(folder: user + "/Application Scripts", kind: .containers, pattern: .identifier, byName: false),
            Place(folder: user + "/Saved Application State", kind: .savedState, pattern: .identifier, byName: false),
            Place(folder: user + "/HTTPStorages", kind: .webData, pattern: .identifier, byName: false),
            Place(folder: user + "/WebKit", kind: .webData, pattern: .identifier, byName: false),
            Place(folder: user + "/Cookies", kind: .webData, pattern: .identifier, byName: false),
            Place(folder: user + "/Logs", kind: .logs, pattern: .identifier, byName: true),
            Place(folder: user + "/LaunchAgents", kind: .launchItems, pattern: .plist, byName: false),
            Place(
                folder: "/Library/Application Support",
                kind: .applicationSupport,
                pattern: .identifier,
                byName: true
            ),
            Place(folder: "/Library/Caches", kind: .caches, pattern: .identifier, byName: false),
            Place(folder: "/Library/Preferences", kind: .preferences, pattern: .plist, byName: false),
            Place(folder: "/Library/LaunchAgents", kind: .launchItems, pattern: .plist, byName: false),
            Place(folder: "/Library/LaunchDaemons", kind: .launchItems, pattern: .plist, byName: false),
            Place(folder: "/Library/PrivilegedHelperTools", kind: .launchItems, pattern: .identifier, byName: false),
        ]
    }

    /// Names too generic to match by app name alone.
    private static let genericNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "steam", "java", "python", "node", "docker",
        "helper", "update", "updater", "support", "data", "cache", "caches", "logs", "app", "browser",
    ]

    /// Everything the app with this bundle ID and name left in the libraries.
    public static func find(bundleID: String?, name: String, home: String = NSHomeDirectory()) async -> [Leftover] {
        let id = bundleID?.lowercased()
        let appName = name.lowercased()
        let nameIsUsable = appName.count >= 4 && !genericNames.contains(appName)

        var candidates: [(path: String, kind: Leftover.Kind, match: Leftover.Match)] = []
        for place in places(home: home) {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: place.folder)) ?? [] {
                let lower = entry.lowercased()
                var match: Leftover.Match?
                if let id {
                    switch place.pattern {
                    case .identifier:
                        if lower == id || lower.hasPrefix(id + ".") || lower == id + ".binarycookies" {
                            match = .bundleID
                        }
                    case .plist:
                        if lower.hasSuffix(".plist"), lower == id + ".plist" || lower.hasPrefix(id + ".") {
                            match = .bundleID
                        }
                    case .contains:
                        if lower.contains(id) {
                            match = .bundleID
                        }
                    }
                }
                if match == nil, place.byName, nameIsUsable, lower == appName {
                    match = .name
                }
                if let match {
                    candidates.append((place.folder + "/" + entry, place.kind, match))
                }
            }
        }

        var leftovers: [Leftover] = []
        for candidate in candidates {
            guard let size = await DiskUsage.allocatedSize(of: candidate.path) else { continue }
            let parent = (candidate.path as NSString).deletingLastPathComponent
            leftovers.append(Leftover(
                path: candidate.path,
                size: size,
                kind: candidate.kind,
                match: candidate.match,
                requiresAdmin: access(parent, W_OK) != 0
            ))
        }
        return leftovers.sorted { $0.size > $1.size }
    }
}
