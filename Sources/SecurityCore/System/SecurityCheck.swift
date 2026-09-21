import Foundation

/// One security setting of the Mac and how it stands.
public struct SecurityCheck: Sendable, Identifiable {
    public enum Status: Int, Sendable, Comparable {
        case fail, warning, pass, info

        public static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let id: String
    public let title: LocalizedStringResource
    public let status: Status
    /// The current state in plain words.
    public let summary: LocalizedStringResource
    /// What to do about it; nil when nothing needs doing.
    public let advice: LocalizedStringResource?
    /// System Settings pane where the user can change it.
    public let settingsURL: URL?
    /// Share of the security score; 0 for informational checks.
    public let weight: Int

    public init(
        id: String,
        title: LocalizedStringResource,
        status: Status,
        summary: LocalizedStringResource,
        advice: LocalizedStringResource? = nil,
        settingsURL: URL? = nil,
        weight: Int
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.advice = status == .pass ? nil : advice
        self.settingsURL = settingsURL
        self.weight = weight
    }
}

public enum SettingsPane {
    public static let privacySecurity = URL(string: "x-apple.systempreferences:com.apple.preference.security?General")!
    public static let fileVault = URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")!
    public static let firewall = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!
    public static let softwareUpdate =
        URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
    public static let lockScreen = URL(string: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")!
    public static let sharing = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!
    public static let users = URL(string: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")!
    public static let airDrop = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
    public static let loginItems = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
