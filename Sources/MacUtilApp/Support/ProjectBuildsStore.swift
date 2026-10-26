import CleanerCore
import Foundation
import Observation

/// Build output sitting inside project folders.
@MainActor
@Observable
final class ProjectBuildsStore {
    enum Phase {
        case idle, scanning, ready, cleaning
        case done(CleanupResult)
    }

    private(set) var phase = Phase.idle
    private(set) var artifacts: [BuildArtifact] = []
    /// Folders that were just taken out of Time Machine, to say so on screen.
    private(set) var excluded = Set<String>()
    var selection = Set<String>()

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    /// Grouped by project, biggest project first.
    var byProject: [(project: String, path: String, artifacts: [BuildArtifact])] {
        Dictionary(grouping: artifacts, by: \.projectPath)
            .map { (project: ($0.key as NSString).lastPathComponent, path: $0.key, artifacts: $0.value) }
            .sorted { size(of: $0.artifacts) > size(of: $1.artifacts) }
    }

    var totalSize: Int64 { size(of: artifacts) }
    var selectedSize: Int64 { size(of: artifacts.filter { selection.contains($0.id) }) }

    private func size(of artifacts: [BuildArtifact]) -> Int64 {
        artifacts.reduce(0) { $0 + $1.size }
    }

    func scan() async {
        phase = .scanning
        artifacts = await ProjectBuilds.scan()
        // Only what a single command rebuilds starts selected.
        selection = Set(artifacts.filter(\.isSafe).map(\.id))
        phase = .ready
    }

    func toggle(_ artifact: BuildArtifact) {
        if selection.contains(artifact.id) { selection.remove(artifact.id) } else { selection.insert(artifact.id) }
    }

    func toggle(project path: String) {
        let ids = artifacts.filter { $0.projectPath == path }.map(\.id)
        if ids.allSatisfy(selection.contains) {
            ids.forEach { selection.remove($0) }
        } else {
            ids.forEach { selection.insert($0) }
        }
    }

    func clean() async {
        let chosen = artifacts.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        let targets = chosen.map { CleanupTarget(path: $0.path, size: $0.size) }
        let result = await Cleaner().clean(targets, mode: .trash, source: "projects")
        selection = []
        phase = .done(result)
    }

    /// Keeps the chosen folders out of Time Machine instead of removing them.
    ///
    /// A different job from cleaning: no disk space comes back, but the backups stop
    /// carrying folders that a single command would rebuild.
    func excludeFromBackups() async {
        let chosen = artifacts.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        phase = .cleaning
        excluded = await BackupExclusions.setExcluded(true, paths: chosen.map(\.path))
            ? Set(chosen.map(\.path)) : []
        phase = .ready
    }

    func finish() async {
        phase = .idle
        await scan()
    }
}
