import Foundation

/// An installed application and its code signature.
public struct InstalledApp: Sendable, Identifiable {
    public let path: String
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let signature: CodeSignature

    public var id: String { path }

    /// The main executable, which is what VirusTotal knows the app by.
    public var executablePath: String? {
        Bundle(path: path)?.executablePath
    }
}

public enum AppInventory {
    public static let defaultFolders = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    /// Apps in the given folders and one level of subfolders (suites such as
    /// "Adobe Photoshop 2026/"), inspected in parallel.
    public static func scan(folders: [String] = defaultFolders) async -> [InstalledApp] {
        let paths = appPaths(in: folders)
        return await withTaskGroup(of: InstalledApp.self) { group in
            let limit = max(ProcessInfo.processInfo.activeProcessorCount, 2)
            var iterator = paths.makeIterator()
            for _ in 0 ..< limit {
                if let path = iterator.next() {
                    group.addTask { inspect(path) }
                }
            }
            var apps: [InstalledApp] = []
            for await app in group {
                apps.append(app)
                if let path = iterator.next() {
                    group.addTask { inspect(path) }
                }
            }
            return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public static func inspect(_ path: String) -> InstalledApp {
        let bundle = Bundle(path: path)
        let info = bundle?.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
        return InstalledApp(
            path: path,
            name: displayName ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
            bundleID: bundle?.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            signature: CodeSignature.inspect(path)
        )
    }

    static func appPaths(in folders: [String]) -> [String] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for folder in folders {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    if seen.insert(path).inserted {
                        result.append(path)
                    }
                } else if name != "Utilities", isDirectory(path) {
                    for inner in (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
                        where inner.hasSuffix(".app")
                    {
                        let innerPath = path + "/" + inner
                        if seen.insert(innerPath).inserted {
                            result.append(innerPath)
                        }
                    }
                }
            }
        }
        return result
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
