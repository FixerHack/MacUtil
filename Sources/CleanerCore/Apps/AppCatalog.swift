import CoreServices
import Foundation

/// An installed application as the Uninstaller shows it.
public struct AppRecord: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let isAppStore: Bool
    public let lastUsed: Date?
    /// Size of the bundle itself, without data in ~/Library.
    public let size: Int64

    public var id: String { path }
}

public enum AppCatalog {
    public static var defaultFolders: [String] {
        ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    }

    /// Apps the user installed, with sizes. Apps on the read-only system volume
    /// (Safari, Mail…) and MacUtil itself are left out: they cannot be removed.
    public static func scan(folders: [String] = defaultFolders) async -> [AppRecord] {
        let paths = appPaths(in: folders).filter { !isSystemApp($0) }
        let records = await withTaskGroup(of: AppRecord?.self) { group in
            for path in paths {
                group.addTask { await record(for: path) }
            }
            var records: [AppRecord] = []
            for await record in group {
                if let record {
                    records.append(record)
                }
            }
            return records
        }
        return records
            .filter { $0.bundleID != MacUtilInfo.bundleIdentifier }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func record(for path: String) async -> AppRecord? {
        guard let bundle = Bundle(path: path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return await AppRecord(
            path: path,
            name: name,
            bundleID: bundle.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            isAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt"),
            lastUsed: lastUsedDate(path),
            size: DiskUsage.allocatedSize(of: path) ?? 0
        )
    }

    /// `.app` bundles in the folders and one level of subfolders ("Adobe Photoshop 2026/").
    public static func appPaths(in folders: [String]) -> [String] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String) {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        for folder in folders {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    add(path)
                } else if !folders.contains(path), isDirectory(path) {
                    for inner in (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
                        where inner.hasSuffix(".app")
                    {
                        add(path + "/" + inner)
                    }
                }
            }
        }
        return result
    }

    /// Spotlight's "Last opened" date.
    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(filePath: path) as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func isSystemApp(_ path: String) -> Bool {
        let values = try? URL(filePath: path).resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true || SafetyGuard.resolve(path).hasPrefix("/System/")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Bundle IDs of every app on the Mac, to tell data of installed apps from
/// leftovers of removed ones.
public struct InstalledApps: Sendable {
    public let bundleIDs: Set<String>
    /// First two components of each bundle ID ("com.docker"): helpers and
    /// updaters of an installed vendor's apps count as owned.
    let vendors: Set<String>
    /// Names of installed command-line tools ("swiftformat"): their data is not app leftovers.
    let commandLineTools: Set<String>
    /// Falls back to LaunchServices, which also knows apps outside the scanned folders.
    let asksLaunchServices: Bool

    public init(bundleIDs: Set<String>, commandLineTools: Set<String> = [], asksLaunchServices: Bool = false) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
        vendors = Set(self.bundleIDs.compactMap(Self.vendor(of:)))
        self.commandLineTools = Set(commandLineTools.map { $0.lowercased() })
        self.asksLaunchServices = asksLaunchServices
    }

    public static func current() -> InstalledApps {
        let home = NSHomeDirectory()
        let folders = AppCatalog.defaultFolders + [
            "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
            // Steam keeps real game bundles here; ~/Applications only has launcher shortcuts.
            home + "/Library/Application Support/Steam/steamapps/common",
        ]
        let ids = AppCatalog.appPaths(in: folders).compactMap { Bundle(path: $0)?.bundleIdentifier }
        let toolFolders = [
            "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin",
        ]
        let tools = toolFolders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        return InstalledApps(bundleIDs: Set(ids), commandLineTools: Set(tools), asksLaunchServices: true)
    }

    /// Whether data named after `identifier` belongs to an installed app.
    public func owns(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        if id.hasPrefix("com.apple.") || bundleIDs.contains(id) {
            return true
        }
        if bundleIDs.contains(where: { id.hasPrefix($0 + ".") }) {
            return true
        }
        if let vendor = Self.vendor(of: id), vendors.contains(vendor) {
            return true
        }
        if let tool = id.split(separator: ".").last, commandLineTools.contains(String(tool)) {
            return true
        }
        if asksLaunchServices,
           let urls = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue(),
           CFArrayGetCount(urls) > 0
        {
            return true
        }
        return false
    }

    static func vendor(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        return parts.count >= 3 ? parts.prefix(2).joined(separator: ".") : nil
    }

    /// Reverse-DNS names such as "com.example.App"; folders like "Google" are not.
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }), !name.contains(" ") else { return false }
        let topLevel = parts[0].lowercased()
        return topLevel.count >= 2 && topLevel.count <= 6 && topLevel.allSatisfy(\.isLetter)
    }
}

/// On-disk size of files and folders.
public enum DiskUsage {
    /// Allocated size of a file or folder, or nil if it does not exist.
    public static func allocatedSize(of path: String) async -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFDIR {
            return try? await DiskScanner().scan(URL(filePath: path)).root.allocatedSize
        }
        return Int64(info.st_blocks) * 512
    }
}
