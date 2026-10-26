import CleanerCore
import Foundation
import Observation

/// Extensions, plug-ins, software needing Rosetta, and files iCloud already holds.
@MainActor
@Observable
final class AddOnStore {
    enum Tab: String, CaseIterable, Identifiable {
        case extensions, plugins, rosetta, cloud
        var id: Self { self }
    }

    var tab = Tab.extensions
    private(set) var isBusy = false
    private(set) var loaded = Set<Tab>()

    private(set) var extensions: [AppExtension] = []
    private(set) var plugins: [SystemPlugin] = []
    private(set) var translated: [TranslatedApp] = []
    private(set) var cloudFiles: [CloudFile] = []
    var cloudSelection = Set<String>()
    private(set) var cloudFreed: Int64 = 0

    /// Apple's own are shown apart: there are hundreds, and none of them is a choice.
    var theirExtensions: [AppExtension] { extensions.filter { !$0.isApple } }
    var appleExtensions: [AppExtension] { extensions.filter(\.isApple) }

    var cloudSelectedSize: Int64 {
        cloudFiles.filter { cloudSelection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var isCloudAvailable: Bool { CloudFiles.isAvailable }
    var isRosettaRelevant: Bool { RosettaApps.isRelevant }

    func load(_ tab: Tab, force: Bool = false) async {
        guard force || !loaded.contains(tab) else { return }
        isBusy = true
        switch tab {
        case .extensions: extensions = await SystemAddOns.extensions()
        case .plugins: plugins = await SystemAddOns.plugins()
        case .rosetta: translated = await RosettaApps.find()
        case .cloud:
            cloudFiles = await CloudFiles.downloaded()
            cloudSelection = []
        }
        loaded.insert(tab)
        isBusy = false
    }

    func setExtensionEnabled(_ enabled: Bool, _ item: AppExtension) async {
        isBusy = true
        _ = await SystemAddOns.setEnabled(enabled, identifier: item.identifier)
        isBusy = false
    }

    // MARK: - iCloud

    func toggleCloud(_ file: CloudFile) {
        if cloudSelection.contains(file.id) { cloudSelection.remove(file.id) } else {
            cloudSelection.insert(file.id)
        }
    }

    /// Keeps the chosen files in iCloud only. Nothing is deleted: they come back when opened.
    func evict() async {
        let chosen = cloudFiles.filter { cloudSelection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isBusy = true
        let result = await CloudFiles.evict(chosen)
        cloudFreed = result.freed
        cloudSelection = []
        await load(.cloud, force: true)
        isBusy = false
    }
}
