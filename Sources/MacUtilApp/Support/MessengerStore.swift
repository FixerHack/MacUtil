import CleanerCore
import Foundation
import Observation

/// What messaging apps have downloaded and kept, and how much of it can go.
@MainActor
@Observable
final class MessengerStore {
    enum Age: Int, CaseIterable, Identifiable {
        case everything = 0
        case week = 7
        case month = 30
        case threeMonths = 90
        case year = 365

        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue) * 86400 }
    }

    enum Phase {
        case idle, scanning, ready, cleaning
        case done(CleanupResult)
    }

    private(set) var phase = Phase.idle
    private(set) var files: [MessengerFile] = []
    var selection = Set<String>()
    var age = Age.month

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    var byApp: [(app: String, files: [MessengerFile])] {
        Dictionary(grouping: files, by: \.app)
            .map { (app: $0.key, files: $0.value) }
            .sorted { $0.files.reduce(0) { $0 + $1.size } > $1.files.reduce(0) { $0 + $1.size } }
    }

    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    var selectedSize: Int64 {
        files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scan() async {
        phase = .scanning
        files = await MessengerDownloads.scan(olderThan: age.seconds)
        // Everything found is older than the cut-off, so it all starts selected.
        selection = Set(files.map(\.id))
        phase = .ready
    }

    func toggle(_ file: MessengerFile) {
        if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
    }

    func toggle(app: String) {
        let ids = files.filter { $0.app == app }.map(\.id)
        if ids.allSatisfy(selection.contains) {
            ids.forEach { selection.remove($0) }
        } else {
            ids.forEach { selection.insert($0) }
        }
    }

    /// Moves the chosen files to the Trash, where they can be fished out again.
    func clean() async {
        let chosen = files.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        let targets = chosen.map { CleanupTarget(path: $0.path, size: $0.size) }
        let result = await Cleaner().clean(targets, mode: .trash, source: "messengers")
        selection = []
        phase = .done(result)
    }

    func finish() async {
        phase = .idle
        await scan()
    }
}
