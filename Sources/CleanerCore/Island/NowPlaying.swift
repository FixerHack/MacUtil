import Foundation

/// What a music player is playing, as it announces it.
///
/// Apple closed the private Now Playing framework to other apps in macOS 15.4. Music and
/// Spotify still announce every change themselves, to anyone listening, as a distributed
/// notification; and both answer AppleScript for artwork and the play buttons. That covers
/// the two players most people use without anything private. Sound from a browser tab is
/// not covered.
public struct NowPlaying: Equatable, Sendable {
    public enum Player: String, Sendable, CaseIterable {
        case music, spotify

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

    public let player: Player
    public let title: String
    public let artist: String
    public let album: String
    public let isPlaying: Bool

    public init(player: Player, title: String, artist: String, album: String, isPlaying: Bool) {
        self.player = player
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
    }

    /// Reads a player's notification. Nil when it has stopped altogether.
    public init?(player: Player, userInfo: [AnyHashable: Any]) {
        let state = userInfo["Player State"] as? String ?? ""
        guard state != "Stopped", let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
        self.init(
            player: player,
            title: title,
            artist: userInfo["Artist"] as? String ?? "",
            album: userInfo["Album"] as? String ?? "",
            isPlaying: state == "Playing"
        )
    }

    /// AppleScript that answers state, name, artist and album on separate lines.
    public static func stateScript(for player: Player) -> String {
        """
        tell application "\(player.scriptName)"
            set s to (player state as text)
            if s is "stopped" then return s
            return s & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track)
        end tell
        """
    }

    /// Reads what `stateScript` printed.
    public init?(player: Player, scriptOutput: String) {
        let lines = scriptOutput.components(separatedBy: "\n")
        guard lines.count >= 4, lines[0] != "stopped", !lines[1].isEmpty else { return nil }
        self.init(player: player, title: lines[1], artist: lines[2], album: lines[3], isPlaying: lines[0] == "playing")
    }

    /// The artwork as AppleScript prints raw data: «data JPEG…hex…». Music only; Spotify
    /// gives a web address instead, and fetching it would send something off this Mac.
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
}
