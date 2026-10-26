import AppKit
import CleanerCore
import Foundation
import Observation

/// Watches the clipboard while the history is switched on.
@MainActor
@Observable
final class ClipboardStore {
    private(set) var entries: [ClipboardEntry] = []
    private(set) var isWatching = false
    var search = ""

    private var task: Task<Void, Never>?
    private var lastChangeCount = NSPasteboard.general.changeCount

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: ClipboardHistory.enabledKey)
    }

    var shown: [ClipboardEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    func start() {
        entries = ClipboardHistory.load()
        guard isEnabled, task == nil else { return }
        isWatching = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isWatching = false
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ClipboardHistory.enabledKey)
        if enabled {
            lastChangeCount = NSPasteboard.general.changeCount
            start()
        } else {
            stop()
        }
    }

    private func check() async {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // The app in front when something is copied is almost always the one it came from.
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        guard let entry = ClipboardHistory.current(pasteboard, source: source) else { return }
        entries = ClipboardHistory.adding(entry, to: entries)
        ClipboardHistory.save(entries)
    }

    func copy(_ entry: ClipboardEntry) {
        // Our own write must not come straight back in as a new entry.
        ClipboardHistory.copy(entry)
        lastChangeCount = NSPasteboard.general.changeCount
        entries = ClipboardHistory.adding(entry, to: entries)
        ClipboardHistory.save(entries)
    }

    func remove(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        ClipboardHistory.save(entries)
    }

    func forgetEverything() {
        entries = []
        ClipboardHistory.forget()
    }
}
