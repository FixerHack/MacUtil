import CleanerCore
import Foundation
import Observation

/// Everything MacUtil has removed or restored, read back from the action log.
@MainActor
@Observable
final class HistoryStore {
    /// One recorded cleanup. The log has no identifiers of its own, so the
    /// position in the file serves as one.
    struct Record: Identifiable {
        let id: Int
        let entry: ActionLog.Entry

        var date: Date { entry.date }
        var freedBytes: Int64 { entry.freedBytes }
    }

    struct Day: Identifiable {
        let date: Date
        let records: [Record]

        var id: Date { date }
        var freedBytes: Int64 { records.reduce(0) { $0 + $1.freedBytes } }
    }

    private(set) var days: [Day] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var expanded = Set<Int>()

    private let log: ActionLog

    init(log: ActionLog = .standard) {
        self.log = log
    }

    var isEmpty: Bool { days.isEmpty }

    /// Everything removed, minus everything put back.
    var freedBytes: Int64 {
        days.reduce(0) { total, day in
            total + day.records.reduce(0) { $0 + ($1.entry.action == "restore" ? -$1.freedBytes : $1.freedBytes) }
        }
    }

    var itemCount: Int {
        days.reduce(0) { $0 + $1.records.reduce(0) { $0 + $1.entry.removed.count } }
    }

    func load() async {
        isLoading = true
        let entries = await Task.detached(priority: .userInitiated) { [log] in log.entries() }.value
        let calendar = Calendar.current
        let records = entries.enumerated().map { Record(id: $0.offset, entry: $0.element) }
        days = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
            .map { Day(date: $0.key, records: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
        isLoading = false
        hasLoaded = true
    }

    func toggle(_ record: Record) {
        if expanded.contains(record.id) { expanded.remove(record.id) } else { expanded.insert(record.id) }
    }

    func clear() async {
        log.clear()
        expanded = []
        await load()
    }
}

extension ActionLog.Entry {
    /// What the cleanup was, in words. Sources are ids like "junk.system" or
    /// "uninstall.com.example.App".
    var sourceTitle: LocalizedStringResource {
        switch source {
        case "junk.system": "System Junk"
        case "junk.developer": "Developer Junk"
        case "junk.privacy": "Privacy"
        case "junk.leftovers": "Leftovers"
        case "trash.empty": "Trash Bins"
        case "smartScan": "Smart Scan"
        case "schedule": "Scheduled cleanup"
        case "messengers": "Messenger Downloads"
        case "duplicates": "Duplicates"
        case "installers": "Installer Files"
        case "projects": "Project Build Files"
        case "search": "Deep Search"
        case "undo": "Undo"
        default: source.hasPrefix("uninstall.") ? "Uninstaller" : "Cleanup"
        }
    }

    /// Where the removed items went.
    var actionTitle: LocalizedStringResource {
        switch action {
        case "trash": "Moved to the Trash"
        case "delete": "Deleted"
        default: "Put back"
        }
    }

    var symbol: String {
        switch action {
        case "trash": "trash"
        case "delete": "xmark.bin"
        default: "arrow.uturn.backward"
        }
    }
}
