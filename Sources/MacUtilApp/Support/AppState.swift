import CleanerCore
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Where you are: empty means the hub itself, otherwise the tool on screen.
    ///
    /// A path rather than a selection, because there is no sidebar to select in any more.
    var path: [Module] = []

    /// What is on screen, for the few places that need to know.
    var selection: Module? {
        get { path.last ?? .hub }
        set { path = newValue.map { $0 == .hub ? [] : [$0] } ?? [] }
    }

    /// Opens a tool from anywhere: the menu bar, the dashboard, the hub.
    func open(_ module: Module) {
        path = module == .hub ? [] : [module]
    }

    // MARK: - Favourites

    static let favouritesKey = "favouriteModules"

    /// Tools kept to hand, in the order they were pinned.
    private(set) var favourites: [Module] = (UserDefaults.standard.stringArray(forKey: favouritesKey) ?? [])
        .compactMap(Module.named)

    func isFavourite(_ module: Module) -> Bool { favourites.contains(module) }

    func toggleFavourite(_ module: Module) {
        if let index = favourites.firstIndex(of: module) {
            favourites.remove(at: index)
        } else {
            favourites.append(module)
        }
        UserDefaults.standard.set(favourites.map(\.key), forKey: Self.favouritesKey)
    }

    /// Tools whose name contains what was typed, best match first.
    func matches(_ text: String) -> [Module] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let titles = Module.allCases.filter { $0 != .hub }
            .map { (module: $0, title: $0.titleText) }
        // A name that begins with what was typed is the likelier answer than one that
        // merely contains it somewhere, so those come first.
        func begins(_ title: String) -> Bool {
            title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }
        let starting = titles.filter { begins($0.title) }
        let containing = titles.filter {
            !begins($0.title) && $0.title.localizedCaseInsensitiveContains(needle)
        }
        return (starting + containing).map(\.module)
    }
    let scans = ScanStore()
    let systemJunk = JunkStore(group: .system)
    let developerJunk = JunkStore(group: .developer)
    let trash = TrashStore()
    let security = SecurityStore()
    let uninstaller = UninstallerStore()
    let leftovers = JunkStore(group: .leftovers)
    let duplicates = DuplicatesStore()
    let search = SearchStore()
    let privacy = JunkStore(group: .privacy)
    let messengers = MessengerStore()
    let maintenance = MaintenanceStore()
    let hiddenSettings = HiddenSettingsStore()
    let taskManager = TaskManagerStore()
    let disks = DisksStore()
    let recovery = RecoveryStore()
    let loginItems = LoginItemsStore()
    let smartScan = SmartScanStore()
    let updater = UpdaterStore()
    let selfUpdate = SelfUpdateStore()
    let monitor = MenuBarMonitor()
    let history = HistoryStore()
    let installers = InstallerStore()
    let projectBuilds = ProjectBuildsStore()
    let slimming = SlimmingStore()
    let organize = OrganizeStore()
    let network = NetworkStore()
    let terminal = TerminalStore()
    let addOns = AddOnStore()
    let clipboard = ClipboardStore()
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown
    private(set) var startupDisk: VolumeInfo?
    /// The Full Disk Access guide; opens on launch while access is missing.
    var showsPermissionsGuide = false
    #if DEBUG
        /// Security Analyzer section to open, for snapshots ("permissions", "network"…).
        var securitySection: String?
    #endif

    init() {
        UserDefaults.standard.register(defaults: [Preferences.automaticUpdateCheck: true])
        refresh()
        showsPermissionsGuide = fullDiskAccess != .granted
        #if DEBUG
            if DebugSnapshot.isActive {
                showsPermissionsGuide = false
            }
        #endif
    }

    func refresh() {
        fullDiskAccess = FullDiskAccess.status()
        startupDisk = try? VolumeInfo.forVolume()
    }
}
