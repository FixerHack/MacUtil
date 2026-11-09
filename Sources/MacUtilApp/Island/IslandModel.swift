import AppKit
import CleanerCore
import Foundation
import Observation

/// Everything the island shows, and the settings that decide what it may do.
@MainActor
@Observable
final class IslandModel {
    enum Keys {
        static let enabled = "islandEnabled"
        static let onPlainScreens = "islandOnPlainScreens"
        static let replacesIndicators = "islandReplacesIndicators"
        static let playerVolume = "islandPlayerVolume"
        static let nowPlaying = "islandNowPlaying"
        static let shelf = "islandShelf"
        static let shelfPaths = "islandShelfPaths"
    }

    /// A volume or brightness change, shown for a moment in place of the system's indicator.
    struct Indicator: Equatable {
        enum Kind: Equatable {
            case volume, brightness
            case player(NowPlaying.Player)
        }

        let kind: Kind
        let level: Float
        let muted: Bool
    }

    /// Something UniMacHub is busy with, worth a glance.
    struct Work: Equatable {
        let title: String
        let symbol: String
    }

    // MARK: - Settings

    var isEnabled: Bool { didSet { save(isEnabled, Keys.enabled) } }
    var onPlainScreens: Bool { didSet { save(onPlainScreens, Keys.onPlainScreens) } }
    var replacesIndicators: Bool { didSet { save(replacesIndicators, Keys.replacesIndicators) } }
    var playerVolume: Bool { didSet { save(playerVolume, Keys.playerVolume) } }
    var showsNowPlaying: Bool { didSet { save(showsNowPlaying, Keys.nowPlaying) } }
    var showsShelf: Bool { didSet { save(showsShelf, Keys.shelf) } }

    // MARK: - What is on show

    private(set) var indicator: Indicator?
    private(set) var nowPlaying: NowPlaying?
    private(set) var artwork: NSImage?
    private(set) var shelf: [URL] = []
    var work: Work?
    var isHovering = false { didSet { scheduleExpansion() } }
    var isDropTargeted = false { didSet { scheduleExpansion() } }
    var isPinnedOpen = false
    private(set) var isExpanded = false

    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored private var expansionTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.enabled: true, Keys.onPlainScreens: true, Keys.replacesIndicators: false,
            Keys.playerVolume: true, Keys.nowPlaying: true, Keys.shelf: true,
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        onPlainScreens = defaults.bool(forKey: Keys.onPlainScreens)
        replacesIndicators = defaults.bool(forKey: Keys.replacesIndicators)
        playerVolume = defaults.bool(forKey: Keys.playerVolume)
        showsNowPlaying = defaults.bool(forKey: Keys.nowPlaying)
        showsShelf = defaults.bool(forKey: Keys.shelf)
        shelf = (defaults.stringArray(forKey: Keys.shelfPaths) ?? [])
            .map { URL(filePath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        listenToPlayers()
    }

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// How much room the island takes right now.
    var presentation: IslandGeometry.State {
        if isExpanded { return .expanded }
        if indicator != nil || work != nil || (showsNowPlaying && nowPlaying?.isPlaying == true) { return .wings }
        return .collapsed
    }

    // MARK: - Opening and closing

    func toggle() {
        isPinnedOpen.toggle()
        isExpanded = isPinnedOpen
    }

    func close() {
        isPinnedOpen = false
        isExpanded = false
    }

    /// Opens a moment after the pointer arrives, and closes a moment after it leaves, so
    /// passing over the top of the screen on the way to the menu bar does not open it.
    private func scheduleExpansion() {
        expansionTask?.cancel()
        let wanted = isHovering || isDropTargeted || isPinnedOpen
        guard wanted != isExpanded else { return }
        expansionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wanted ? 140 : 380))
            guard !Task.isCancelled, let self else { return }
            self.isExpanded = self.isHovering || self.isDropTargeted || self.isPinnedOpen
        }
    }

    // MARK: - Volume and brightness keys

    /// Takes a key press, or leaves it to macOS by returning false.
    func handle(_ press: MediaKeyPress) -> Bool {
        guard isEnabled, replacesIndicators else { return false }
        switch press.key {
        case .soundUp, .soundDown, .mute:
            return handleVolume(press)
        case .brightnessUp, .brightnessDown:
            guard let current = DisplayBrightness.brightness() else { return false }
            if press.isDown {
                let next = SystemVolume.stepped(current, up: press.key == .brightnessUp)
                DisplayBrightness.setBrightness(next)
                show(Indicator(kind: .brightness, level: next, muted: false))
            }
            return true
        default:
            return false
        }
    }

    private func handleVolume(_ press: MediaKeyPress) -> Bool {
        // A player that is playing takes the volume keys, so AirPlay speakers follow them.
        if press.key != .mute, playerVolume, let playing = nowPlaying, playing.isPlaying, isRunning(playing.player) {
            if press.isDown {
                let player = playing.player
                let change = press.key == .soundUp ? 6 : -6
                Task { [weak self] in
                    guard let level = await Self.changePlayerVolume(player, by: change) else { return }
                    self?.show(Indicator(kind: .player(player), level: Float(level) / 100, muted: false))
                }
            }
            return true
        }
        // An output whose volume macOS cannot set (most HDMI speakers) is left to macOS.
        guard let current = SystemVolume.volume() else { return false }
        guard press.isDown else { return true }
        switch press.key {
        case .mute:
            let muted = !SystemVolume.isMuted()
            SystemVolume.setMuted(muted)
            show(Indicator(kind: .volume, level: current, muted: muted))
        default:
            let next = SystemVolume.stepped(current, up: press.key == .soundUp)
            SystemVolume.setVolume(next)
            show(Indicator(kind: .volume, level: next, muted: next == 0))
        }
        return true
    }

    private func show(_ indicator: Indicator) {
        self.indicator = indicator
        indicatorTask?.cancel()
        indicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.indicator = nil
        }
    }

    // MARK: - Music and Spotify

    private func listenToPlayers() {
        let center = DistributedNotificationCenter.default()
        for player in NowPlaying.Player.allCases {
            observers.append(center.addObserver(
                forName: Notification.Name(player.notification), object: nil, queue: .main
            ) { [weak self] note in
                let info = note.userInfo ?? [:]
                let update = NowPlaying(player: player, userInfo: info)
                Task { @MainActor in self?.update(update, from: player) }
            })
        }
        // What was already playing before the island started, asked only of players that
        // are open: a script addressed to a closed app would open it.
        Task { [weak self] in
            for player in NowPlaying.Player.allCases where Self.running(player) {
                if let current = await Self.query(player), current.isPlaying {
                    self?.update(current, from: player)
                    break
                }
            }
        }
    }

    private func update(_ playing: NowPlaying?, from player: NowPlaying.Player) {
        let previous = nowPlaying
        if let playing {
            nowPlaying = playing
        } else if nowPlaying?.player == player {
            nowPlaying = nil
            artwork = nil
        }
        guard let playing, playing.title != previous?.title || playing.player != previous?.player else { return }
        artwork = nil
        guard playing.player == .music else { return }
        Task { [weak self] in
            self?.artwork = await Self.musicArtwork()
        }
    }

    func playPause() { send("playpause") }
    func nextTrack() { send("next track") }
    func previousTrack() { send("previous track") }

    private func send(_ command: String) {
        guard let player = nowPlaying?.player, isRunning(player) else { return }
        Task {
            _ = await Command.run("/usr/bin/osascript", ["-e", "tell application \"\(player.scriptName)\" to \(command)"])
        }
    }

    private func isRunning(_ player: NowPlaying.Player) -> Bool { Self.running(player) }

    nonisolated static func running(_ player: NowPlaying.Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    nonisolated static func query(_ player: NowPlaying.Player) async -> NowPlaying? {
        guard let output = await Command.run("/usr/bin/osascript", ["-e", NowPlaying.stateScript(for: player)]),
              output.status == 0
        else { return nil }
        return NowPlaying(player: player, scriptOutput: output.text)
    }

    nonisolated static func musicArtwork() async -> NSImage? {
        let script = "tell application \"Music\" to get raw data of artwork 1 of current track"
        guard let output = await Command.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(10)),
              output.status == 0, let data = NowPlaying.artwork(fromScriptOutput: output.text)
        else { return nil }
        return NSImage(data: data)
    }

    /// Changes a player's own volume and says where it ended up, from 0 to 100.
    nonisolated static func changePlayerVolume(_ player: NowPlaying.Player, by change: Int) async -> Int? {
        let script = """
        tell application "\(player.scriptName)"
            set sound volume to ((sound volume) + (\(change)))
            return sound volume
        end tell
        """
        guard let output = await Command.run("/usr/bin/osascript", ["-e", script]), output.status == 0 else { return nil }
        return Int(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Shelf

    func addToShelf(_ urls: [URL]) {
        for url in urls where url.isFileURL && !shelf.contains(url) {
            shelf.append(url)
        }
        saveShelf()
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
        saveShelf()
    }

    func clearShelf() {
        shelf = []
        saveShelf()
    }

    func airDropShelf() {
        guard !shelf.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: shelf)
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: Keys.shelfPaths)
    }
}
