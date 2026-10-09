import AppKit
import CleanerCore
import Observation
import SecurityCore
import UserNotifications

/// Samples CPU, memory, disk, network and battery for the menu bar.
@MainActor
@Observable
final class MenuBarMonitor {
    private(set) var sample = SystemStats.Sample()
    private let stats = SystemStats()
    private var timer: Task<Void, Never>?
    private var lastLowDiskWarning: Date?
    /// When each alert was last sent, so a lasting problem is mentioned once an hour.
    private var lastAlert: [String: Date] = [:]
    /// How long the processor has been busy without a break.
    private var busySince: Date?

    func start() {
        guard timer == nil else { return }
        timer = Task {
            while !Task.isCancelled {
                let stats = stats
                sample = await Task.detached { stats.sample() }.value
                checkDiskSpace()
                checkHardware()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Warns about a Mac that is working too hard: a hot machine, memory under pressure, or the
    /// processor pinned for minutes on end. Each is mentioned at most once an hour.
    private func checkHardware() {
        guard UserDefaults.standard.bool(forKey: Preferences.hardwareAlerts) else {
            busySince = nil
            return
        }
        if let temperature = sample.temperature, temperature >= 100 {
            alert(
                "temperature",
                title: String(localized: "Your Mac is running hot"),
                body: String(localized: "The warmest part is at \(Int(temperature.rounded())) °C. See what is working hard in the Task Manager.")
            )
        }
        if let memory = sample.memory {
            let pressure = Double(memory.wired + memory.compressed) / Double(max(memory.total, 1))
            if pressure >= 0.8 {
                alert(
                    "memory",
                    title: String(localized: "Memory is under pressure"),
                    body: String(localized: "macOS is squeezing memory to keep up. Closing something heavy will help.")
                )
            }
        }
        // Busy means busy for a while: a short burst is just work being done.
        if sample.cpu >= 0.85 {
            let since = busySince ?? Date()
            busySince = since
            if Date().timeIntervalSince(since) >= 600 {
                alert(
                    "cpu",
                    title: String(localized: "The processor has been busy for ten minutes"),
                    body: String(localized: "Something has been using most of the processor. The Task Manager shows what.")
                )
            }
        } else {
            busySince = nil
        }
    }

    private func alert(_ id: String, title: String, body: String) {
        if let last = lastAlert[id], Date().timeIntervalSince(last) < 3600 { return }
        lastAlert[id] = Date()
        Notifications.post(id: "alert.\(id)", title: title, body: body)
    }

    /// Warns once a day when less than 10 % (or 10 GB) of the startup disk is free.
    private func checkDiskSpace() {
        guard UserDefaults.standard.bool(forKey: Preferences.lowDiskWarning),
              let disk = sample.disk, disk.totalCapacity > 0,
              disk.availableCapacity < min(10_000_000_000, disk.totalCapacity / 10),
              lastLowDiskWarning.map({ Date().timeIntervalSince($0) > 86400 }) ?? true
        else { return }
        lastLowDiskWarning = Date()
        Notifications.post(
            id: "lowDisk",
            title: String(localized: "Your disk is almost full"),
            body: String(
                localized: "Only \(disk.availableCapacity.formatted(.byteCount(style: .file))) left. Open MacUtil to free up space."
            )
        )
    }
}

enum Preferences {
    static let showsMenuBar = "showsMenuBar"
    static let lowDiskWarning = "lowDiskWarning"
    static let reminder = "cleanupReminder"
    static let automaticUpdateCheck = "automaticUpdateCheck"
    static let hardwareAlerts = "hardwareAlerts"
    static let lastUpdateCheck = "lastUpdateCheck"
}

enum Notifications {
    static func requestPermission() async -> Bool {
        await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    enum Reminder: String, CaseIterable, Identifiable {
        case never, weekly, monthly
        var id: Self { self }
    }

    /// Replaces the repeating cleanup reminder: Mondays or the 1st of the month at 10:00.
    static func schedule(_ reminder: Reminder) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["cleanupReminder"])
        var components = DateComponents()
        components.hour = 10
        switch reminder {
        case .never: return
        case .weekly: components.weekday = 2
        case .monthly: components.day = 1
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time for a cleanup")
        content.body = String(localized: "Run Smart Scan in MacUtil to free up space and check your Mac's security.")
        center.add(UNNotificationRequest(
            identifier: "cleanupReminder", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        ))
    }
}

/// Runs the cleanup, leftovers and security scans together for the dashboard.
@MainActor
@Observable
final class SmartScanStore {
    enum Phase {
        case idle, scanning, ready, cleaning
        case cleaned(CleanupResult)
    }

    private(set) var phase = Phase.idle

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    func run(_ state: AppState) async {
        phase = .scanning
        async let system: Void = state.systemJunk.scan()
        async let developer: Void = state.developerJunk.scan()
        async let leftovers: Void = state.leftovers.scan()
        async let trash: Void = state.trash.scan()
        async let security: Void = state.security.scan()
        _ = await (system, developer, leftovers, trash, security)
        phase = .ready
    }

    /// Junk the scans preselected (safe categories, apps not running), moved to the Trash.
    func safeJunk(_ state: AppState) -> [CleanupTarget] {
        [state.systemJunk, state.developerJunk, state.leftovers].flatMap { store in
            store.selectedItems.map { CleanupTarget(path: $0.path, size: $0.size) }
        }
    }

    func cleanSafeJunk(_ state: AppState) async {
        let targets = safeJunk(state)
        guard !targets.isEmpty else { return }
        phase = .cleaning
        let result = await Cleaner().clean(targets, mode: .trash, source: "smartScan")
        phase = .cleaned(result)
        await state.systemJunk.scan()
        await state.developerJunk.scan()
        await state.leftovers.scan()
    }
}

@MainActor
@Observable
final class UpdaterStore {
    enum Phase {
        case idle, checking, ready
    }

    private(set) var phase = Phase.idle
    private(set) var updates: [AppUpdate] = []
    private(set) var appCount = 0
    private(set) var upgrading = Set<AppUpdate.ID>()
    private(set) var messages: [AppUpdate.ID: String] = [:]

    var hasHomebrew: Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew") || FileManager.default
            .isExecutableFile(atPath: "/usr/local/bin/brew")
    }

    var hasMas: Bool {
        FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/mas") || FileManager.default
            .isExecutableFile(atPath: "/usr/local/bin/mas")
    }

    func check() async {
        phase = .checking
        let apps = await AppCatalog.scan()
        appCount = apps.count
        updates = await AppUpdates.check(apps: apps)
        phase = .ready
    }

    func update(_ update: AppUpdate) async {
        switch update.source {
        case let .homebrew(cask):
            upgrading.insert(update.id)
            let output = await AppUpdates.upgrade(cask: cask)
            upgrading.remove(update.id)
            if output?.status == 0 {
                updates.removeAll { $0.id == update.id }
            } else {
                messages[update.id] = output?.text.split(separator: "\n").last
                    .map(String.init) ?? String(localized: "Update failed")
            }
        case .sparkle:
            // The app downloads and installs the update itself when opened.
            NSWorkspace.shared.open(URL(filePath: update.appPath))
        case let .appStore(id):
            if let url = URL(string: "macappstore://apps.apple.com/app/id\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
