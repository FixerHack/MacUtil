import CleanerCore
import Foundation
import Observation

/// Settings zsh, Git and ssh already have, switched from one place.
@MainActor
@Observable
final class TerminalStore {
    private(set) var enabled = Set<String>()
    private(set) var isBusy = false
    private(set) var hasLoaded = false
    private(set) var problem: String?

    var options: [TerminalOption.Place: [TerminalOption]] {
        Dictionary(grouping: TerminalSettings.all, by: \.place)
    }

    func load() async {
        enabled = await TerminalSettings.enabled()
        hasLoaded = true
    }

    func isOn(_ option: TerminalOption) -> Bool { enabled.contains(option.id) }

    func toggle(_ option: TerminalOption) async {
        var wanted = enabled
        if wanted.contains(option.id) { wanted.remove(option.id) } else { wanted.insert(option.id) }
        await apply(wanted)
    }

    func turnOffEverything() async {
        await apply([])
    }

    private func apply(_ wanted: Set<String>) async {
        isBusy = true
        problem = nil
        do {
            try await TerminalSettings.apply(wanted)
        } catch {
            problem = (error as NSError).localizedDescription
        }
        // Read the files back rather than trusting the switch.
        await load()
        isBusy = false
    }
}
