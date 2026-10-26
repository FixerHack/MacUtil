import Foundation

/// An app extension: a share sheet entry, a widget, a Finder extension, an action.
public struct AppExtension: Sendable, Identifiable, Hashable {
    public let identifier: String
    public let version: String
    public let path: String
    public let displayName: String
    /// The extension point it plugs into, as macOS names it.
    public let kind: String

    public var id: String { identifier }

    public var isApple: Bool {
        identifier.hasPrefix("com.apple.") || path.hasPrefix("/System/")
    }

    /// The app that carries it, when it lives inside one.
    public var owner: String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return (String(path[path.startIndex ..< range.lowerBound]) as NSString).lastPathComponent
    }
}

/// Something loaded into the system from a folder: a Quick Look generator, a screen saver,
/// a preference pane, an audio plug-in.
public struct SystemPlugin: Sendable, Identifiable, Hashable {
    public let path: String
    public let kind: LocalizedStringResource
    public let size: Int64
    public let modified: Date?
    /// It belongs to the person, not to the whole Mac.
    public let isPerUser: Bool

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.path == rhs.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Lists what plugs into macOS besides ordinary apps.
///
/// These are the things that run inside other programs — the Finder, Quick Look, System
/// Settings, an audio host — and so outlive the app that installed them and never show up
/// in a list of applications.
public enum SystemAddOns {
    // MARK: - App extensions

    public static func extensions() async -> [AppExtension] {
        guard let output = await Command.run("/usr/bin/pluginkit", ["-mAvvv"], timeout: .seconds(60))
        else { return [] }
        return parseExtensions(output.text)
    }

    /// `pluginkit` prints an identifier line, then indented "Key = Value" lines under it.
    static func parseExtensions(_ text: String) -> [AppExtension] {
        var found: [AppExtension] = []
        var identifier: String?
        var version = ""
        var fields: [String: String] = [:]

        func finish() {
            guard let identifier, !identifier.isEmpty else { return }
            found.append(AppExtension(
                identifier: identifier,
                version: version,
                path: fields["Path"] ?? "",
                displayName: fields["Display Name"] ?? fields["Short Name"] ?? identifier,
                kind: fields["SDK"] ?? ""
            ))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "(475 plug-ins)" is a count, not one of them.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("(") else { continue }
            finish()
            identifier = nil
            version = ""
            fields = [:]
            // "com.example.Thing(1.2)" — the version sits in the last brackets.
            if let open = trimmed.lastIndex(of: "("), trimmed.hasSuffix(")") {
                identifier = String(trimmed[trimmed.startIndex ..< open])
                let inside = String(trimmed[trimmed.index(after: open) ..< trimmed.index(before: trimmed.endIndex)])
                version = inside == "(null)" ? "" : inside
            } else {
                identifier = trimmed
            }
        }
        finish()
        return found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Tells macOS to use an extension, or to leave it alone.
    public static func setEnabled(_ enabled: Bool, identifier: String) async -> Bool {
        let output = await Command.run(
            "/usr/bin/pluginkit", ["-e", enabled ? "use" : "ignore", "-i", identifier], timeout: .seconds(30)
        )
        return output?.status == 0
    }

    // MARK: - Plug-in folders

    struct Place {
        let path: String
        let kind: LocalizedStringResource
    }

    static var places: [Place] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let kinds: [(String, LocalizedStringResource)] = [
            ("Internet Plug-Ins", "Browser plug-ins"),
            ("QuickLook", "Quick Look previews"),
            ("Spotlight", "Spotlight importers"),
            ("PreferencePanes", "Preference panes"),
            ("Screen Savers", "Screen savers"),
            ("Audio/Plug-Ins/HAL", "Audio devices"),
            ("Audio/Plug-Ins/Components", "Audio units"),
            ("Audio/Plug-Ins/VST", "VST plug-ins"),
            ("Audio/Plug-Ins/VST3", "VST3 plug-ins"),
            ("Mail/Bundles", "Mail plug-ins"),
            ("Input Methods", "Input methods"),
            ("Contextual Menu Items", "Contextual menu items"),
        ]
        return kinds.flatMap { folder, kind in
            [
                Place(path: "/Library/" + folder, kind: kind),
                Place(path: home + "/Library/" + folder, kind: kind),
            ]
        }
    }

    public static func plugins() async -> [SystemPlugin] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var found: [SystemPlugin] = []
        for place in places {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
            for name in names where !name.hasPrefix(".") {
                let path = "\(place.path)/\(name)"
                let modified = try? URL(filePath: path).resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                found.append(SystemPlugin(
                    path: path,
                    kind: place.kind,
                    size: await DiskUsage.allocatedSize(of: path) ?? 0,
                    modified: modified,
                    isPerUser: path.hasPrefix(home)
                ))
            }
        }
        return found.sorted { $0.size > $1.size }
    }
}
