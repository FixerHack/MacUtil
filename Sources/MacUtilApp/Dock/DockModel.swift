import AppKit
import CleanerCore
import Foundation
import Observation

/// UniMacHub's own Dock: its settings, what is in it, and the system Dock it stands in for.
@MainActor
@Observable
final class DockModel {
    enum Position: String, CaseIterable, Identifiable {
        case bottom, left, right
        var id: String { rawValue }
        var isVertical: Bool { self != .bottom }
    }

    enum Widget: String, CaseIterable, Identifiable {
        case clock, system, controls, music, calendar, weather
        var id: String { rawValue }

        /// Which end of the Dock it sits at.
        var leading: Bool {
            switch self {
            case .clock, .system, .controls: true
            case .music, .calendar, .weather: false
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

    enum Keys {
        static let enabled = "dockEnabled"
        static let iconSize = "dockIconSize"
        static let magnifies = "dockMagnifies"
        static let magnification = "dockMagnification"
        static let autohides = "dockAutohides"
        static let position = "dockPosition"
        static let indicators = "dockIndicators"
        static let runningApps = "dockRunningApps"
        static let tools = "dockTools"
        static let widgets = "dockWidgets"
        static let pinned = "dockPinned"
        static let town = "dockWeatherTown"
        static let place = "dockWeatherPlace"
    }

    // MARK: - Settings

    private(set) var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    var iconSize: Double { didSet { defaults.set(iconSize, forKey: Keys.iconSize) } }
    var magnifies: Bool { didSet { defaults.set(magnifies, forKey: Keys.magnifies) } }
    var magnification: Double { didSet { defaults.set(magnification, forKey: Keys.magnification) } }
    var autohides: Bool { didSet { defaults.set(autohides, forKey: Keys.autohides) } }
    var position: Position { didSet { defaults.set(position.rawValue, forKey: Keys.position) } }
    var showsIndicators: Bool { didSet { defaults.set(showsIndicators, forKey: Keys.indicators) } }
    var showsRunningApps: Bool { didSet { defaults.set(showsRunningApps, forKey: Keys.runningApps) } }
    var showsTools: Bool { didSet { defaults.set(showsTools, forKey: Keys.tools) } }
    var widgets: Set<Widget> { didSet { defaults.set(widgets.map(\.rawValue).sorted(), forKey: Keys.widgets) } }
    var weatherTown: String { didSet { defaults.set(weatherTown, forKey: Keys.town) } }

    // MARK: - Contents

    private(set) var pinned: [URL] { didSet { defaults.set(pinned.map(\.path), forKey: Keys.pinned) } }
    private(set) var apps: [App] = []
    private(set) var weatherPlace: Weather.Place?
    private(set) var weather: Weather.Now?
    private(set) var weatherError = false
    /// Whether the Dock is out, when it hides itself.
    var isShown = false
    /// Where the pointer is along the Dock, for the magnification; nil when it is elsewhere.
    var pointer: CGFloat?
    /// How long the bar is before anything grows, as the view last laid it out.
    @ObservationIgnored var barLength: CGFloat = 0

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var weatherTask: Task<Void, Never>?
    @ObservationIgnored private var launching: Set<String> = []

    init() {
        defaults.register(defaults: [
            Keys.iconSize: 96.0, Keys.magnifies: true, Keys.magnification: 1.335, Keys.autohides: true,
            Keys.position: Position.bottom.rawValue, Keys.indicators: true, Keys.runningApps: true,
            Keys.tools: true, Keys.widgets: [Widget.clock.rawValue, Widget.system.rawValue, Widget.music.rawValue],
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        iconSize = defaults.double(forKey: Keys.iconSize)
        magnifies = defaults.bool(forKey: Keys.magnifies)
        magnification = defaults.double(forKey: Keys.magnification)
        autohides = defaults.bool(forKey: Keys.autohides)
        position = Position(rawValue: defaults.string(forKey: Keys.position) ?? "") ?? .bottom
        showsIndicators = defaults.bool(forKey: Keys.indicators)
        showsRunningApps = defaults.bool(forKey: Keys.runningApps)
        showsTools = defaults.bool(forKey: Keys.tools)
        widgets = Set((defaults.stringArray(forKey: Keys.widgets) ?? []).compactMap(Widget.init))
        weatherTown = defaults.string(forKey: Keys.town) ?? ""
        pinned = (defaults.stringArray(forKey: Keys.pinned) ?? []).map { URL(filePath: $0) }
        weatherPlace = defaults.data(forKey: Keys.place).flatMap { try? JSONDecoder().decode(Weather.Place.self, from: $0) }
        watchApps()
        rebuild()
    }

    // MARK: - Turning it on and off

    /// At launch: the system Dock is hidden again if this one is on, and put back if an
    /// earlier run hid it and could not undo that, such as after a crash.
    func launched() {
        let enabled = isEnabled
        Task.detached {
            if enabled { SystemDock.hide() } else if SystemDock.isHidden { SystemDock.restore() }
        }
    }

    /// Takes over from the system Dock, with its apps.
    func enable() {
        if pinned.isEmpty { pinned = SystemDock.pinnedApps() }
        SystemDock.hide()
        isEnabled = true
        rebuild()
    }

    /// Gives the screen back to the system Dock, exactly as it was.
    func disable() {
        isEnabled = false
        SystemDock.restore()
    }

    /// On quitting: the system Dock comes back, and goes away again at the next launch.
    func quitting() {
        if isEnabled { SystemDock.restore() }
    }

    // MARK: - Apps

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.willLaunchApplicationNotification,
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

    /// Pinned apps in their order, then those running that are not pinned.
    func rebuild() {
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

    func icon(for url: URL) -> NSImage {
        if let icon = icons[url.path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url.path] = icon
        return icon
    }

    /// A click: brings a running app forward, or opens it.
    func open(_ app: App) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID ?? "").first {
            if running.isActive { running.unhide() }
            running.activate()
        } else {
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
    }

    /// Files dropped on an app open in it.
    func open(_ files: [URL], with app: App) {
        NSWorkspace.shared.open(files, withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
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

    func unpin(_ app: App) {
        pinned.removeAll { $0 == app.url }
        rebuild()
    }

    func move(_ url: URL, before target: URL) {
        guard url != target, let from = pinned.firstIndex(of: url) else { return }
        pinned.remove(at: from)
        let to = pinned.firstIndex(of: target) ?? pinned.endIndex
        pinned.insert(url, at: to)
        rebuild()
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

    /// Looks the town up once, then fetches the weather every half hour while the widget is on.
    func refreshWeather() {
        weatherTask?.cancel()
        guard widgets.contains(.weather), !weatherTown.trimmingCharacters(in: .whitespaces).isEmpty else {
            weather = nil
            return
        }
        let town = weatherTown.trimmingCharacters(in: .whitespaces)
        weatherTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchWeather(town: town)
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func fetchWeather(town: String) async {
        if weatherPlace?.name.lowercased() != town.lowercased() || weatherPlace == nil {
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            guard let url = Weather.searchURL(for: town, language: language),
                  let data = try? await URLSession.shared.data(from: url).0,
                  let place = Weather.place(fromSearch: data)
            else {
                weatherError = true
                return
            }
            weatherPlace = place
            defaults.set(try? JSONEncoder().encode(place), forKey: Keys.place)
            if weatherTown != place.name { weatherTown = place.name }
        }
        guard let place = weatherPlace, let url = Weather.forecastURL(for: place),
              let data = try? await URLSession.shared.data(from: url).0,
              let now = Weather.now(fromForecast: data)
        else {
            weatherError = true
            return
        }
        weatherError = false
        weather = now
    }
}
