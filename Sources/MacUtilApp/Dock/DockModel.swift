import AppKit
import CleanerCore
import Foundation
import Observation

/// UniMacHub's own Dock: its settings, what is in it, and the system Dock it stands in for.
///
/// The same model runs in two processes. In UniMacHub it is the settings page; in the Dock's
/// own background process (see `DockAgent`) it is the Dock itself. Both keep the settings in
/// UniMacHub's preferences and tell each other when they change them, so a change made on
/// either side, such as an app pinned by dragging it onto the Dock, shows on the other.
@MainActor
@Observable
final class DockModel {
    enum Role { case settings, dock }

    enum Position: String, CaseIterable, Identifiable {
        case bottom, left, right
        var id: String { rawValue }
        var isVertical: Bool { self != .bottom }
    }

    /// How a folder opens: a fan rising from it, a grid, or a list.
    enum FolderStyle: String, CaseIterable, Identifiable {
        case fan, grid, list
        var id: String { rawValue }
    }

    enum Widget: String, CaseIterable, Identifiable {
        case clock, system, music, calendar, weather
        var id: String { rawValue }

        /// Which end of the Dock it sits at.
        var leading: Bool {
            switch self {
            case .clock, .system: true
            case .music, .calendar, .weather: false
            }
        }

        /// How long it is along a Dock at the bottom, in icon sizes. Along a side it is square.
        var units: CGFloat {
            switch self {
            case .clock: 1.55
            case .system: 1.75
            case .music: 3.3
            case .calendar: 1.55
            case .weather: 1.6
            }
        }
    }

    /// One app's place in the Dock.
    struct App: Identifiable, Equatable {
        let url: URL
        let bundleID: String?
        let name: String
        var isPinned: Bool
        var isRunning: Bool
        var isActive: Bool
        var isLaunching: Bool
        var id: String { url.path }
    }

    /// One place along the Dock.
    enum Entry: Identifiable, Equatable {
        case widget(Widget)
        case app(App)
        case window(MinimizedWindow)
        case folder(URL)
        case divider(Int)
        case trash

        var id: String {
            switch self {
            case let .widget(widget): "widget." + widget.rawValue
            case let .app(app): "app." + app.id
            case let .window(window): "window." + window.id
            case let .folder(url): "folder." + url.path
            case let .divider(index): "divider.\(index)"
            case .trash: "trash"
            }
        }

        func slot(vertical: Bool) -> DockLayout.Slot {
            switch self {
            case .app, .window, .folder, .trash: .init(units: 1, grows: true)
            case .divider: .init(units: 0.32, grows: false)
            case let .widget(widget): .init(units: vertical ? 1 : widget.units, grows: false)
            }
        }
    }

    enum Keys {
        static let enabled = "dockEnabled"
        static let iconSize = "dockIconSize"
        static let magnifies = "dockMagnifies"
        static let magnification = "dockMagnification"
        static let autohides = "dockAutohides"
        static let position = "dockPosition"
        static let indicators = "dockIndicators"
        static let runningApps = "dockRunningApps"
        static let widgets = "dockWidgets"
        static let pinned = "dockPinned"
        static let town = "dockWeatherTown"
        static let place = "dockWeatherPlace"
        static let minimized = "dockMinimizedWindows"
        static let folders = "dockFolders"
        static let displays = "dockDisplays"
        static let previews = "dockWindowPreviews"
        static let screenRecording = "dockScreenRecordingGranted"
        static let folderStyle = "dockFolderStyle"
        static let accessibility = "dockAccessibilityGranted"
    }

    /// Posted by either process when it changes a setting, so the other reads them again.
    static let changedNotification = Notification.Name(MacUtilInfo.bundleIdentifier + ".dockChanged")
    /// Sent by the settings page for the Dock's process to ask macOS for Accessibility.
    static let askAccessibilityNotification = Notification.Name(MacUtilInfo.bundleIdentifier + ".dockAskAccessibility")
    /// The same for Screen Recording, which the window previews need.
    static let askScreenRecordingNotification = Notification.Name(MacUtilInfo.bundleIdentifier + ".dockAskScreenRecording")
    /// The players the music widget stands for: while it is on, their icons stay out of the Dock.
    static let musicPlayers = Set(NowPlaying.Player.allCases.map(\.bundleID))
    static let iconSizes: ClosedRange<Double> = 24 ... 128

    let role: Role

    // MARK: - Settings

    private(set) var isEnabled: Bool { didSet { save(isEnabled, Keys.enabled) } }
    var iconSize: Double { didSet { save(iconSize, Keys.iconSize) } }
    var magnifies: Bool { didSet { save(magnifies, Keys.magnifies) } }
    var magnification: Double { didSet { save(magnification, Keys.magnification) } }
    var autohides: Bool { didSet { save(autohides, Keys.autohides) } }
    var position: Position { didSet { save(position.rawValue, Keys.position) } }
    var showsIndicators: Bool { didSet { save(showsIndicators, Keys.indicators) } }
    var showsRunningApps: Bool { didSet { save(showsRunningApps, Keys.runningApps); rebuild() } }
    var widgets: Set<Widget> { didSet { save(widgets.map(\.rawValue).sorted(), Keys.widgets); rebuild() } }
    private(set) var weatherTown: String { didSet { save(weatherTown, Keys.town) } }
    /// Minimised windows in the Dock, before the Trash, as the system Dock keeps them.
    var showsMinimized: Bool { didSet { save(showsMinimized, Keys.minimized) } }
    /// Folders kept by the Trash, as the system Dock keeps Downloads.
    private(set) var folders: [URL] { didSet { save(folders.map(\.path), Keys.folders) } }
    var folderStyle: FolderStyle { didSet { save(folderStyle.rawValue, Keys.folderStyle) } }
    /// The displays the Dock is on, by their lasting identifiers; none chosen means the main one.
    var displays: Set<String> { didSet { save(displays.sorted(), Keys.displays) } }
    /// Pictures of an app's windows while the pointer rests on its icon.
    var showsPreviews: Bool { didSet { save(showsPreviews, Keys.previews) } }
    private(set) var screenRecordingGranted: Bool { didSet { save(screenRecordingGranted, Keys.screenRecording) } }
    /// Whether the Dock's process may read other apps' windows, as it last found.
    private(set) var accessibilityGranted: Bool { didSet { save(accessibilityGranted, Keys.accessibility) } }

    // MARK: - Contents

    private(set) var pinned: [URL] { didSet { save(pinned.map(\.path), Keys.pinned) } }
    private(set) var apps: [App] = []
    /// Set by the Dock's process from `MinimizedWindows`.
    var minimizedWindows: [MinimizedWindow] = []
    private(set) var weatherPlace: Weather.Place?
    private(set) var weather: Weather.Now?
    private(set) var weatherError = false
    private(set) var isLookingUpTown = false
    /// Called in the Dock's process when the other side turned the Dock off.
    @ObservationIgnored var onDisabled: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var launching: Set<String> = []

    init(role: Role) {
        self.role = role
        // UniMacHub's own preferences, from whichever process.
        let own = Bundle.main.bundleIdentifier == MacUtilInfo.bundleIdentifier
        defaults = own ? .standard : UserDefaults(suiteName: MacUtilInfo.bundleIdentifier) ?? .standard
        defaults.register(defaults: [
            Keys.iconSize: 64.0, Keys.magnifies: true, Keys.magnification: 1.335, Keys.autohides: true,
            Keys.position: Position.bottom.rawValue, Keys.indicators: true, Keys.runningApps: true,
            Keys.minimized: true, Keys.previews: true, Keys.folderStyle: FolderStyle.grid.rawValue,
            Keys.folders: [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").path],
            Keys.widgets: [Widget.clock.rawValue, Widget.system.rawValue, Widget.music.rawValue],
        ])
        isEnabled = false
        iconSize = 64
        magnifies = true
        magnification = 1.335
        autohides = true
        position = .bottom
        showsIndicators = true
        showsRunningApps = true
        widgets = []
        weatherTown = ""
        showsMinimized = true
        folders = []
        folderStyle = .grid
        displays = []
        showsPreviews = true
        screenRecordingGranted = false
        accessibilityGranted = false
        pinned = []
        load()

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.changedNotification, object: nil, queue: .main
        ) { [weak self] note in
            let sender = note.object as? String
            Task { @MainActor in
                guard let self, sender != Self.processTag else { return }
                self.changedElsewhere()
            }
        })
        if role == .dock { watchApps() }
        rebuild()
    }

    // MARK: - Keeping both processes in step

    private static let processTag = String(ProcessInfo.processInfo.processIdentifier)

    private func save(_ value: Any, _ key: String) {
        guard !loading else { return }
        defaults.set(value, forKey: key)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Self.changedNotification, object: Self.processTag, userInfo: nil, deliverImmediately: true
        )
    }

    /// Reads every setting, touching only what differs, so nothing redraws for nothing.
    private func load() {
        loading = true
        defer { loading = false }
        defaults.synchronize()
        let read = defaults
        if isEnabled != read.bool(forKey: Keys.enabled) { isEnabled = read.bool(forKey: Keys.enabled) }
        let size = min(Self.iconSizes.upperBound, max(Self.iconSizes.lowerBound, read.double(forKey: Keys.iconSize)))
        if iconSize != size { iconSize = size }
        if magnifies != read.bool(forKey: Keys.magnifies) { magnifies = read.bool(forKey: Keys.magnifies) }
        if magnification != read.double(forKey: Keys.magnification) { magnification = read.double(forKey: Keys.magnification) }
        if autohides != read.bool(forKey: Keys.autohides) { autohides = read.bool(forKey: Keys.autohides) }
        let side = Position(rawValue: read.string(forKey: Keys.position) ?? "") ?? .bottom
        if position != side { position = side }
        if showsIndicators != read.bool(forKey: Keys.indicators) { showsIndicators = read.bool(forKey: Keys.indicators) }
        if showsRunningApps != read.bool(forKey: Keys.runningApps) { showsRunningApps = read.bool(forKey: Keys.runningApps) }
        let chosen = Set((read.stringArray(forKey: Keys.widgets) ?? []).compactMap(Widget.init))
        if widgets != chosen { widgets = chosen }
        let keptFolders = (read.stringArray(forKey: Keys.folders) ?? []).map { URL(filePath: $0) }
        if folders != keptFolders { folders = keptFolders }
        if showsPreviews != read.bool(forKey: Keys.previews) { showsPreviews = read.bool(forKey: Keys.previews) }
        if screenRecordingGranted != read.bool(forKey: Keys.screenRecording) { screenRecordingGranted = read.bool(forKey: Keys.screenRecording) }
        let chosenDisplays = Set(read.stringArray(forKey: Keys.displays) ?? [])
        if displays != chosenDisplays { displays = chosenDisplays }
        let style = FolderStyle(rawValue: read.string(forKey: Keys.folderStyle) ?? "") ?? .grid
        if folderStyle != style { folderStyle = style }
        if showsMinimized != read.bool(forKey: Keys.minimized) { showsMinimized = read.bool(forKey: Keys.minimized) }
        if accessibilityGranted != read.bool(forKey: Keys.accessibility) { accessibilityGranted = read.bool(forKey: Keys.accessibility) }
        let town = read.string(forKey: Keys.town) ?? ""
        if weatherTown != town { weatherTown = town }
        let kept = (read.stringArray(forKey: Keys.pinned) ?? []).map { URL(filePath: $0) }
        if pinned != kept { pinned = kept }
        let stored = read.data(forKey: Keys.place).flatMap { try? JSONDecoder().decode(Weather.Place.self, from: $0) }
        if weatherPlace != stored { weatherPlace = stored }
    }

    /// The other process changed something: read it all again.
    private func changedElsewhere() {
        let place = weatherPlace
        let wasEnabled = isEnabled
        let hadWeather = widgets.contains(.weather)
        load()
        rebuild()
        guard role == .dock else { return }
        if wasEnabled, !isEnabled { onDisabled?() }
        if place != weatherPlace || hadWeather != widgets.contains(.weather) { refreshWeather() }
    }

    // MARK: - Turning it on and off (UniMacHub's side, see `DockService`)

    /// Writes down whether the Dock is on, for its process to find when it starts. The apps
    /// in the system Dock come across the first time.
    func markEnabled(_ enabled: Bool) {
        if enabled, pinned.isEmpty { pinned = SystemDock.pinnedApps() }
        isEnabled = enabled
    }

    /// From the Dock's process, for the settings page to show.
    func reportAccessibility(_ granted: Bool) {
        if accessibilityGranted != granted { accessibilityGranted = granted }
    }

    func reportScreenRecording(_ granted: Bool) {
        if screenRecordingGranted != granted { screenRecordingGranted = granted }
    }

    // MARK: - What is in it

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.willLaunchApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let launched = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
                let finished = note.name != NSWorkspace.willLaunchApplicationNotification
                Task { @MainActor in
                    if let launched, finished { self?.launching.remove(launched) }
                    self?.rebuild()
                }
            })
        }
    }

    /// Pinned apps in their order, then those running that are not pinned. Music players stay
    /// out while the music widget stands in for them.
    func rebuild() {
        guard role == .dock else { return }
        let hidden = widgets.contains(.music) ? Self.musicPlayers : []
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byPath: [String: NSRunningApplication] = [:]
        for app in running {
            if let path = app.bundleURL?.path { byPath[path] = app }
        }
        var result: [App] = []
        for url in pinned where FileManager.default.fileExists(atPath: url.path) {
            result.append(app(url, pinned: true, running: byPath[url.path]))
        }
        if showsRunningApps {
            let pinnedPaths = Set(pinned.map(\.path))
            for app in running {
                guard let url = app.bundleURL, !pinnedPaths.contains(url.path),
                      app.bundleIdentifier != Bundle.main.bundleIdentifier
                else { continue }
                result.append(self.app(url, pinned: false, running: app))
            }
        }
        result.removeAll { $0.bundleID.map(hidden.contains) ?? false }
        if result != apps { apps = result }
    }

    private func app(_ url: URL, pinned: Bool, running: NSRunningApplication?) -> App {
        App(
            url: url,
            bundleID: running?.bundleIdentifier ?? Bundle(url: url)?.bundleIdentifier,
            name: running?.localizedName ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            isPinned: pinned,
            isRunning: running != nil,
            isActive: running?.isActive ?? false,
            isLaunching: launching.contains(url.path) || (running.map { !$0.isFinishedLaunching } ?? false)
        )
    }

    /// Everything along the Dock, in order: widgets, apps, the Trash last. UniMacHub's tools
    /// are in the menu of its own icon.
    var entries: [Entry] {
        var result: [Entry] = []
        let leading = Widget.allCases.filter { widgets.contains($0) && $0.leading }
        let trailing = Widget.allCases.filter { widgets.contains($0) && !$0.leading }
        result += leading.map(Entry.widget)
        if !leading.isEmpty { result.append(.divider(0)) }
        let kept = apps.filter(\.isPinned)
        let others = apps.filter { !$0.isPinned }
        result += kept.map(Entry.app)
        if !others.isEmpty {
            if !kept.isEmpty { result.append(.divider(1)) }
            result += others.map(Entry.app)
        }
        if !trailing.isEmpty {
            result.append(.divider(3))
            result += trailing.map(Entry.widget)
        }
        result.append(.divider(4))
        result += folders.filter { FileManager.default.fileExists(atPath: $0.path) }.map(Entry.folder)
        if showsMinimized { result += minimizedWindows.map(Entry.window) }
        result.append(.trash)
        return result
    }

    // MARK: - Displays

    /// A display's identifier that lasts across restarts and plugging in again.
    static func displayID(of screen: NSScreen) -> String {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return String(number) }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func shows(onDisplay id: String, isMain: Bool) -> Bool {
        displays.isEmpty ? isMain : displays.contains(id)
    }

    /// Puts the Dock on a display or takes it off, starting from where it is now.
    func setShows(_ shows: Bool, onDisplay id: String) {
        var current = Set(NSScreen.screens.enumerated().compactMap { index, screen in
            let screenID = Self.displayID(of: screen)
            return self.shows(onDisplay: screenID, isMain: index == 0) ? screenID : nil
        })
        // Displays not connected now keep their choice.
        current.formUnion(displays)
        if shows { current.insert(id) } else { current.remove(id) }
        displays = current
    }

    /// Where everything goes, given the room along the edge.
    func layout(_ entries: [Entry], available: CGFloat, pointer: CGFloat?) -> DockLayout {
        DockLayout(
            slots: entries.map { $0.slot(vertical: position.isVertical) },
            iconSize: CGFloat(iconSize),
            available: available,
            magnification: magnifies ? CGFloat(magnification) : 1,
            pointer: pointer
        )
    }

    func icon(for url: URL) -> NSImage {
        if let icon = icons[url.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url.path] = icon
        return icon
    }

    // MARK: - Apps

    /// A click: brings a running app forward, or opens it.
    func open(_ app: App) {
        if app.isRunning {
            // Through Launch Services, as the system Dock does: an app with its windows all
            // closed opens a new one, and a hidden one comes back.
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        launching.insert(app.url.path)
        rebuild()
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        // An app that never finishes launching does not bounce for ever.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.launching.remove(app.url.path)
            self?.rebuild()
        }
    }

    /// Opens an app by its bundle, for the music widget.
    func open(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Files dropped on an app open in it.
    func open(_ files: [URL], with app: App) {
        NSWorkspace.shared.open(files, withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    func hide(_ app: App) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").forEach { $0.hide() }
    }

    func quit(_ app: App) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").forEach { $0.terminate() }
    }

    func showInFinder(_ app: App) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func pin(_ url: URL) {
        guard !pinned.contains(url) else { return }
        pinned.append(url)
        rebuild()
    }

    func unpin(_ url: URL) {
        pinned.removeAll { $0 == url }
        rebuild()
    }

    func move(_ url: URL, before target: URL) {
        guard url != target, let from = pinned.firstIndex(of: url) else { return }
        pinned.remove(at: from)
        let to = pinned.firstIndex(of: target) ?? pinned.endIndex
        pinned.insert(url, at: to)
        rebuild()
    }

    func pinFolder(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
    }

    func unpinFolder(_ url: URL) {
        folders.removeAll { $0 == url }
    }

    /// What is in a folder, newest first, the way the system Dock's stacks sort by default.
    static func contents(of folder: URL, limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        func date(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.addedToDirectoryDate ?? values?.contentModificationDate ?? .distantPast
        }
        return Array(items.map { ($0, date($0)) }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    func useSystemDockApps() {
        pinned = SystemDock.pinnedApps()
        rebuild()
    }

    // MARK: - Trash

    var trashIsFull: Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        return ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).contains { $0 != ".DS_Store" }
    }

    func openTrash() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
    }

    /// Dropped on the Trash: moved there, the way the system Dock does it, and so they can come back.
    func moveToTrash(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: - Weather

    /// Finds the town, from the settings page; the Dock then fetches the weather for it.
    func lookUpTown(_ name: String) async {
        let town = name.trimmingCharacters(in: .whitespaces)
        guard !town.isEmpty else { return }
        isLookingUpTown = true
        defer { isLookingUpTown = false }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        guard let url = Weather.searchURL(for: town, language: language),
              let data = try? await URLSession.shared.data(from: url).0,
              let place = Weather.place(fromSearch: data),
              let encoded = try? JSONEncoder().encode(place)
        else {
            weatherError = true
            return
        }
        weatherError = false
        weatherPlace = place
        save(encoded, Keys.place)
        weatherTown = place.name
        refreshWeather()
    }

    /// Fetches the weather every half hour while the widget is on, in the Dock's process.
    func refreshWeather() {
        weatherTask?.cancel()
        guard role == .dock, widgets.contains(.weather), let place = weatherPlace else {
            weather = nil
            return
        }
        weatherTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let url = Weather.forecastURL(for: place) else { return }
                let data = try? await URLSession.shared.data(from: url).0
                guard !Task.isCancelled else { return }
                if let data, let reading = Weather.now(fromForecast: data) {
                    self?.weather = reading
                }
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }
}
