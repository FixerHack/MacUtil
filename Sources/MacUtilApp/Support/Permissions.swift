import AppKit
import CoreServices
import UserNotifications

/// Where a permission stands, read from macOS rather than remembered.
///
/// macOS asks about each permission once. After that, asking again shows nothing and
/// returns the old answer, so a button that only asks would look like it worked and change
/// nothing. Every screen that offers a permission reads this instead.
enum Grant: Equatable {
    case granted
    case denied
    case notAsked

    /// Asked and answered, either way. Only an unanswered question holds the welcome up.
    var isAnswered: Bool { self != .notAsked }
}

enum Permissions {
    // MARK: - Notifications

    static func notifications() async -> Grant {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }

    /// Shows macOS's own question the first time, and reads the answer every time after.
    static func requestNotifications() async -> Grant {
        if await notifications() == .notAsked {
            _ = await Notifications.requestPermission()
        }
        return await notifications()
    }

    static var notificationSettingsURL: URL {
        let id = Bundle.main.bundleIdentifier ?? ""
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
    }

    // MARK: - Automation

    static let finder = "com.apple.finder"

    /// Whether UniMacHub may send Finder Apple Events, without asking.
    static func automation() async -> Grant {
        await determine(asking: false)
    }

    /// Shows macOS's own question the first time, and reads the answer every time after.
    static func requestAutomation() async -> Grant {
        await determine(asking: true)
    }

    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    /// Asks TCC directly. It blocks while its prompt is up, so it runs off the main thread.
    private static func determine(asking: Bool) async -> Grant {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: finder)
            guard let address = target.aeDesc else { return Grant.notAsked }
            let status = AEDeterminePermissionToAutomateTarget(
                address, AEEventClass(typeWildCard), AEEventID(typeWildCard), asking
            )
            switch status {
            case noErr: return Grant.granted
            case OSStatus(errAEEventNotPermitted): return Grant.denied
            // errAEEventWouldRequireUserConsent, or Finder not running (procNotFound).
            default: return Grant.notAsked
            }
        }.value
    }
}
