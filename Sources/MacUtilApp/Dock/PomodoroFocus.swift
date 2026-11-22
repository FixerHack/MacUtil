import AppKit
import CleanerCore

/// What a pomodoro's focus shuts out, and puts back when it ends: Do Not Disturb, the sound,
/// and the apps that pull attention.
///
/// The settings live in UniMacHub's defaults, which both the app (where they are set) and the
/// Dock (where the pomodoro runs) read.
@MainActor
final class PomodoroFocus {
    enum Keys {
        static let doNotDisturb = "pomodoroDoNotDisturb"
        static let mutes = "pomodoroMutes"
        static let apps = "pomodoroApps"
        static let appsAction = "pomodoroAppsAction"
    }

    /// What happens to the chosen apps during focus.
    enum AppsAction: String, CaseIterable, Identifiable {
        case none, hide, quit
        var id: String { rawValue }
    }

    /// macOS lets apps switch Do Not Disturb only through Shortcuts: two shortcuts the person
    /// makes once, which UniMacHub runs.
    nonisolated static let focusOnShortcut = "UniMacHub Focus On"
    nonisolated static let focusOffShortcut = "UniMacHub Focus Off"

    /// Messengers and mail, offered until the person makes their own list.
    static let usualDistractions = [
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord", "com.apple.MobileSMS", "com.apple.mail",
        "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.facebook.archon", "com.viber.osx",
    ]

    static var defaults: UserDefaults { UserDefaults(suiteName: MacUtilInfo.bundleIdentifier) ?? .standard }

    /// The chosen apps, by bundle identifier; at first the usual ones that are installed.
    static var apps: [String] {
        get {
            if let chosen = defaults.stringArray(forKey: Keys.apps) { return chosen }
            return usualDistractions.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }
        set { defaults.set(newValue, forKey: Keys.apps) }
    }

    private var active = false
    private var mutedByUs = false
    private var closed: [URL] = []

    /// Focus begins: shuts out what the person chose.
    func begin() {
        guard !active else { return }
        active = true
        let settings = Self.defaults
        if settings.bool(forKey: Keys.doNotDisturb) {
            Self.runShortcut(Self.focusOnShortcut)
        }
        if settings.bool(forKey: Keys.mutes) {
            Task {
                let output = await Command.run("/usr/bin/osascript", ["-e", "output muted of (get volume settings)"])
                guard output?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else { return }
                _ = await Command.run("/usr/bin/osascript", ["-e", "set volume with output muted"])
                self.mutedByUs = true
            }
        }
        let action = AppsAction(rawValue: settings.string(forKey: Keys.appsAction) ?? "") ?? .none
        guard action != .none else { return }
        for id in Self.apps {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                switch action {
                case .hide: app.hide()
                case .quit:
                    if let url = app.bundleURL { closed.append(url) }
                    app.terminate()
                case .none: break
                }
            }
        }
    }

    /// Focus ends, for a rest, a pause or a stop: everything as it was.
    func end() {
        guard active else { return }
        active = false
        if Self.defaults.bool(forKey: Keys.doNotDisturb) {
            Self.runShortcut(Self.focusOffShortcut)
        }
        if mutedByUs {
            mutedByUs = false
            Task { _ = await Command.run("/usr/bin/osascript", ["-e", "set volume without output muted"]) }
        }
        // Apps closed for the focus open again, behind whatever is in front.
        let reopen = closed
        closed = []
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for url in reopen {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private static func runShortcut(_ name: String) {
        Task { _ = await Command.run("/usr/bin/shortcuts", ["run", name]) }
    }

    /// Whether both shortcuts exist, for the settings to say what is missing.
    nonisolated static func shortcutsReady() async -> Bool {
        guard let output = await Command.run("/usr/bin/shortcuts", ["list"]) else { return false }
        let names = Set(output.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return names.contains(focusOnShortcut) && names.contains(focusOffShortcut)
    }
}
