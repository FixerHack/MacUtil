import AppKit
import CleanerCore
import Foundation

/// Cleaning that happens by itself, on the quiet, every week or every month.
///
/// Only the categories MacUtil considers safe are touched, and everything goes to the Trash,
/// so a scheduled run can be undone like any other.
@MainActor
enum ScheduledCleanup {
    enum Schedule: String, CaseIterable, Identifiable {
        case never, weekly, monthly

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .never: nil
            case .weekly: 7
            case .monthly: 30
            }
        }
    }

    static var schedule: Schedule {
        Schedule(rawValue: UserDefaults.standard.string(forKey: Preferences.cleanupSchedule) ?? "") ?? .never
    }

    /// Runs if enough days have passed. Returns what was freed, or nil when nothing ran.
    @discardableResult
    static func runIfDue(now: Date = Date()) async -> Int64? {
        guard let days = schedule.days else { return nil }
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Preferences.lastScheduledCleanup)
        if last > 0, now.timeIntervalSince1970 - last < Double(days) * 86400 { return nil }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let categories = await JunkScanner.scan(
            JunkCatalog.rules(in: .system), context: JunkContext(runningBundleIDs: running)
        )
        // Only what is safe to remove without asking: caches and logs, never anything marked
        // for review, and never the cache of an app that is running.
        let targets = categories
            .filter { $0.rule.safety == .safe }
            .flatMap(\.items)
            .filter { !$0.isInUse }
            .map { CleanupTarget(path: $0.path, size: $0.size) }
        guard !targets.isEmpty else {
            defaults.set(now.timeIntervalSince1970, forKey: Preferences.lastScheduledCleanup)
            return nil
        }

        let result = await Cleaner().clean(targets, mode: .trash, source: "schedule")
        defaults.set(now.timeIntervalSince1970, forKey: Preferences.lastScheduledCleanup)
        guard result.freedBytes > 0 else { return nil }

        Notifications.post(
            id: "scheduledCleanup",
            title: String(localized: "MacUtil cleaned up"),
            body: String(localized: "\(result.freedBytes.formatted(.byteCount(style: .file))) moved to the Trash, where you can still get it back.")
        )
        return result.freedBytes
    }
}
