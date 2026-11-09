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

    /// A track's picture, kept with the track it belongs to so a late answer for the last
    /// track never lands on the next one.
    struct Artwork {
        let track: String
        let image: NSImage
    }

    // MARK: - Settings

    var isEnabled: Bool { didSet { save(isEnabled, Keys.enabled) } }
    var onPlainScreens: Bool { didSet { save(onPlainScreens, Keys.onPlainScreens) } }
    var replacesIndicators: Bool { didSet { save(replacesIndicators, Keys.replacesIndicators) } }
    var playerVolume: Bool { didSet { save(playerVolume, Keys.playerVolume) } }
    var showsNowPlaying: Bool { didSet { save(showsNowPlaying, Keys.nowPlaying) } }
    var showsShelf: Bool { didSet { save(showsShelf, Keys.shelf) } }

    /// What the opened island shows.
    enum Page: Equatable { case home, agents }

    // MARK: - What is on show

    let agents = AgentsModel()
    /// Brings UniMacHub's window forward; set by the controller, which knows the app.
    @ObservationIgnored var openMain: (() -> Void)?
    /// The Dock's settings, for switching its profile from here; set by the controller.
    @ObservationIgnored var dock: DockModel?
    let calendar = CalendarFeed()
    let batteries = BatteriesFeed()
    var page: Page = .home

    /// Where the island is; set by the controller, read by the view for its sizes.
    var geometry: IslandGeometry?
    private(set) var indicator: Indicator?
    /// Every app that is playing or was playing a moment ago, in the order they appeared.
    private(set) var sessions: [NowPlaying] = []
    private(set) var artworks: [String: Artwork] = [:]
    /// The one the opened island shows; swiping changes it.
    var selectedID: String?
    /// The app macOS's Now Playing service considers current, which its play buttons reach.
    private(set) var currentFeedBundleID: String?
    private(set) var shelf: [URL] = []
    var work: Work?
    var isHovering = false { didSet { if isHovering != oldValue { hoverChanged() } } }
    var isDropTargeted = false { didSet { if isDropTargeted != oldValue { scheduleExpansion() } } }
    private(set) var isExpanded = false {
        didSet {
            guard isExpanded, !oldValue else { return }
            batteries.refresh()
            calendar.refresh()
            // A question waiting for an answer is what the person came for.
            if !agents.questions.isEmpty { page = .agents }
        }
    }
    /// For a few seconds after the music stops, so the island does not snap shut at once.
    private(set) var isLingering = false

    @ObservationIgnored private var indicatorTask: Task<Void, Never>?
    @ObservationIgnored private var expansionTask: Task<Void, Never>?
    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var feed: MediaRemoteFeed?
    @ObservationIgnored private var hoverSuppressed = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var names: [String: String] = [:]

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
        if indicator != nil || work != nil || agents.attention != nil || calendar.soon != nil { return .wings }
        if showsNowPlaying, playing != nil || (isLingering && featured != nil) { return .wings }
        return .collapsed
    }

    /// The session swiped to, else the first.
    var selected: NowPlaying? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    /// Something that is playing: the chosen one if it is, else any.
    var playing: NowPlaying? {
        if let selected, selected.isPlaying { return selected }
        return sessions.first(where: \.isPlaying)
    }

    /// What the closed island shows beside the notch.
    var featured: NowPlaying? { playing ?? selected }

    // MARK: - Opening and closing

    /// A click: opens a closed island at once, and closes an open one.
    func tapped() {
        if isExpanded {
            close()
        } else {
            expansionTask?.cancel()
            isExpanded = true
        }
    }

    /// Closes it, and keeps it closed until the pointer has left and come back.
    func close() {
        expansionTask?.cancel()
        isExpanded = false
        hoverSuppressed = isHovering
    }

    private func hoverChanged() {
        if !isHovering { hoverSuppressed = false }
        scheduleExpansion()
    }

    /// Opens a moment after the pointer arrives, and closes a moment after it leaves, so
    /// passing over the top of the screen on the way to the menu bar does not open it.
    private func scheduleExpansion() {
        expansionTask?.cancel()
        let wanted = (isHovering && !hoverSuppressed) || isDropTargeted
        guard wanted != isExpanded else { return }
        expansionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(wanted ? 160 : 320))
            guard !Task.isCancelled, let self else { return }
            let now = (self.isHovering && !self.hoverSuppressed) || self.isDropTargeted
            if now != self.isExpanded { self.isExpanded = now }
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
        if press.key != .mute, playerVolume, let player = playing?.player, Self.running(player) {
            if press.isDown {
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

    // MARK: - Players

    /// Runs the Now Playing helper while the island shows music, and stops it otherwise.
    func setFeedRunning(_ running: Bool) {
        if running {
            if feed == nil {
                feed = MediaRemoteFeed { [weak self] line in self?.received(line) }
            }
            feed?.start()
        } else if let feed {
            feed.stop()
            self.feed = nil
            currentFeedBundleID = nil
        }
    }

    private func listenToPlayers() {
        let center = DistributedNotificationCenter.default()
        for player in NowPlaying.Player.allCases {
            observers.append(center.addObserver(
                forName: Notification.Name(player.notification), object: nil, queue: .main
            ) { [weak self] note in
                let update = NowPlaying(player: player, userInfo: note.userInfo ?? [:])
                Task { @MainActor in self?.announced(update, by: player) }
            })
        }
        // A player that quits takes its card with it; so does a browser.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            Task { @MainActor in self?.remove(bundleID) }
        })
        // What was already playing before the island started, asked only of players that
        // are open: a script addressed to a closed app would open it.
        Task { [weak self] in
            for player in NowPlaying.Player.allCases where Self.running(player) {
                if let current = await Self.query(player) {
                    self?.upsert(current)
                }
            }
        }
    }

    /// A notification from Music or Spotify.
    private func announced(_ update: NowPlaying?, by player: NowPlaying.Player) {
        guard let update else { return remove(player.bundleID) }
        upsert(update)
        // Music does not say where in the track it is; ask.
        if update.elapsed == nil {
            Task { [weak self] in
                if let full = await Self.query(player), full.isSameTrack(as: update) { self?.upsert(full) }
            }
        }
    }

    /// A line from the Now Playing helper.
    private func received(_ line: MediaRemoteLine) {
        let previous = currentFeedBundleID
        if currentFeedBundleID != line.bundleID { currentFeedBundleID = line.bundleID }
        guard let update = line.nowPlaying else {
            // Nothing current any more, such as a closed tab. Music and Spotify say for themselves.
            if let previous, NowPlaying.Player(bundleID: previous) == nil { remove(previous) }
            return
        }
        upsert(update)
        if let data = line.artwork, let image = NSImage(data: data) {
            artworks[update.id] = Artwork(track: update.trackKey, image: image)
        } else if line.artworkID == 0, update.player == nil, artworks[update.id]?.track != update.trackKey {
            artworks[update.id] = nil
        }
    }

    /// Adds a session or brings it up to date, keeping what the new report leaves out.
    private func upsert(_ update: NowPlaying) {
        let wasPlaying = playing != nil
        var merged = update
        if let index = sessions.firstIndex(where: { $0.id == update.id }) {
            let old = sessions[index]
            if old.isSameTrack(as: update) {
                if merged.duration == nil { merged.duration = old.duration }
                if merged.elapsed == nil {
                    merged.elapsed = old.position(at: update.timestamp)
                }
            }
            if merged != old { sessions[index] = merged }
            if !old.isSameTrack(as: merged) { trackChanged(merged) }
            if merged.isPlaying, !old.isPlaying { selectedID = merged.id }
        } else {
            sessions.append(merged)
            trackChanged(merged)
            if merged.isPlaying || selectedID == nil { selectedID = merged.id }
        }
        settle(wasPlaying: wasPlaying)
    }

    private func remove(_ id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        let wasPlaying = playing != nil
        sessions.removeAll { $0.id == id }
        artworks[id] = nil
        if selectedID == id {
            selectedID = sessions.first(where: \.isPlaying)?.id ?? sessions.first?.id
        }
        settle(wasPlaying: wasPlaying)
    }

    /// When the music stops, the island keeps its wings a few seconds longer and then folds
    /// them in slowly, instead of snapping shut the moment pause is pressed.
    private func settle(wasPlaying: Bool) {
        let isPlaying = playing != nil
        if isPlaying {
            lingerTask?.cancel()
            if isLingering { isLingering = false }
        } else if wasPlaying {
            isLingering = true
            lingerTask?.cancel()
            lingerTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.isLingering = false
            }
        }
    }

    /// Fetches the picture for a new track from the player itself, unless the Now Playing
    /// helper already sent one.
    private func trackChanged(_ session: NowPlaying) {
        guard let player = session.player else { return }
        let key = session.trackKey
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.artworks[session.id]?.track != key,
                  self.sessions.first(where: { $0.id == session.id })?.trackKey == key
            else { return }
            let data = player == .music ? await Self.musicArtwork() : await Self.spotifyArtwork()
            guard let data, let image = NSImage(data: data),
                  self.sessions.first(where: { $0.id == session.id })?.trackKey == key
            else { return }
            self.artworks[session.id] = Artwork(track: key, image: image)
        }
    }

    func artwork(for session: NowPlaying) -> NSImage? {
        guard let artwork = artworks[session.id], artwork.track == session.trackKey else { return nil }
        return artwork.image
    }

    // MARK: - Controls

    func playPause(_ session: NowPlaying) {
        guard control(session, script: "playpause", command: .togglePlayPause) else { return }
        // Shown at once; the player's own report follows and corrects it if need be.
        var changed = session
        changed.elapsed = session.position(at: Date())
        changed.timestamp = Date()
        changed.isPlaying.toggle()
        upsert(changed)
    }

    func nextTrack(_ session: NowPlaying) { _ = control(session, script: "next track", command: .nextTrack) }
    func previousTrack(_ session: NowPlaying) { _ = control(session, script: "previous track", command: .previousTrack) }

    /// Whether the play buttons reach it: Music and Spotify always, anything else only while
    /// it is the one macOS considers current.
    func canControl(_ session: NowPlaying) -> Bool {
        if let player = session.player { return Self.running(player) }
        return session.bundleID == currentFeedBundleID
    }

    func canSeek(_ session: NowPlaying) -> Bool {
        session.duration != nil && session.elapsed != nil && canControl(session)
    }

    func seek(_ session: NowPlaying, to fraction: Double) {
        guard let duration = session.duration, canControl(session) else { return }
        let seconds = max(0, min(duration, fraction * duration))
        if let player = session.player {
            let place = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            Task { _ = await Command.run("/usr/bin/osascript", ["-e", "tell application \"\(player.scriptName)\" to set player position to \(place)"]) }
        } else {
            Task { await MediaRemoteFeed.seek(to: seconds) }
        }
        var moved = session
        moved.elapsed = seconds
        moved.timestamp = Date()
        upsert(moved)
    }

    /// Sends a button press; false when it could not be sent and the app was brought up instead.
    private func control(_ session: NowPlaying, script: String, command: MediaRemoteLine.Command) -> Bool {
        if let player = session.player, Self.running(player) {
            Task { _ = await Command.run("/usr/bin/osascript", ["-e", "tell application \"\(player.scriptName)\" to \(script)"]) }
            return true
        }
        if session.bundleID == currentFeedBundleID {
            Task { await MediaRemoteFeed.send(command) }
            return true
        }
        openApp(session.bundleID)
        return false
    }

    func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func appIcon(_ bundleID: String) -> NSImage? {
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    func appName(_ bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        names[bundleID] = name
        return name
    }

    nonisolated static func running(_ player: NowPlaying.Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    nonisolated static func query(_ player: NowPlaying.Player) async -> NowPlaying? {
        guard let output = await Command.run("/usr/bin/osascript", ["-e", NowPlaying.stateScript(for: player)]),
              output.status == 0
        else { return nil }
        return NowPlaying(player: player, scriptOutput: output.text)
    }

    nonisolated static func musicArtwork() async -> Data? {
        let script = "tell application \"Music\" to get raw data of artwork 1 of current track"
        guard let output = await Command.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(10)),
              output.status == 0
        else { return nil }
        return NowPlaying.artwork(fromScriptOutput: output.text)
    }

    /// Spotify's picture lives on its own servers, which it is already talking to.
    nonisolated static func spotifyArtwork() async -> Data? {
        let script = "tell application \"Spotify\" to get artwork url of current track"
        guard let output = await Command.run("/usr/bin/osascript", ["-e", script]), output.status == 0,
              let url = NowPlaying.spotifyArtworkURL(output.text)
        else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return try? await URLSession.shared.data(for: request).0
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
