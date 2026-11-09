import AppKit
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

    /// Opens the main window, from places outside it such as the island and the Dock, which
    /// have no scene of their own to ask. Set by the first window that appears.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Brings UniMacHub forward with a tool on screen, opening the window again if it was closed.
    func showMain(_ module: Module? = nil) {
        if let module { open(module) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
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
    let dns = DNSStore()
    let vault = VaultStore()
    let island = IslandModel()
    @ObservationIgnored private var islandController: IslandController?
    /// The Dock's settings; the Dock itself runs in its own process (see `DockAgent`).
    let dock = DockModel(role: .settings)
    @ObservationIgnored private var hubLink: NSObjectProtocol?
    let terminal = TerminalStore()
    let addOns = AddOnStore()
    let clipboard = ClipboardStore()
    private(set) var fullDiskAccess: FullDiskAccess.Status = .unknown
    private(set) var startupDisk: VolumeInfo?
    /// The Full Disk Access guide.
    var showsPermissionsGuide = false
    #if DEBUG
        /// Security Analyzer section to open, for snapshots ("permissions", "network"…).
        var securitySection: String?
    #endif

    init() {
        UserDefaults.standard.register(defaults: [Preferences.automaticUpdateCheck: true])
        refresh()
        // The Dock opens tools here: at launch if it started UniMacHub, by a note otherwise.
        if let module = HubLink.launchModule { open(module) }
        hubLink = DistributedNotificationCenter.default().addObserver(
            forName: HubLink.notification, object: nil, queue: .main
        ) { [weak self] note in
            let module = (note.object as? String).flatMap(Module.named)
            Task { @MainActor in
                guard let module else { return }
                self?.showMain(module)
            }
        }
        // Once everything above exists: the island reads the stores to show work in progress.
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
                if DebugSnapshot.isActive { return }
            #endif
            self.islandController = IslandController(model: self.island, state: self)
            DockService.launched(self.dock)
        }
    }

    /// What UniMacHub is busy with, for the island; nil while it is idle.
    var islandWork: IslandModel.Work? {
        if smartScan.isBusy { return .init(title: String(localized: "Checking everything…"), symbol: "wand.and.sparkles") }
        for (store, title) in [
            (systemJunk, String(localized: "Cleaning up system junk…")),
            (developerJunk, String(localized: "Cleaning up developer junk…")),
            (privacy, String(localized: "Clearing traces…")),
            (leftovers, String(localized: "Looking for leftovers…")),
        ] where store.isBusy {
            return .init(title: title, symbol: "sparkles")
        }
        if case .working = uninstaller.phase {
            return .init(title: String(localized: "Removing an app…"), symbol: "trash")
        }
        if case .scanning = security.phase {
            return .init(title: String(localized: "Checking security…"), symbol: "checkmark.shield")
        }
        return nil
    }

    /// Whether a tool is waiting on Full Disk Access. Only a definite no locks it: when
    /// none of the probe files exist there is no telling, and a lock would be a guess.
    func isLocked(_ module: Module) -> Bool {
        module.needsFullDiskAccess && fullDiskAccess == .denied
    }

    func refresh() {
        fullDiskAccess = FullDiskAccess.status()
        startupDisk = try? VolumeInfo.forVolume()
    }
}
