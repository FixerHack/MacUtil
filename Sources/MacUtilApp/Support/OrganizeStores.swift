import AppKit
import CleanerCore
import Foundation
import Observation

/// Folders kept in order by rules.
@MainActor
@Observable
final class OrganizeStore {
    enum Phase {
        case idle, planning, preview, working
        case done(OrganizeResult)
    }

    private(set) var folders: [WatchedFolder] = []
    private(set) var phase = Phase.idle
    private(set) var plan: [PlannedMove] = []
    /// The last sort, kept so it can be undone.
    private(set) var lastResult: OrganizeResult?
    var selection: WatchedFolder.ID?

    private var watchers: [WatchedFolder.ID: FolderWatcher] = [:]

    var isBusy: Bool {
        switch phase {
        case .planning, .working: true
        default: false
        }
    }

    var current: WatchedFolder? {
        folders.first { $0.id == selection }
    }

    /// The plan grouped by the folder each file is going to.
    var planByFolder: [(folder: String, moves: [PlannedMove])] {
        Dictionary(grouping: plan, by: \.folder)
            .map { (folder: $0.key, moves: $0.value) }
            .sorted { $0.folder < $1.folder }
    }

    func load() {
        folders = OrganizeStore.stored()
        if selection == nil { selection = folders.first?.id }
        startWatching()
    }

    private static func stored() -> [WatchedFolder] {
        CleanerCore.OrganizeStore.load()
    }

    private func save() {
        CleanerCore.OrganizeStore.save(folders)
        startWatching()
    }

    // MARK: - Folders

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to keep in order.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        guard !folders.contains(where: { $0.path == path }) else { return }

        // A new folder starts with the ready-made rules; they are the point of the feature.
        var folder = WatchedFolder(path: path)
        folder.extensionRules = FolderOrganizer.presets
        folders.append(folder)
        selection = folder.id
        save()
    }

    func removeFolder(_ folder: WatchedFolder) {
        watchers[folder.id]?.stop()
        watchers[folder.id] = nil
        folders.removeAll { $0.id == folder.id }
        if selection == folder.id { selection = folders.first?.id }
        plan = []
        phase = .idle
        save()
    }

    func update(_ folder: WatchedFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        save()
    }

    // MARK: - Rules

    func addExtensionRule(to folder: WatchedFolder) {
        var updated = folder
        updated.extensionRules.append(ExtensionRule(extensions: "", destination: ""))
        update(updated)
    }

    func addNameRule(to folder: WatchedFolder) {
        var updated = folder
        updated.nameRules.append(NameRule(pattern: "", destination: ""))
        update(updated)
    }

    func addPresets(to folder: WatchedFolder) {
        var updated = folder
        let existing = Set(updated.extensionRules.map(\.destination))
        updated.extensionRules += FolderOrganizer.presets.filter { !existing.contains($0.destination) }
        update(updated)
    }

    // MARK: - Sorting

    func preview() async {
        guard let folder = current else { return }
        phase = .planning
        plan = await Task.detached { FolderOrganizer.plan(folder) }.value
        phase = .preview
    }

    func organize() async {
        guard !plan.isEmpty else { return }
        phase = .working
        let result = await FolderOrganizer.apply(plan)
        lastResult = result.moved.isEmpty ? nil : result
        plan = []
        phase = .done(result)
    }

    func undoLast() async {
        guard let result = lastResult else { return }
        phase = .working
        _ = await FolderOrganizer.undo(result)
        lastResult = nil
        phase = .idle
        await preview()
    }

    func finish() {
        phase = .idle
        plan = []
    }

    // MARK: - Watching

    /// Watches the folders set to sort themselves, and stops watching the rest.
    private func startWatching() {
        for folder in folders {
            if folder.organizesAutomatically, watchers[folder.id] == nil {
                let watcher = FolderWatcher(path: folder.path) { [weak self] in
                    Task { @MainActor in await self?.organizeInBackground(folder.id) }
                }
                watcher.start()
                watchers[folder.id] = watcher
            } else if !folder.organizesAutomatically, let watcher = watchers[folder.id] {
                watcher.stop()
                watchers[folder.id] = nil
            }
        }
        // Folders that are gone take their watcher with them.
        let known = Set(folders.map(\.id))
        for (id, watcher) in watchers where !known.contains(id) {
            watcher.stop()
            watchers[id] = nil
        }
    }

    /// Sorting nobody asked for just now, so it waits rather than moving files out from
    /// under a plan someone is reading.
    private func organizeInBackground(_ id: WatchedFolder.ID) async {
        guard !isBusy else { return }
        if case .preview = phase, selection == id { return }
        await runAutomatically(id)
    }

    private func runAutomatically(_ id: WatchedFolder.ID) async {
        guard let folder = folders.first(where: { $0.id == id }), folder.organizesAutomatically else { return }
        let moves = await Task.detached { FolderOrganizer.plan(folder) }.value
        guard !moves.isEmpty else { return }
        let result = await FolderOrganizer.apply(moves)
        guard !result.moved.isEmpty else { return }
        lastResult = result
        Notifications.post(
            id: "organize-\(id)",
            title: String(localized: "Folder sorted"),
            body: String(localized: "\(result.moved.count) files were filed in \(folder.name).")
        )
    }
}
