import Foundation

/// A newer version of an installed app and where it comes from.
public struct AppUpdate: Sendable, Identifiable, Hashable {
    public enum Source: Sendable, Hashable {
        /// The app updates itself through Sparkle.
        case sparkle(downloadURL: URL?)
        /// Installed with `brew install --cask`.
        case homebrew(cask: String)
        case appStore(id: String)
    }

    public let appPath: String
    public let name: String
    public let installedVersion: String
    public let availableVersion: String
    public let source: Source

    public var id: String { appPath }
}

public enum AppUpdates {
    /// Checks every source in parallel. Network failures of single apps are skipped.
    public static func check(apps: [AppRecord], session: URLSession = .shared) async -> [AppUpdate] {
        async let sparkle = sparkleUpdates(apps: apps, session: session)
        async let homebrew = homebrewUpdates(apps: apps)
        async let appStore = appStoreUpdates(apps: apps)
        var updates: [String: AppUpdate] = [:]
        // Homebrew and the App Store know best how to install; they win over Sparkle.
        for update in await sparkle + appStore + homebrew {
            updates[update.appPath] = update
        }
        return updates.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Sparkle

    static func sparkleUpdates(apps: [AppRecord], session: URLSession) async -> [AppUpdate] {
        await withTaskGroup(of: AppUpdate?.self) { group in
            for app in apps {
                guard let info = Bundle(path: app.path)?.infoDictionary,
                      let feed = (info["SUFeedURL"] as? String).flatMap(URL.init(string:)),
                      feed.scheme == "https"
                else { continue }
                let installed = info["CFBundleShortVersionString"] as? String ?? ""
                let build = info["CFBundleVersion"] as? String ?? installed
                group.addTask {
                    var request = URLRequest(url: feed, timeoutInterval: 15)
                    request.setValue("MacUtil", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await session.data(for: request),
                          let latest = latestAppcastItem(data)
                    else { return nil }
                    let newer = compare(latest.build, build) == .orderedDescending
                        || compare(latest.version, installed) == .orderedDescending
                    guard newer else { return nil }
                    return AppUpdate(
                        appPath: app.path, name: app.name, installedVersion: installed,
                        availableVersion: latest.version, source: .sparkle(downloadURL: latest.url)
                    )
                }
            }
            var updates: [AppUpdate] = []
            for await update in group {
                if let update {
                    updates.append(update)
                }
            }
            return updates
        }
    }

    /// The newest `<item>` of a Sparkle appcast: its short version, build and download.
    static func latestAppcastItem(_ data: Data) -> (version: String, build: String, url: URL?)? {
        let parser = AppcastParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.items.max { compare($0.build, $1.build) == .orderedAscending }
    }

    /// Numeric version comparison: "1.10" is newer than "1.9".
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    // MARK: - Homebrew

    static let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func homebrewUpdates(apps: [AppRecord]) async -> [AppUpdate] {
        guard let brew else { return [] }
        guard let output = await Command.run(
            brew,
            ["outdated", "--cask", "--greedy", "--json=v2"],
            timeout: .seconds(120)
        ),
            output.status == 0
        else { return [] }
        return parseBrewOutdated(Data(output.text.utf8), apps: apps)
    }

    static func parseBrewOutdated(_ data: Data, apps: [AppRecord]) -> [AppUpdate] {
        struct Report: Decodable {
            struct Cask: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }

            let casks: [Cask]
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return [] }
        return report.casks.compactMap { cask in
            // Match the cask ("visual-studio-code") to an app ("Visual Studio Code").
            let normalizedCask = cask.name.replacingOccurrences(of: "-", with: "").lowercased()
            guard let app = apps.first(where: {
                $0.name.replacingOccurrences(of: " ", with: "").lowercased() == normalizedCask
                    || ((($0.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                    .replacingOccurrences(of: " ", with: "").lowercased() == normalizedCask
            }) else { return nil }
            return AppUpdate(
                appPath: app.path, name: app.name,
                installedVersion: cask.installed_versions.first ?? app.version ?? "",
                availableVersion: cask.current_version.components(separatedBy: ",").first ?? cask.current_version,
                source: .homebrew(cask: cask.name)
            )
        }
    }

    /// Runs `brew upgrade --cask`.
    public static func upgrade(cask: String) async -> Command.Output? {
        guard let brew else { return nil }
        return await Command.run(brew, ["upgrade", "--cask", cask], timeout: .seconds(900))
    }

    // MARK: - App Store

    static let mas = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Uses the `mas` command-line tool when installed; without it App Store apps are skipped.
    static func appStoreUpdates(apps: [AppRecord]) async -> [AppUpdate] {
        guard let mas, let output = await Command.run(mas, ["outdated"], timeout: .seconds(60)) else { return [] }
        return parseMasOutdated(output.text, apps: apps)
    }

    /// Lines like `497799835 Xcode (26.0 -> 27.0)`.
    static func parseMasOutdated(_ text: String, apps: [AppRecord]) -> [AppUpdate] {
        text.split(separator: "\n").compactMap { line in
            let pattern = #"^(\d+)\s+(.+?)\s+\((.+?)\s+->\s+(.+?)\)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)),
                  match.numberOfRanges == 5
            else { return nil }
            let line = String(line)
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            let name = group(2)
            guard let app = apps.first(where: { $0.name == name && $0.isAppStore }) else { return nil }
            return AppUpdate(
                appPath: app.path, name: app.name, installedVersion: group(3), availableVersion: group(4),
                source: .appStore(id: group(1))
            )
        }
    }
}

/// Collects `<item>` entries of a Sparkle appcast.
private final class AppcastParser: NSObject, XMLParserDelegate {
    var items: [(version: String, build: String, url: URL?)] = []
    private var inItem = false
    private var version = ""
    private var build = ""
    private var url: URL?
    private var text = ""

    func parser(
        _: XMLParser,
        didStartElement element: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        if element == "item" {
            inItem = true
            version = ""
            build = ""
            url = nil
        } else if inItem, element == "enclosure" {
            url = attributes["url"].flatMap(URL.init(string:))
            build = attributes["sparkle:version"] ?? build
            version = attributes["sparkle:shortVersionString"] ?? version
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement element: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "sparkle:version" where inItem: build = value
        case "sparkle:shortVersionString" where inItem: version = value
        case "item":
            inItem = false
            if !build.isEmpty || !version.isEmpty {
                items.append((version.isEmpty ? build : version, build.isEmpty ? version : build, url))
            }
        default: break
        }
    }
}
