import AppKit
import CleanerCore
import Observation

@MainActor
@Observable
final class DuplicatesStore {
    enum Phase {
        case idle, searching, ready, removing
        case done(CleanupResult)
    }

    enum MinimumSize: Int64, CaseIterable, Identifiable {
        case kb100 = 100_000
        case mb1 = 1_000_000
        case mb10 = 10_000_000
        case mb100 = 100_000_000

        var id: Self { self }
    }

    private(set) var phase = Phase.idle
    private(set) var groups: [DuplicateGroup] = []
    private(set) var progress = DuplicateProgress()
    private(set) var folder = FileManager.default.homeDirectoryForCurrentUser
    var minimumSize = MinimumSize.mb1
    var selection = Set<DuplicateFile.ID>()
    private var finder: DuplicateFinder?

    var isSearching: Bool {
        if case .searching = phase {
            true
        } else {
            false
        }
    }

    var reclaimableSize: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableSize }
    }

    var selectedFreedSpace: Int64 {
        groups.reduce(0) { total, group in
            let removing = Set(group.files.map(\.path)).intersection(selection)
            return total + (removing.isEmpty ? 0 : group.freedSpace(removing: removing))
        }
    }

    func search() async {
        // App data in ~/Library is not the user's files; duplicates there are intentional.
        let home = NSHomeDirectory()
        let finder = DuplicateFinder(
            minimumSize: minimumSize.rawValue,
            excludedPaths: [home + "/Library", home + "/.Trash"]
        )
        self.finder = finder
        groups = []
        selection = []
        progress = DuplicateProgress()
        phase = .searching

        let poller = Task {
            while !Task.isCancelled {
                progress = finder.progress
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        do {
            let found = try await finder.find(in: folder)
            guard self.finder === finder else { return }
            groups = found
            select(.keepOldest)
            phase = .ready
        } catch {
            if self.finder === finder {
                phase = .idle
            }
        }
    }

    func cancel() {
        finder?.cancel()
    }

    func chooseFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            await search()
        }
    }

    func select(_ rule: DuplicateSelection) {
        selection = Set(groups.flatMap { rule.filesToRemove(in: $0).map(\.id) })
    }

    /// Whether the file can be selected without removing every copy of it.
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        selection.contains(file.id) || group.files.filter { !selection.contains($0.id) }.count > 1
    }

    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else if canSelect(file, in: group) {
            selection.insert(file.id)
        }
    }

    func remove() async {
        let targets = groups.flatMap { group in
            group.files.filter { selection.contains($0.id) }.map { CleanupTarget(path: $0.path, size: $0.privateSize) }
        }
        guard !targets.isEmpty else { return }
        phase = .removing
        let result = await Cleaner().clean(targets, mode: .trash, source: "duplicates")
        phase = .done(result)
    }

    func undo(_ result: CleanupResult) async {
        phase = .removing
        _ = await Cleaner().undo(result)
        await search()
    }
}
