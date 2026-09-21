import AppKit
import CleanerCore
import Observation
import SecurityCore

@MainActor
@Observable
final class MaintenanceStore {
    var selection = Set<MaintenanceTask.ID>()
    private(set) var running = false
    private(set) var results: [MaintenanceTask.ID: AdminRunner.Output] = [:]

    func run() async {
        let tasks = MaintenanceCatalog.all.filter { selection.contains($0.id) }
        guard !tasks.isEmpty else { return }
        running = true
        results = [:]
        results = await MaintenanceCatalog.run(tasks)
        running = false
    }
}

@MainActor
@Observable
final class HiddenSettingsStore {
    private(set) var values: [HiddenSetting.ID: HiddenSetting.Value] = [:]
    private(set) var busy = Set<HiddenSetting.ID>()

    func load() {
        values = [:]
        for setting in HiddenSettings.all {
            if let value = HiddenSettings.currentValue(of: setting) {
                values[setting.id] = value
            }
        }
    }

    func isOn(_ setting: HiddenSetting) -> Bool {
        values[setting.id] == setting.options.first?.value
    }

    /// Nil means the macOS default.
    func set(_ value: HiddenSetting.Value?, for setting: HiddenSetting) async {
        busy.insert(setting.id)
        await HiddenSettings.apply(value, to: setting)
        busy.remove(setting.id)
        values[setting.id] = HiddenSettings.currentValue(of: setting)
    }

    var changedCount: Int {
        HiddenSettings.all.filter { values[$0.id] != nil }.count
    }

    func resetAll() async {
        for setting in HiddenSettings.all where values[setting.id] != nil {
            await set(nil, for: setting)
        }
    }
}

@MainActor
@Observable
final class ProcessesStore {
    private(set) var processes: [RunningProcess] = []
    private(set) var memory: MemoryStats?
    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        timer = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() async {
        processes = await ProcessMonitor.processes()
        memory = ProcessMonitor.memory()
    }

    func quit(_ process: RunningProcess, force: Bool) async {
        // Apps get a proper quit request so they can save their work.
        if !force, let app = NSRunningApplication(processIdentifier: process.pid) {
            app.terminate()
        } else {
            _ = ProcessMonitor.terminate(process.pid, force: force)
        }
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }
}

@MainActor
@Observable
final class LoginItemsStore {
    private(set) var items: [PersistenceItem] = []
    private(set) var loading = false
    private(set) var busy = Set<PersistenceItem.ID>()
    private(set) var lastError: String?

    func load() async {
        loading = true
        var scanner = PersistenceScanner()
        scanner.includesCron = false
        items = await scanner.scan().filter { $0.kind != .kernelExtension }
        loading = false
    }

    func setEnabled(_ enabled: Bool, for item: PersistenceItem) async {
        busy.insert(item.id)
        lastError = nil
        if item.kind == .daemon, let plist = item.location {
            let output = await LaunchControl.setDaemonEnabled(enabled, label: item.label, plist: plist)
            if !output.succeeded, !output.wasCancelled {
                lastError = output.text
            }
        } else {
            _ = await LaunchControl.setEnabled(enabled, label: item.label, plist: item.location)
        }
        busy.remove(item.id)
        await load()
    }
}
