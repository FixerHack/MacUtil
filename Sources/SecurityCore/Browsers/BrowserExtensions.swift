import CleanerCore
import Foundation

public struct BrowserExtension: Sendable, Identifiable, Hashable {
    public let browser: String
    public let identifier: String
    public let name: String
    public let version: String?
    public let path: String
    /// Can read and change every website the user visits.
    public let readsAllSites: Bool
    /// Sensitive API permissions such as cookies or intercepting requests.
    public let sensitivePermissions: [String]

    public var id: String { browser + "|" + identifier }

    public var risk: PersistenceItem.Risk {
        if readsAllSites, !sensitivePermissions.isEmpty {
            return .medium
        }
        if readsAllSites || !sensitivePermissions.isEmpty {
            return .low
        }
        return .none
    }
}

public enum BrowserExtensions {
    static let chromiumBrowsers: [(name: String, folder: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
        ("Opera", "com.operasoftware.Opera"),
        ("Chromium", "Chromium"),
    ]

    static let sensitive: Set<String> = [
        "cookies", "webRequest", "webRequestBlocking", "declarativeNetRequest", "proxy", "debugger",
        "nativeMessaging", "history", "management", "clipboardRead", "tabCapture", "desktopCapture", "privacy",
    ]

    static let allSitesPatterns: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*", "file:///*"]

    public static func scan(home: String = NSHomeDirectory()) -> [BrowserExtension] {
        let support = home + "/Library/Application Support"
        var result: [BrowserExtension] = []
        for browser in chromiumBrowsers {
            let base = support + "/" + browser.folder
            for profile in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                where profile == "Default" || profile.hasPrefix("Profile ")
            {
                result += chromiumExtensions(in: base + "/" + profile + "/Extensions", browser: browser.name)
            }
        }
        result += firefoxExtensions(profiles: support + "/Firefox/Profiles")
        var seen = Set<String>()
        return result
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.risk, $1.name) > ($1.risk, $0.name) }
    }

    static func chromiumExtensions(in folder: String, browser: String) -> [BrowserExtension] {
        let fileManager = FileManager.default
        return ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).compactMap { id in
            let extensionFolder = folder + "/" + id
            // The newest installed version.
            guard let version = ((try? fileManager.contentsOfDirectory(atPath: extensionFolder)) ?? [])
                .filter({ !$0.hasPrefix(".") }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }),
                let data = fileManager.contents(atPath: extensionFolder + "/" + version + "/manifest.json"),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let root = extensionFolder + "/" + version
            var name = manifest["name"] as? String ?? id
            if name.hasPrefix("__MSG_") {
                name = localizedMessage(name, root: root, defaultLocale: manifest["default_locale"] as? String) ?? id
            }
            let permissions = (manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
            let hosts = (manifest["host_permissions"] as? [String] ?? [])
                + (manifest["content_scripts"] as? [[String: Any]] ?? []).flatMap { $0["matches"] as? [String] ?? [] }
                + permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
            return BrowserExtension(
                browser: browser, identifier: id, name: name, version: manifest["version"] as? String,
                path: root,
                readsAllSites: hosts.contains(where: allSitesPatterns.contains),
                sensitivePermissions: permissions.filter(sensitive.contains).sorted()
            )
        }
    }

    /// Resolves "__MSG_appName__" from _locales/<locale>/messages.json.
    static func localizedMessage(_ key: String, root: String, defaultLocale: String?) -> String? {
        let messageKey = key.dropFirst("__MSG_".count).dropLast(2).lowercased()
        for locale in [defaultLocale, "en", "en_US"].compactMap(\.self) {
            guard let data = FileManager.default.contents(atPath: root + "/_locales/\(locale)/messages.json"),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (name, value) in messages where name.lowercased() == messageKey {
                if let message = (value as? [String: Any])?["message"] as? String {
                    return message
                }
            }
        }
        return nil
    }

    static func firefoxExtensions(profiles: String) -> [BrowserExtension] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profiles)) ?? [])
            .flatMap { profile -> [BrowserExtension] in
                let path = profiles + "/" + profile + "/extensions.json"
                guard let data = FileManager.default.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let addons = json["addons"] as? [[String: Any]]
                else { return [] }
                return addons.compactMap { addon in
                    guard addon["type"] as? String == "extension",
                          addon["location"] as? String == "app-profile" else { return nil }
                    let permissions = (addon["userPermissions"] as? [String: Any])?["permissions"] as? [String] ?? []
                    let origins = (addon["userPermissions"] as? [String: Any])?["origins"] as? [String] ?? []
                    let name = (addon["defaultLocale"] as? [
                        String: Any
                    ])?["name"] as? String ?? addon["id"] as? String ?? "?"
                    return BrowserExtension(
                        browser: "Firefox", identifier: addon["id"] as? String ?? name, name: name,
                        version: addon["version"] as? String, path: addon["path"] as? String ?? path,
                        readsAllSites: origins.contains(where: allSitesPatterns.contains),
                        sensitivePermissions: permissions.filter(sensitive.contains).sorted()
                    )
                }
            }
    }
}
