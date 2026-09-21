import AppKit

/// Interface language override, stored as the app's own `AppleLanguages` default.
/// macOS reads it only at launch, so a change needs a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case ukrainian = "uk"

    var id: Self { self }

    static var current: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let languages = domain?["AppleLanguages"] as? [String]
        return languages?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
