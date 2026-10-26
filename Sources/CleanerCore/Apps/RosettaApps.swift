import Foundation

/// An app with no code for this Mac, which macOS has to translate to run.
public struct TranslatedApp: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let version: String?
    public let size: Int64
    public let lastUsed: Date?

    public var id: String { path }
}

/// Finds the software still running under Rosetta.
///
/// On Apple silicon an Intel-only app runs through translation: slower, hungrier for power,
/// and dependent on Rosetta, which Apple has said will not last forever. Knowing which apps
/// these are is the first step to replacing them, and on an Intel Mac the question does not
/// arise at all.
public enum RosettaApps {
    /// False on an Intel Mac, where nothing is being translated.
    public static var isRelevant: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }

    public static func find(apps: [AppRecord]? = nil) async -> [TranslatedApp] {
        guard isRelevant else { return [] }
        let installed = if let apps { apps } else { await AppCatalog.scan() }
        return installed.compactMap { app in
            guard let executable = executable(of: app.path) else { return nil }
            let architectures = AppSlimming.architectures(ofMachO: executable)
            // Nothing readable means it is a script or a wrapper, not Intel-only code.
            guard !architectures.isEmpty, !architectures.contains(AppSlimming.native) else { return nil }
            return TranslatedApp(
                path: app.path, name: app.name, version: app.version, size: app.size, lastUsed: app.lastUsed
            )
        }
        .sorted { $0.size > $1.size }
    }

    /// The binary macOS starts when the app is opened.
    static func executable(of bundlePath: String) -> String? {
        let info = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOfFile: info),
              let name = plist["CFBundleExecutable"] as? String
        else { return nil }
        let path = (bundlePath as NSString).appendingPathComponent("Contents/MacOS/\(name)")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
