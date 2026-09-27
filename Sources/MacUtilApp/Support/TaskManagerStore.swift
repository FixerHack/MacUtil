import AppKit
import CleanerCore
import Foundation
import Observation

/// Live list of everything running, with the machine's load, refreshed while the screen is open.
@MainActor
@Observable
final class TaskManagerStore {
    enum Column: String, CaseIterable, Identifiable {
        case cpu, memory, disk, name, pid

        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, mine, apps, busy

        var id: String { rawValue }
    }

    struct Details: Sendable, Equatable {
        var arguments: String?
        var openFiles: [String] = []
        var signature: String?
    }

    private(set) var processes: [TaskProcess] = []
    private(set) var load = SystemLoad()
    /// Recent CPU share of each process, for the little graphs.
    private(set) var history: [Int32: [Double]] = [:]
    private(set) var details: Details?
    private(set) var busyPIDs = Set<Int32>()
    private(set) var pausedPIDs = Set<Int32>()
    private(set) var lastError: String?

    var selection: Int32?
    var search = ""
    var sortBy = Column.cpu
    var filter = Filter.all
    var groupsByApp = true

    private var timer: Task<Void, Never>?
    private var previousDiskBytes: [Int32: (read: Int64, written: Int64)] = [:]
    private let manager = TaskManager()

    var selected: TaskProcess? {
        processes.first { $0.pid == selection }
    }

    /// The rows the list shows: filtered, searched and sorted.
    var visible: [TaskProcess] {
        var result = processes
        switch filter {
        case .all: break
        case .mine: result = result.filter(\.isOwnedByUser)
        case .apps: result = result.filter(\.isApp)
        case .busy: result = result.filter { $0.cpu >= 1 || $0.memory > 500_000_000 }
        }
        if !search.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(search) || "\($0.pid)" == search
            }
        }
        return result.sorted { first, second in
            switch sortBy {
            case .cpu: first.cpu > second.cpu
            case .memory: first.memory > second.memory
            case .disk: (first.diskRead + first.diskWritten) > (second.diskRead + second.diskWritten)
            case .name: first.name.localizedStandardCompare(second.name) == .orderedAscending
            case .pid: first.pid < second.pid
            }
        }
    }

    /// Helper processes shown under the app they belong to.
    func children(of process: TaskProcess) -> [TaskProcess] {
        guard groupsByApp else { return [] }
        return processes.filter { $0.parentPID == process.pid && $0.pid != process.pid }
            .sorted { $0.cpu > $1.cpu }
    }

    var topByCPU: [TaskProcess] {
        processes.sorted { $0.cpu > $1.cpu }.prefix(3).map { $0 }
    }

    var topByMemory: [TaskProcess] {
        processes.sorted { $0.memory > $1.memory }.prefix(3).map { $0 }
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() async {
        let (processes, load) = await manager.sample(previous: previousDiskBytes, interval: 2)
        self.processes = processes
        self.load = load
        previousDiskBytes = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, ($0.diskRead, $0.diskWritten)) })

        // Keep a minute of history for the graphs, and forget processes that ended.
        let alive = Set(processes.map(\.pid))
        history = history.filter { alive.contains($0.key) }
        for process in processes {
            var samples = history[process.pid] ?? []
            samples.append(process.cpu)
            if samples.count > 30 { samples.removeFirst(samples.count - 30) }
            history[process.pid] = samples
        }
        pausedPIDs = Set(processes.filter { $0.state == .stopped }.map(\.pid))
        if let selection, alive.contains(selection) {} else if selection != nil {
            self.selection = nil
            details = nil
        }
    }

    // MARK: - Acting on a process

    func quit(_ process: TaskProcess, force: Bool) async {
        busyPIDs.insert(process.pid)
        defer { busyPIDs.remove(process.pid) }
        lastError = nil

        // Apps get a normal quit first so they can save open documents.
        if !force, let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        } else if !TaskManager.send(force ? .forceQuit : .quit, to: process.pid) {
            lastError = String(
                localized: "\(process.name) belongs to another user, so macOS did not let MacUtil stop it."
            )
        }
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    /// Freezes a process without losing its work, and lets it go again.
    func setPaused(_ paused: Bool, _ process: TaskProcess) async {
        busyPIDs.insert(process.pid)
        defer { busyPIDs.remove(process.pid) }
        lastError = nil
        if !TaskManager.send(paused ? .pause : .resume, to: process.pid) {
            lastError = String(localized: "macOS did not let MacUtil pause \(process.name).")
        }
        try? await Task.sleep(for: .milliseconds(300))
        await refresh()
    }

    func setPriority(_ niceness: Int32, for process: TaskProcess) async {
        busyPIDs.insert(process.pid)
        defer { busyPIDs.remove(process.pid) }
        if await !TaskManager.setPriority(niceness, for: process.pid) {
            lastError = String(localized: "The priority of \(process.name) could not be changed.")
        }
        await refresh()
    }

    func loadDetails(for process: TaskProcess) async {
        details = nil
        async let arguments = TaskManager.arguments(pid: process.pid)
        async let files = TaskManager.openFiles(pid: process.pid)
        details = await Details(arguments: arguments, openFiles: files, signature: nil)
    }

    /// Writes a CPU sample of the process to a file and shows it in Finder.
    func saveSample(of process: TaskProcess) async {
        busyPIDs.insert(process.pid)
        defer { busyPIDs.remove(process.pid) }
        guard let text = await TaskManager.sampleStack(pid: process.pid) else {
            lastError = String(localized: "The sample could not be taken.")
            return
        }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Desktop/\(process.name)-sample.txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)
        FinderActions.reveal([file.path])
    }
}
