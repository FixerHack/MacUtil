import CleanerCore
import Foundation
import Observation

/// Disk images and packages left behind after installing something.
@MainActor
@Observable
final class InstallerStore {
    enum Phase {
        case idle, scanning, ready, cleaning
        case done(CleanupResult)
    }

    private(set) var phase = Phase.idle
    private(set) var files: [InstallerFile] = []
    var selection = Set<String>()

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    /// Installers whose app is already in place, and the rest.
    var spent: [InstallerFile] { files.filter(\.isSpent) }
    var unmatched: [InstallerFile] { files.filter { !$0.isSpent } }

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        phase = .scanning
        files = await InstallerFiles.scan()
        // Only the ones whose app is installed start selected; the rest may still be wanted.
        selection = Set(spent.map(\.id))
        phase = .ready
    }

    func toggle(_ file: InstallerFile) {
        if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
    }

    func toggleAll(_ group: [InstallerFile]) {
        let ids = group.map(\.id)
        if ids.allSatisfy(selection.contains) {
            ids.forEach { selection.remove($0) }
        } else {
            ids.forEach { selection.insert($0) }
        }
    }

    func clean() async {
        let chosen = files.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        let targets = chosen.map { CleanupTarget(path: $0.path, size: $0.size) }
        let result = await Cleaner().clean(targets, mode: .trash, source: "installers")
        selection = []
        phase = .done(result)
    }

    func finish() async {
        phase = .idle
        await scan()
    }
}
