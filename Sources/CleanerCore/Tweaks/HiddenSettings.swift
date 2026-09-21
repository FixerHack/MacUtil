import Foundation

/// A macOS setting that has no switch in System Settings, changed with `defaults`.
public struct HiddenSetting: Sendable, Identifiable, Hashable {
    public enum Section: String, Sendable, CaseIterable {
        case finder, dock, screenshots, typing, general
    }

    public enum Value: Sendable, Hashable {
        case bool(Bool)
        case float(Double)
        case string(String)

        var arguments: [String] {
            switch self {
            case let .bool(value): ["-bool", value ? "true" : "false"]
            case let .float(value): ["-float", String(value)]
            case let .string(value): ["-string", value]
            }
        }
    }

    public struct Option: Sendable, Hashable {
        public let title: LocalizedStringResource
        public let value: Value

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.value == rhs.value
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(value)
        }
    }

    public let id: String
    public let section: Section
    public let title: LocalizedStringResource
    public let details: LocalizedStringResource
    /// Preferences domain; "NSGlobalDomain" for system-wide ones.
    public let domain: String
    public let key: String
    /// The value that turns the tweak on, or the choices for a menu.
    public let options: [Option]
    /// Process to restart so the change shows ("Finder", "Dock", "SystemUIServer").
    public let restarts: String?

    public var isToggle: Bool { options.count == 1 }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum HiddenSettings {
    static func toggle(
        _ id: String, _ section: HiddenSetting.Section, _ title: LocalizedStringResource,
        _ details: LocalizedStringResource, domain: String, key: String, on value: HiddenSetting.Value,
        restarts: String?
    ) -> HiddenSetting {
        HiddenSetting(
            id: id, section: section, title: title, details: details, domain: domain, key: key,
            options: [HiddenSetting.Option(title: "On", value: value)], restarts: restarts
        )
    }

    public static let all: [HiddenSetting] = [
        toggle(
            "finder.hiddenFiles",
            .finder,
            "Show hidden files",
            "Shows files and folders whose names start with a dot. Also toggled with ⌘⇧. in Finder.",
            domain: "com.apple.finder",
            key: "AppleShowAllFiles",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.extensions",
            .finder,
            "Show all file extensions",
            "Always shows .pdf, .app and other extensions.",
            domain: "NSGlobalDomain",
            key: "AppleShowAllExtensions",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.pathBar",
            .finder,
            "Show path bar",
            "Shows where the current folder is at the bottom of Finder windows.",
            domain: "com.apple.finder",
            key: "ShowPathbar",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.statusBar",
            .finder,
            "Show status bar",
            "Shows the number of items and free space.",
            domain: "com.apple.finder",
            key: "ShowStatusBar",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.posixTitle",
            .finder,
            "Full path in window title",
            "Shows /Users/… instead of just the folder name.",
            domain: "com.apple.finder",
            key: "_FXShowPosixPathInTitle",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.foldersFirst",
            .finder,
            "Keep folders on top",
            "Sorts folders before files when sorting by name.",
            domain: "com.apple.finder",
            key: "_FXSortFoldersFirst",
            on: .bool(true),
            restarts: "Finder"
        ),
        toggle(
            "finder.extensionWarning",
            .finder,
            "Don't warn when changing an extension",
            "Renames files without the confirmation dialog.",
            domain: "com.apple.finder",
            key: "FXEnableExtensionChangeWarning",
            on: .bool(false),
            restarts: "Finder"
        ),
        toggle(
            "finder.networkDSStore",
            .finder,
            "No .DS_Store on network drives",
            "Stops Finder from leaving .DS_Store files on shared folders.",
            domain: "com.apple.desktopservices",
            key: "DSDontWriteNetworkStores",
            on: .bool(true),
            restarts: nil
        ),
        toggle(
            "finder.usbDSStore",
            .finder,
            "No .DS_Store on USB drives",
            "Stops Finder from leaving .DS_Store files on external drives.",
            domain: "com.apple.desktopservices",
            key: "DSDontWriteUSBStores",
            on: .bool(true),
            restarts: nil
        ),

        toggle(
            "dock.noDelay",
            .dock,
            "Show hidden Dock instantly",
            "Removes the delay before an auto-hidden Dock appears.",
            domain: "com.apple.dock",
            key: "autohide-delay",
            on: .float(0),
            restarts: "Dock"
        ),
        toggle(
            "dock.fastAnimation",
            .dock,
            "Faster Dock hiding",
            "Makes the auto-hide animation four times faster.",
            domain: "com.apple.dock",
            key: "autohide-time-modifier",
            on: .float(0.25),
            restarts: "Dock"
        ),
        toggle(
            "dock.noRecents",
            .dock,
            "Hide recent apps",
            "Removes the recent apps section from the Dock.",
            domain: "com.apple.dock",
            key: "show-recents",
            on: .bool(false),
            restarts: "Dock"
        ),
        toggle(
            "dock.runningOnly",
            .dock,
            "Only show running apps",
            "The Dock shows only open apps, like a task switcher.",
            domain: "com.apple.dock",
            key: "static-only",
            on: .bool(true),
            restarts: "Dock"
        ),
        toggle(
            "dock.hiddenApps",
            .dock,
            "Dim hidden apps",
            "Icons of apps hidden with ⌘H look translucent.",
            domain: "com.apple.dock",
            key: "showhidden",
            on: .bool(true),
            restarts: "Dock"
        ),
        HiddenSetting(
            id: "dock.minimizeEffect", section: .dock, title: "Minimize effect",
            details: "The animation when a window goes to the Dock.",
            domain: "com.apple.dock", key: "mineffect",
            options: [.init(title: "Genie", value: .string("genie")), .init(title: "Scale", value: .string("scale")),
                      .init(title: "Suck", value: .string("suck"))],
            restarts: "Dock"
        ),

        HiddenSetting(
            id: "screenshots.format", section: .screenshots, title: "Screenshot format",
            details: "File type of new screenshots.",
            domain: "com.apple.screencapture", key: "type",
            options: [.init(title: "PNG", value: .string("png")), .init(title: "JPEG", value: .string("jpg")),
                      .init(title: "HEIC", value: .string("heic")), .init(title: "PDF", value: .string("pdf"))],
            restarts: "SystemUIServer"
        ),
        toggle(
            "screenshots.noShadow",
            .screenshots,
            "No window shadow",
            "Window screenshots (⌘⇧4, then Space) come without the shadow.",
            domain: "com.apple.screencapture",
            key: "disable-shadow",
            on: .bool(true),
            restarts: "SystemUIServer"
        ),
        toggle(
            "screenshots.noDate",
            .screenshots,
            "No date in file names",
            "Names screenshots \"Screenshot 1\" instead of with date and time.",
            domain: "com.apple.screencapture",
            key: "include-date",
            on: .bool(false),
            restarts: "SystemUIServer"
        ),

        toggle(
            "typing.keyRepeat",
            .typing,
            "Key repeat instead of accents",
            "Holding a key repeats it instead of showing the accent menu. Handy for code and games.",
            domain: "NSGlobalDomain",
            key: "ApplePressAndHoldEnabled",
            on: .bool(false),
            restarts: nil
        ),
        toggle(
            "typing.noAutocorrect",
            .typing,
            "Turn off autocorrect",
            "Stops macOS from changing words as you type.",
            domain: "NSGlobalDomain",
            key: "NSAutomaticSpellingCorrectionEnabled",
            on: .bool(false),
            restarts: nil
        ),
        toggle(
            "typing.noSmartQuotes",
            .typing,
            "Straight quotes",
            "Keeps \" and ' as typed instead of curly quotes. Useful for code.",
            domain: "NSGlobalDomain",
            key: "NSAutomaticQuoteSubstitutionEnabled",
            on: .bool(false),
            restarts: nil
        ),
        toggle(
            "typing.noSmartDashes",
            .typing,
            "Plain dashes",
            "Keeps -- as typed instead of turning it into a long dash.",
            domain: "NSGlobalDomain",
            key: "NSAutomaticDashSubstitutionEnabled",
            on: .bool(false),
            restarts: nil
        ),

        toggle(
            "general.expandSave",
            .general,
            "Expanded save dialogs",
            "Save dialogs open with the full folder browser.",
            domain: "NSGlobalDomain",
            key: "NSNavPanelExpandedStateForSaveMode",
            on: .bool(true),
            restarts: nil
        ),
        toggle(
            "general.scrollBars",
            .general,
            "Always show scroll bars",
            "Scroll bars stay visible instead of appearing only while scrolling.",
            domain: "NSGlobalDomain",
            key: "AppleShowScrollBars",
            on: .string("Always"),
            restarts: nil
        ),
        toggle(
            "general.timeMachinePrompt",
            .general,
            "Don't offer new disks for Time Machine",
            "Stops the question each time you connect a new drive.",
            domain: "com.apple.TimeMachine",
            key: "DoNotOfferNewDisksForBackup",
            on: .bool(true),
            restarts: nil
        ),
        toggle(
            "general.crashDialog",
            .general,
            "Quieter crash reports",
            "Shows crash reports as notifications instead of dialogs.",
            domain: "com.apple.CrashReporter",
            key: "UseUNC",
            on: .bool(true),
            restarts: nil
        ),
    ]

    /// The value stored now, or nil when the key is unset (macOS default).
    public static func currentValue(of setting: HiddenSetting) -> HiddenSetting.Value? {
        let domain = setting.domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : setting.domain as CFString
        CFPreferencesAppSynchronize(domain)
        guard let raw = CFPreferencesCopyAppValue(setting.key as CFString, domain) else { return nil }
        return value(raw, like: setting.options.first?.value)
    }

    public static func isOn(_ setting: HiddenSetting) -> Bool {
        guard setting.isToggle, let on = setting.options.first?.value else { return false }
        return currentValue(of: setting) == on
    }

    /// Converts a stored preference to the setting's value type ("1", 1 and true are all `true`).
    static func value(_ raw: Any, like example: HiddenSetting.Value?) -> HiddenSetting.Value? {
        switch example {
        case .bool:
            if let number = raw as? NSNumber {
                return .bool(number.boolValue)
            }
            if let text = raw as? String {
                return .bool(["1", "true", "yes"].contains(text.lowercased()))
            }
        case .float:
            if let number = raw as? NSNumber {
                return .float(number.doubleValue)
            }
            if let text = raw as? String, let number = Double(text) {
                return .float(number)
            }
        case .string, nil:
            if let text = raw as? String {
                return .string(text)
            }
        }
        return nil
    }

    /// Stores a value, or removes the key to go back to the macOS default.
    @discardableResult
    public static func apply(_ value: HiddenSetting.Value?, to setting: HiddenSetting) async -> Bool {
        let arguments = value.map { ["write", setting.domain, setting.key] + $0.arguments }
            ?? ["delete", setting.domain, setting.key]
        let output = await Command.run("/usr/bin/defaults", arguments)
        if let process = setting.restarts {
            _ = await Command.run("/usr/bin/killall", [process])
        }
        // "delete" fails when the key is already unset, which is the goal anyway.
        return output?.status == 0 || value == nil
    }
}
