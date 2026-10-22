import AppKit
import CleanerCore
import Foundation
import Observation

/// Apps carrying code for an architecture this Mac never runs.
@MainActor
@Observable
final class SlimmingStore {
    enum Phase {
        case idle, scanning, ready, working
    }

    struct Outcome: Identifiable {
        let id: String
        let name: String
        let freed: Int64
        let problem: LocalizedStringResource?
    }

    private(set) var phase = Phase.idle
    private(set) var apps: [SlimmableApp] = []
    private(set) var outcomes: [Outcome] = []
    /// The app being worked on right now.
    private(set) var current: String?
    var selection = Set<String>()

    var isBusy: Bool {
        switch phase {
        case .scanning, .working: true
        default: false
        }
    }

    var totalSavings: Int64 { apps.reduce(0) { $0 + $1.savings } }
    var selectedSavings: Int64 { apps.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.savings } }
    var freedSoFar: Int64 { outcomes.reduce(0) { $0 + $1.freed } }

    /// Apps running right now; their files must not be swapped underneath them.
    private var runningPaths: Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path(percentEncoded: false) })
    }

    func isRunning(_ app: SlimmableApp) -> Bool { runningPaths.contains(app.path) }

    func canSlim(_ app: SlimmableApp) -> Bool { app.isWritable && !isRunning(app) }

    func scan() async {
        phase = .scanning
        outcomes = []
        apps = await AppSlimming.scan()
        // Nothing is selected by default: this cannot be undone without reinstalling.
        selection = []
        phase = .ready
    }

    func toggle(_ app: SlimmableApp) {
        guard canSlim(app) else { return }
        if selection.contains(app.id) { selection.remove(app.id) } else { selection.insert(app.id) }
    }

    func selectAll() {
        let allowed = apps.filter(canSlim).map(\.id)
        selection = Set(allowed).count == selection.count ? [] : Set(allowed)
    }

    func slim() async {
        let chosen = apps.filter { selection.contains($0.id) && canSlim($0) }
        guard !chosen.isEmpty else { return }
        phase = .working
        outcomes = []
        for app in chosen {
            current = app.name
            switch await AppSlimming.slim(app) {
            case let .success(freed):
                outcomes.append(Outcome(id: app.id, name: app.name, freed: freed, problem: nil))
            case let .failure(failure):
                outcomes.append(Outcome(id: app.id, name: app.name, freed: 0, problem: describe(failure)))
            }
        }
        current = nil
        selection = []
        await scan()
    }

    private func describe(_ failure: AppSlimming.Failure) -> LocalizedStringResource {
        switch failure {
        case .notWritable: "Needs an administrator to change"
        case .running: "The app was running"
        case .nothingToRemove: "Nothing left to remove"
        case .signatureBroken: "The signature would have broken, so nothing was changed"
        case let .failed(reason): "Did not finish: \(reason)"
        }
    }
}
