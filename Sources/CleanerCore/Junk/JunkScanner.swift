import Darwin
import Foundation

public struct JunkContext: Sendable {
    public var home: String
    /// Bundle IDs of running apps; their caches are not touched.
    public var runningBundleIDs: Set<String>
    public var now: Date
    /// Folders claimed by specific rules, excluded from broad ones. Defaults to all catalog rules.
    public var claimingRules: [JunkRule]
    /// Installed apps, to recognize leftovers of removed ones.
    public var installed: InstalledApps

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningBundleIDs: Set<String> = [],
        now: Date = Date(),
        claimingRules: [JunkRule] = JunkCatalog.all,
        installed: InstalledApps? = nil
    ) {
        self.installed = installed ?? InstalledApps.current()
        self.home = SafetyGuard.resolve(home.path(percentEncoded: false))
        self.runningBundleIDs = runningBundleIDs
        self.now = now
        self.claimingRules = claimingRules
    }
}

/// Finds the items each `JunkRule` describes and measures them.
public enum JunkScanner {
    /// A candidate item and its on-disk size.
    typealias Found = (path: String, size: Int64)

    public static func scan(_ rules: [JunkRule], context: JunkContext) async -> [JunkCategory] {
        await withTaskGroup(of: (Int, JunkCategory).self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask {
                    await (index, JunkCategory(rule: rule, items: collect(rule, context: context)))
                }
            }
            var categories: [(Int, JunkCategory)] = []
            for await category in group where !category.1.items.isEmpty {
                categories.append(category)
            }
            return categories.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func collect(_ rule: JunkRule, context: JunkContext) async -> [JunkItem] {
        let claimed = context.claimingRules
            .filter { $0.id != rule.id }
            .flatMap { $0.roots(home: context.home) }
        let ruleOwner = rule.appBundleIDs.first { context.runningBundleIDs.contains($0) }

        var found: [Found] = []
        for source in rule.sources {
            switch source {
            case let .contents(folder, excluding):
                found += await contents(of: expand(folder, home: context.home), excluding: excluding, claimed: claimed)
            case let .paths(patterns):
                for path in patterns.flatMap({ glob(expand($0, home: context.home)) }) {
                    if let size = await allocatedSize(of: path) {
                        found.append((path, size))
                    }
                }
            case let .oldFiles(folder, extensions, days):
                found += await oldFiles(
                    in: expand(folder, home: context.home), extensions: extensions,
                    before: context.now.addingTimeInterval(-Double(days) * 86400)
                )
            case .brokenPreferences:
                found += brokenPreferences(in: context.home + "/Library/Preferences")
            case let .staleNodeModules(days):
                found += await staleNodeModules(
                    home: context.home, before: context.now.addingTimeInterval(-Double(days) * 86400)
                )
            case let .orphans(folder, naming):
                found += await orphans(
                    in: expand(folder, home: context.home), naming: naming,
                    installed: context.installed, claimed: claimed
                )
            case let .brokenLaunchAgents(folder):
                found += brokenLaunchAgents(in: expand(folder, home: context.home))
            }
        }

        var seen = Set<String>()
        return found
            .filter { $0.size > 0 && seen.insert($0.path).inserted }
            .map { JunkItem(
                path: $0.path,
                size: $0.size,
                ruleID: rule.id,
                inUseBy: ruleOwner ?? owner(of: $0.path, running: context.runningBundleIDs)
            ) }
            .sorted { $0.size > $1.size }
    }

    // MARK: - Sources

    private static func contents(of folder: String, excluding: Set<String>, claimed: [String]) async -> [Found] {
        guard let result = try? await DiskScanner().scan(URL(filePath: folder)) else { return [] }
        let root = result.root
        let isClaimed = { (path: String) in
            claimed.contains { $0 == path || $0.hasPrefix(path + "/") }
        }
        let directories = root.directories
            .filter { $0.status == .scanned && !excluding.contains($0.name) && !isClaimed($0.path) }
            .map { ($0.path, $0.allocatedSize) }
        let files = root.files
            .filter { !excluding.contains($0.name) && $0.name != ".DS_Store" && !isClaimed(root.path(of: $0)) }
            .map { (root.path(of: $0), $0.allocatedSize) }
        return directories + files
    }

    private static func oldFiles(in folder: String, extensions: Set<String>, before cutoff: Date) async -> [Found] {
        let url = URL(filePath: folder)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys)
        )) ?? []
        var result: [Found] = []
        for child in children where extensions.contains(child.pathExtension.lowercased()) {
            guard let values = try? child.resourceValues(forKeys: keys),
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            let path = child.path(percentEncoded: false)
            if let size = await allocatedSize(of: path) {
                result.append((path, size))
            }
        }
        return result
    }

    private static func brokenPreferences(in folder: String) -> [Found] {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return children.filter { $0.hasSuffix(".plist") }.compactMap { name in
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
                  let data = FileManager.default.contents(atPath: path)
            else { return nil }
            let isReadable = (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
            return isReadable ? nil : (path, Int64(info.st_blocks) * 512)
        }
    }

    private static func staleNodeModules(home: String, before cutoff: Date) async -> [Found] {
        var options = ScanOptions()
        options.excludedPaths = [home + "/Library", home + "/.Trash"]
        guard let result = try? await DiskScanner(options: options).scan(URL(filePath: home)) else { return [] }
        let cutoffTime = Int64(cutoff.timeIntervalSince1970)

        var found: [Found] = []
        var stack = [result.root]
        while let node = stack.popLast() {
            for child in node.directories {
                if child.name == "node_modules" {
                    // A project counts as stale when neither its folder nor its own files changed recently.
                    let lastChange = ([node.modificationTime] + node.files.map(\.modificationTime)
                        + node.directories.filter { $0 !== child }.map(\.modificationTime)).max() ?? 0
                    if lastChange < cutoffTime, child.allocatedSize > 0 {
                        found.append((child.path, child.allocatedSize))
                    }
                } else if !child.name.hasPrefix(".") {
                    stack.append(child)
                }
            }
        }
        return found
    }

    private static func orphans(
        in folder: String, naming: JunkRule.OrphanNaming, installed: InstalledApps, claimed: [String]
    ) async -> [Found] {
        var result: [Found] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            var identifier = name
            if case let .bundleIDWithSuffix(suffix) = naming {
                guard name.hasSuffix(suffix) else { continue }
                identifier = String(name.dropLast(suffix.count))
            }
            guard InstalledApps.looksLikeBundleID(identifier), !installed.owns(identifier) else { continue }
            let path = folder + "/" + name
            // Data a more specific rule handles, such as the SwiftPM cache under Developer Junk.
            guard !claimed.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
            if let size = await allocatedSize(of: path) {
                result.append((path, size))
            }
        }
        return result
    }

    private static func brokenLaunchAgents(in folder: String) -> [Found] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
            let path = folder + "/" + name
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard let program, program.hasPrefix("/"), !FileManager.default.fileExists(atPath: program) else {
                return nil
            }
            var info = stat()
            return lstat(path, &info) == 0 ? (path, max(Int64(info.st_blocks) * 512, 4096)) : nil
        }
    }

    // MARK: - Helpers

    static func allocatedSize(of path: String) async -> Int64? {
        await DiskUsage.allocatedSize(of: path)
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home + path.dropFirst()
        }
        return path
    }

    static func glob(_ pattern: String) -> [String] {
        guard pattern.contains("*") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard Darwin.glob(pattern, 0, nil, &matches) == 0 else { return [] }
        return (0 ..< Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// Guesses which app owns a cache or saved state item from its name.
    static func owner(of path: String, running: Set<String>) -> String? {
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".savedState") {
            name = String(name.dropLast(".savedState".count))
        }
        if running.contains(name) {
            return name
        }
        // Any folder on the way can name the owner: ".../BraveSoftware/Brave-Browser/Default/History".
        for component in path.split(separator: "/").map(String.init) {
            if let bundleID = vendorFolders[component], running.contains(bundleID) {
                return bundleID
            }
        }
        return nil
    }

    /// Cache folders named after the vendor rather than the bundle ID.
    private static let vendorFolders = [
        "Google": "com.google.Chrome",
        "BraveSoftware": "com.brave.Browser",
        "Firefox": "org.mozilla.firefox",
        "Mozilla": "org.mozilla.firefox",
        "Microsoft Edge": "com.microsoft.edgemac",
        "Arc": "company.thebrowser.Browser",
        "Opera Software": "com.operasoftware.Opera",
        "Vivaldi": "com.vivaldi.Vivaldi",
        "Yandex": "ru.yandex.desktop.yandex-browser",
        "Spotify": "com.spotify.client",
        "Slack": "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "Telegram": "ru.keepcoder.Telegram",
    ]
}
