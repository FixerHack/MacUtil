import AppKit
import CleanerCore
import Observation

/// Scan results, selection and cleanup state for one junk group.
@MainActor
@Observable
final class JunkStore {
    enum Phase {
        case idle, scanning, ready, cleaning
        case done(CleanupResult)
    }

    enum SelectionState {
        case all, some, none
    }

    let group: JunkRule.Group
    private(set) var phase = Phase.idle
    private(set) var categories: [JunkCategory] = []
    var selection = Set<JunkItem.ID>()
    var expanded = Set<JunkCategory.ID>()

    init(group: JunkRule.Group) {
        self.group = group
    }

    var isBusy: Bool {
        switch phase {
        case .scanning, .cleaning: true
        default: false
        }
    }

    var totalSize: Int64 {
        categories.reduce(0) { $0 + $1.size }
    }

    var selectedItems: [JunkItem] {
        categories.flatMap(\.items).filter { selection.contains($0.id) }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    func scan() async {
        phase = .scanning
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        categories = await JunkScanner.scan(
            JunkCatalog.rules(in: group),
            context: JunkContext(runningBundleIDs: running)
        )
        // Preselect everything that is safe and not in use.
        selection = Set(categories.filter { $0.rule.safety == .safe }.flatMap(\.items).filter { !$0.isInUse }.map(\.id))
        phase = .ready
    }

    func state(of category: JunkCategory) -> SelectionState {
        let selectable = category.items.filter { !$0.isInUse }
        let selected = selectable.filter { selection.contains($0.id) }.count
        if selected == 0 {
            return .none
        }
        return selected == selectable.count ? .all : .some
    }

    func toggle(_ category: JunkCategory) {
        let ids = category.items.filter { !$0.isInUse }.map(\.id)
        if state(of: category) == .all {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    func toggle(_ item: JunkItem) {
        guard !item.isInUse else { return }
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    func clean(mode: CleanupMode) async {
        let targets = selectedItems.map { CleanupTarget(path: $0.path, size: $0.size) }
        guard !targets.isEmpty else { return }
        phase = .cleaning
        let result = await Cleaner().clean(targets, mode: mode, source: "junk.\(group.rawValue)")
        phase = .done(result)
    }

    func undo(_ result: CleanupResult) async {
        phase = .cleaning
        _ = await Cleaner().undo(result)
        await scan()
    }
}

/// Contents of the Trash bins and the state of emptying them.
@MainActor
@Observable
final class TrashStore {
    enum Phase {
        case idle, scanning, ready, emptying
        case done(CleanupResult)
    }

    private(set) var phase = Phase.idle
    private(set) var bins: [TrashBin] = []

    var totalSize: Int64 {
        bins.reduce(0) { $0 + $1.size }
    }

    var itemCount: Int {
        bins.reduce(0) { $0 + $1.items.count }
    }

    func scan() async {
        phase = .scanning
        bins = await TrashBins.find()
        phase = .ready
    }

    func empty() async {
        let targets = bins.flatMap(\.items)
        guard !targets.isEmpty else { return }
        phase = .emptying
        let result = await Cleaner().clean(targets, mode: .delete, source: "trash.empty")
        phase = .done(result)
    }
}
