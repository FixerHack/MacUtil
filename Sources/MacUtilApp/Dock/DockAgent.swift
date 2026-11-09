import AppKit
import CleanerCore
import Observation
import ServiceManagement

/// UniMacHub itself, from whichever of its processes asks: the app, or the Dock's helper
/// inside it at `Contents/Library/LoginItems`.
enum HostApp {
    static var url: URL {
        let own = Bundle.main.bundleURL
        guard DockAgent.isAgentProcess else { return own }
        // …/UniMacHub.app/Contents/Library/LoginItems/UniMacHub Dock.app
        return own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var bundle: Bundle { Bundle(url: url) ?? .main }
}

/// The Dock's own process: a small app with no icon of its own, inside UniMacHub, that
/// macOS starts at login and starts again if it ever stops, so the Dock stays whether or
/// not UniMacHub is open.
///
/// It is the same program as UniMacHub, started from a second bundle with its own name; at
/// launch the program looks at which bundle it is and runs either the app or only the Dock.
@MainActor
final class DockAgent: NSObject, NSApplicationDelegate {
    nonisolated static let bundleID = MacUtilInfo.bundleIdentifier + ".Dock"
    nonisolated static var isAgentProcess: Bool { Bundle.main.bundleIdentifier == bundleID }

    static func run() -> Never {
        let app = NSApplication.shared
        let agent = DockAgent()
        app.delegate = agent
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    private var model: DockModel?
    private var sources: DockSources?
    private var controller: DockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DockModel(role: .dock)
        // Turned off, or turned off while this was not running: nothing to do. A clean exit,
        // so macOS does not start it again.
        guard model.isEnabled else { exit(0) }
        if Self.keepsCrashing() {
            // Something is wrong with this Dock: the system one comes back rather than none.
            SystemDock.restore()
            model.markEnabled(false)
            exit(0)
        }
        model.onDisabled = { exit(0) }
        // Which build is running, so UniMacHub can tell when an update needs a fresh start.
        UserDefaults(suiteName: MacUtilInfo.bundleIdentifier)?.set(
            DockService.buildDate(of: Bundle.main.executableURL), forKey: DockService.runningBuildKey
        )
        self.model = model
        let sources = DockSources(model: model)
        self.sources = sources
        controller = DockController(model: model, sources: sources)
        keepSystemDockAway()
    }

    /// The system Dock hides on the same edge, and moves when this one does: Mission Control
    /// shows it there while this one steps out of the way.
    private func keepSystemDockAway() {
        guard let model else { return }
        let edge = model.position.rawValue
        Task.detached { SystemDock.hide(edge: edge) }
        withObservationTracking {
            _ = model.position
        } onChange: { [weak self] in
            Task { @MainActor in self?.keepSystemDockAway() }
        }
    }

    // MARK: - Starting over and over

    private static let launchesKey = "dockAgentLaunches"

    /// Four starts within two minutes: it keeps falling over, and macOS keeps starting it.
    private static func keepsCrashing() -> Bool {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var launches = (defaults.array(forKey: launchesKey) as? [Double] ?? []).filter { now - $0 < 120 }
        launches.append(now)
        defaults.set(launches, forKey: launchesKey)
        // Running for a while means it is fine.
        Task {
            try? await Task.sleep(for: .seconds(60))
            UserDefaults.standard.removeObject(forKey: launchesKey)
        }
        return launches.count >= 4
    }
}

/// What the Dock's widgets show, and the way back into UniMacHub.
@MainActor
@Observable
final class DockSources {
    let island = IslandModel()
    let windows = MinimizedWindows()
    let gadgets = DockGadgets()
    let previews: WindowPreviews
    private(set) var sample = SystemStats.Sample()
    @ObservationIgnored private let model: DockModel
    @ObservationIgnored private let stats = SystemStats()
    @ObservationIgnored private var sampling: Task<Void, Never>?

    @ObservationIgnored private var askObserver: NSObjectProtocol?
    @ObservationIgnored private var askRecordingObserver: NSObjectProtocol?

    init(model: DockModel) {
        self.model = model
        previews = WindowPreviews(model: model)
        model.reportScreenRecording(WindowPreviews.canCapture)
        askRecordingObserver = DistributedNotificationCenter.default().addObserver(
            forName: DockModel.askScreenRecordingNotification, object: nil, queue: .main
        ) { _ in
            // macOS asks once; after that only System Settings can change it.
            Task { @MainActor in
                if !CGRequestScreenCaptureAccess(),
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        windows.onChange = { [weak self] in
            guard let self else { return }
            self.model.minimizedWindows = self.windows.windows
            self.model.reportAccessibility(self.windows.isTrusted)
        }
        model.reportAccessibility(windows.isTrusted)
        askObserver = DistributedNotificationCenter.default().addObserver(
            forName: DockModel.askAccessibilityNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windows.askForPermission() }
        }
        follow()
        followWindows()
        // Permissions change in System Settings, which says nothing: look now and then.
        permissions = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.model.reportAccessibility(AXIsProcessTrusted())
                self?.model.reportScreenRecording(WindowPreviews.canCapture)
            }
        }
    }

    @ObservationIgnored private var permissions: Task<Void, Never>?

    private func followWindows() {
        let shows = withObservationTracking {
            model.showsMinimized
        } onChange: { [weak self] in
            Task { @MainActor in self?.followWindows() }
        }
        if shows { windows.start() } else { windows.stop() }
    }

    /// Runs only what the widgets on show need.
    private func follow() {
        let widgets = withObservationTracking {
            model.widgets
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        island.setFeedRunning(widgets.contains(.music))
        if widgets.contains(.calendar) {
            if !island.calendar.isEnabled { island.calendar.isEnabled = true }
            island.calendar.setRunning(true)
        } else {
            island.calendar.setRunning(false)
        }
        if widgets.contains(.system) {
            guard sampling == nil else { return }
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    guard let stats = self?.stats else { return }
                    let sample = await Task.detached { stats.sample() }.value
                    self?.sample = sample
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else {
            sampling?.cancel()
            sampling = nil
        }
    }

    /// Opens UniMacHub on a tool: told directly if it is running, started with it otherwise.
    func openInHub(_ module: Module) {
        let configuration = NSWorkspace.OpenConfiguration()
        if NSRunningApplication.runningApplications(withBundleIdentifier: MacUtilInfo.bundleIdentifier).isEmpty {
            configuration.arguments = [HubLink.argument, module.key]
        } else {
            DistributedNotificationCenter.default().postNotificationName(
                HubLink.notification, object: module.key, userInfo: nil, deliverImmediately: true
            )
        }
        // Through Launch Services, which may bring an app forward on a click elsewhere.
        NSWorkspace.shared.openApplication(at: HostApp.url, configuration: configuration)
    }
}

/// How the Dock asks UniMacHub to open a tool.
enum HubLink {
    static let notification = Notification.Name(MacUtilInfo.bundleIdentifier + ".openModule")
    static let argument = "--open-module"

    /// The tool UniMacHub was started with, if the Dock started it.
    static var launchModule: Module? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return nil }
        return Module.named(arguments[index + 1])
    }
}

/// Starting and stopping the Dock's process, from UniMacHub.
///
/// It is a launch agent that macOS keeps running (`KeepAlive` unless it exits cleanly) and
/// starts at login; registering it is what macOS reports as UniMacHub adding a background item.
@MainActor
enum DockService {
    static let label = DockAgent.bundleID
    static var service: SMAppService { .agent(plistName: label + ".plist") }
    static var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LoginItems/UniMacHub Dock.app")
    }

    enum Problem: Equatable {
        /// Run from a build without the helper inside, such as `swift run`.
        case missing
        /// Switched off under Login Items in System Settings.
        case needsApproval
        case failed(String)
    }

    /// Starts it, and from then on at every login.
    static func start() -> Problem? {
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return .missing }
        let service = service
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                return service.status == .requiresApproval ? .needsApproval : .failed(error.localizedDescription)
            }
        }
        if service.status == .requiresApproval { return .needsApproval }
        kickstart(restart: false)
        return nil
    }

    /// Turns the Dock on: written down first, as its process reads that when it starts.
    static func turnOn(_ model: DockModel) -> Problem? {
        model.markEnabled(true)
        if let problem = start() {
            model.markEnabled(false)
            return problem
        }
        return nil
    }

    /// Turns it off: its process quits on hearing so, and the system Dock comes back as it was.
    static func turnOff(_ model: DockModel) {
        model.markEnabled(false)
        stop()
        Task.detached { SystemDock.restore() }
    }

    static func stop() {
        Task { try? await service.unregister() }
    }

    nonisolated static let runningBuildKey = "dockAgentBuild"

    /// When an executable was built, as a number to compare.
    nonisolated static func buildDate(of url: URL?) -> Double {
        guard let url, let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return 0 }
        return date.timeIntervalSince1970
    }

    static var runningAgent: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: DockAgent.bundleID).first
    }

    /// Starts it if it is not running; with `restart`, starts it afresh.
    static func kickstart(restart: Bool) {
        let target = "gui/\(getuid())/\(label)"
        Task.detached {
            _ = await Command.run("/bin/launchctl", restart ? ["kickstart", "-k", target] : ["kickstart", target])
        }
    }

    /// At UniMacHub's launch: the Dock's process matches the setting, and runs this version.
    static func launched(_ model: DockModel) {
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return }
        if model.isEnabled {
            if let problem = start() {
                // It cannot run: the system Dock comes back rather than leaving none.
                if problem != .missing {
                    model.markEnabled(false)
                    Task.detached { SystemDock.restore() }
                }
                return
            }
            // Updated since it started: start the new one. (A process launchd started has no
            // launch date to compare, so it writes down which build it is.)
            let executable = helperURL.appending(path: "Contents/MacOS/UniMacHub Dock")
            let running = UserDefaults.standard.double(forKey: runningBuildKey)
            if runningAgent != nil, running != buildDate(of: executable) {
                kickstart(restart: true)
            }
        } else {
            if service.status == .enabled { stop() }
            if SystemDock.isHidden, runningAgent == nil {
                Task.detached { SystemDock.restore() }
            }
        }
    }
}
