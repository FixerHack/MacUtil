import Foundation

/// What one app is playing: a song in Music or Spotify, or a video in a browser tab.
///
/// Three sources feed it. Music and Spotify announce every change themselves as a distributed
/// notification and answer AppleScript. Everything else, a browser tab included, goes through
/// macOS's Now Playing service, which since macOS 15.4 answers only Apple's own programs; the
/// island reads it through /usr/bin/perl, one of them (see `MediaRemoteLine`).
public struct NowPlaying: Equatable, Sendable, Identifiable {
    /// The two players that can be driven directly, whether or not they are the one macOS
    /// considers current.
    public enum Player: String, Sendable, CaseIterable {
        case music, spotify

        public init?(bundleID: String) {
            guard let player = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
            self = player
        }

        public var bundleID: String {
            switch self {
            case .music: "com.apple.Music"
            case .spotify: "com.spotify.client"
            }
        }

        /// The name to address it by in AppleScript.
        public var scriptName: String {
            switch self {
            case .music: "Music"
            case .spotify: "Spotify"
            }
        }

        /// The notification it posts on every change.
        public var notification: String {
            switch self {
            case .music: "com.apple.Music.playerInfo"
            case .spotify: "com.spotify.client.PlaybackStateChanged"
            }
        }
    }

    /// The app that plays it; for a browser tab, the browser.
    public let bundleID: String
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    /// Length in seconds, when the player says.
    public var duration: TimeInterval?
    /// How far it had got at `timestamp`, in seconds.
    public var elapsed: TimeInterval?
    public var timestamp: Date

    public var id: String { bundleID }
    /// Tells one track from the next within the same app.
    public var trackKey: String { title + "\u{1F}" + artist }
    public var player: Player? { Player(bundleID: bundleID) }

    public init(
        bundleID: String, title: String, artist: String, album: String, isPlaying: Bool,
        duration: TimeInterval? = nil, elapsed: TimeInterval? = nil, timestamp: Date = Date()
    ) {
        self.bundleID = bundleID
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        self.elapsed = elapsed
        self.timestamp = timestamp
    }

    public init(player: Player, title: String, artist: String, album: String, isPlaying: Bool) {
        self.init(bundleID: player.bundleID, title: title, artist: artist, album: album, isPlaying: isPlaying)
    }

    /// Where it is at a moment, counting on from the last report while it plays.
    public func position(at date: Date) -> TimeInterval? {
        guard let elapsed else { return nil }
        var position = elapsed
        if isPlaying { position += max(0, date.timeIntervalSince(timestamp)) }
        if let duration { position = min(position, duration) }
        return max(0, position)
    }

    /// How far through, from 0 to 1, when both the length and the place are known.
    public func progress(at date: Date) -> Double? {
        guard let duration, let position = position(at: date) else { return nil }
        return min(1, max(0, position / duration))
    }

    /// Whether two reports are of the same track, so the artwork can stay.
    public func isSameTrack(as other: NowPlaying?) -> Bool {
        guard let other else { return false }
        return bundleID == other.bundleID && title == other.title && artist == other.artist
    }

    /// Reads a player's notification. Nil when it has stopped altogether.
    public init?(player: Player, userInfo: [AnyHashable: Any], now: Date = Date()) {
        let state = userInfo["Player State"] as? String ?? ""
        guard state != "Stopped", let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
        // Spotify gives the length in milliseconds and the place in seconds; Music gives only
        // the length, in milliseconds, as "Total Time".
        let milliseconds = (userInfo["Duration"] as? NSNumber) ?? (userInfo["Total Time"] as? NSNumber)
        let position = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        self.init(
            bundleID: player.bundleID,
            title: title,
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            isPlaying: state == "Playing",
            duration: milliseconds.map { $0.doubleValue / 1000 },
            elapsed: position,
            timestamp: now
        )
    }

    /// AppleScript that answers state, name, artist, album, place and length on separate lines.
    public static func stateScript(for player: Player) -> String {
        // Spotify counts the length in milliseconds, Music in seconds.
        let length = player == .spotify ? "((duration of current track) / 1000)" : "(duration of current track)"
        return """
        tell application "\(player.scriptName)"
            set s to (player state as text)
            if s is "stopped" then return s
            return s & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & (player position as text) & linefeed & (\(length) as text)
        end tell
        """
    }

    /// Reads what `stateScript` printed.
    public init?(player: Player, scriptOutput: String, now: Date = Date()) {
        let lines = scriptOutput.components(separatedBy: "\n")
        guard lines.count >= 4, lines[0] != "stopped", !lines[1].isEmpty else { return nil }
        self.init(
            bundleID: player.bundleID, title: lines[1], artist: lines[2], album: lines[3],
            isPlaying: lines[0] == "playing",
            duration: lines.count > 5 ? Self.number(lines[5]) : nil,
            elapsed: lines.count > 4 ? Self.number(lines[4]) : nil,
            timestamp: now
        )
    }

    /// AppleScript writes numbers the way the Mac's region does, so 12,5 as often as 12.5.
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// The artwork as AppleScript prints raw data: «data JPEG…hex…».
    public static func artwork(fromScriptOutput text: String) -> Data? {
        guard let start = text.range(of: "«data "), let end = text.range(of: "»", range: start.upperBound ..< text.endIndex)
        else { return nil }
        // Four characters of type, then hex.
        let body = text[start.upperBound ..< end.lowerBound]
        guard body.count > 4 else { return nil }
        let hex = body.dropFirst(4)
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    /// Spotify's artwork is a picture on its own servers. Only those are fetched.
    public static func spotifyArtworkURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host(), host == "i.scdn.co" || host.hasSuffix(".scdn.co")
        else { return nil }
        return url
    }
}

/// One line from the Now Playing helper: what macOS considers the current player.
public struct MediaRemoteLine: Sendable {
    /// What plays, or nil when nothing is current any more.
    public let nowPlaying: NowPlaying?
    /// The app it belongs to, even when nothing plays.
    public let bundleID: String
    /// Identifies the picture; zero when there is none.
    public let artworkID: Int
    /// The picture, sent only when it changed.
    public let artwork: Data?

    /// Nil for a line that is not the helper's, or that says the service is closed.
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["error"] == nil
        else { return nil }
        // Sound from a web page belongs to a helper process; the browser is its parent.
        let parent = object["parent"] as? String ?? ""
        let own = object["bundle"] as? String ?? ""
        bundleID = parent.isEmpty ? own : parent
        artworkID = (object["artworkID"] as? NSNumber)?.intValue ?? 0
        artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }

        let title = object["title"] as? String ?? ""
        guard !title.isEmpty, !bundleID.isEmpty else {
            nowPlaying = nil
            return
        }
        let rate = (object["rate"] as? NSNumber)?.doubleValue
        let playing = (object["playing"] as? Bool ?? false) || (rate ?? 0) > 0
        let stamp = (object["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        nowPlaying = NowPlaying(
            bundleID: bundleID,
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            // Paused with the rate still reported as 1 happens; the playing flag wins then.
            isPlaying: rate == 0 ? false : playing,
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            elapsed: (object["elapsed"] as? NSNumber)?.doubleValue,
            timestamp: stamp
        )
    }

    /// The perl that loads the helper library and calls one of its functions.
    public static let perlScript = """
    use strict; use DynaLoader;
    my ($lib, $fn) = @ARGV;
    my $h = DynaLoader::dl_load_file($lib, 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, $fn) or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    /// MediaRemote's command numbers.
    public enum Command: Int, Sendable {
        case togglePlayPause = 2, nextTrack = 4, previousTrack = 5
    }
}
