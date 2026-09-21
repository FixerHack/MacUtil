import AppKit
import CleanerCore
import Observation

@MainActor
@Observable
final class SearchStore {
    enum Phase {
        case idle, searching, ready
        case failed(String)
    }

    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, day = 1, week = 7, month = 30, year = 365

        var id: Self { self }
    }

    var query = SearchQuery()
    var age = Age.any
    private(set) var folder = FileManager.default.homeDirectoryForCurrentUser
    private(set) var phase = Phase.idle
    private(set) var hits: [SearchHit] = []
    private(set) var progress = SearchProgress()
    private(set) var duration: Duration?
    private var search: DeepSearch?

    var isSearching: Bool {
        if case .searching = phase {
            true
        } else {
            false
        }
    }

    func run() async {
        search?.cancel()
        let search = DeepSearch()
        self.search = search
        var query = query
        query.modifiedWithinDays = age == .any ? nil : age.rawValue
        phase = .searching
        progress = SearchProgress()
        let start = ContinuousClock.now

        let poller = Task {
            while !Task.isCancelled {
                progress = search.progress
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        do {
            let found = try await search.run(query, in: folder)
            guard self.search === search else { return }
            hits = found
            duration = ContinuousClock.now - start
            phase = .ready
        } catch is CancellationError {
            if self.search === search {
                phase = hits.isEmpty ? .idle : .ready
            }
        } catch {
            if self.search === search {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        search?.cancel()
    }

    func use(_ url: URL) {
        folder = url
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    func moveToTrash(_ paths: [String]) async -> CleanupResult {
        let targets = hits.filter { paths.contains($0.path) }.map { CleanupTarget(path: $0.path, size: $0.size) }
        let result = await Cleaner().clean(targets, mode: .trash, source: "search")
        let removed = Set(result.removed.map(\.path))
        hits.removeAll { removed.contains($0.path) }
        return result
    }
}
