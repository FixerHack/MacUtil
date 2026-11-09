import AppKit
import CleanerCore
import EventKit
import Foundation
import Observation

/// The next event from the person's calendars, once they allow it.
@MainActor
@Observable
final class CalendarFeed {
    struct Event: Equatable {
        let title: String
        let start: Date
        let end: Date
        let calendar: String
    }

    enum Access: Equatable { case unknown, granted, denied }

    static let key = "islandCalendar"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            if isEnabled { requestAccess() } else { next = nil }
        }
    }

    private(set) var next: Event?
    private(set) var access: Access = .unknown
    /// The time at the last look, so "soon" is worked out again every minute.
    private(set) var now = Date()

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        access = Self.currentAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .unknown
        default: .denied
        }
    }

    /// An event starting within ten minutes, worth the wings.
    var soon: Event? {
        guard let next else { return nil }
        let wait = next.start.timeIntervalSince(now)
        return wait > -60 && wait < 10 * 60 ? next : nil
    }

    func setRunning(_ running: Bool) {
        if running, isEnabled {
            guard loop == nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        } else {
            loop?.cancel()
            loop = nil
        }
    }

    func requestAccess() {
        guard Self.currentAccess() == .unknown else {
            access = Self.currentAccess()
            refresh()
            return
        }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.access = granted ? .granted : .denied
                self?.refresh()
            }
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        now = Date()
        let current = Self.currentAccess()
        if current != access { access = current }
        guard isEnabled, access == .granted else {
            if next != nil { next = nil }
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
        let event = upcoming.map {
            Event(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, calendar: $0.calendar?.title ?? "")
        }
        if event != next { next = event }
    }
}

/// The charge of this Mac and of the keyboard, mouse and earbuds paired with it.
@MainActor
@Observable
final class BatteriesFeed {
    static let key = "islandBatteries"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            if isEnabled { refresh() } else { devices = [] }
        }
    }

    private(set) var devices: [DeviceBattery] = []

    @ObservationIgnored private var headphones: [DeviceBattery] = []
    @ObservationIgnored private var askedProfiler: Date?

    init() {
        UserDefaults.standard.register(defaults: [Self.key: true])
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// The quick ones at once; earbuds, which take macOS a second or two to report, at most
    /// once a minute and a half.
    func refresh() {
        guard isEnabled else { return }
        publish()
        if let askedProfiler, Date().timeIntervalSince(askedProfiler) < 90 { return }
        askedProfiler = Date()
        Task { [weak self] in
            guard let output = await Command.run(
                "/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: .seconds(20)
            ), output.status == 0 else { return }
            let found = Batteries.headphones(fromSystemProfiler: Data(output.text.utf8))
            self?.headphones = found
            self?.publish()
        }
    }

    private func publish() {
        let all = [Batteries.mac()].compactMap { $0 } + Batteries.accessories() + headphones
        if all != devices { devices = all }
    }
}
