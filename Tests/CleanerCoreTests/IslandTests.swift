@testable import CleanerCore
import CoreGraphics
import Foundation
import Testing

struct IslandGeometryTests {
    /// A 14-inch MacBook Pro: 1512 points wide, a 32-point menu bar with the notch in it.
    private let notched = IslandGeometry(
        screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
        leftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
        rightArea: CGRect(x: 850, y: 950, width: 662, height: 32)
    )

    @Test func findsTheNotchBetweenTheMenuBarHalves() throws {
        let notch = try #require(notched.notch)
        #expect(notch == CGRect(x: 662, y: 950, width: 188, height: 32))
        #expect(notched.resting == notch)
    }

    @Test func growsFromTheNotchAndStaysCentred() {
        let wings = notched.frame(for: .wings)
        #expect(wings.width == 188 + 2 * IslandGeometry.wingWidth)
        #expect(wings.midX == notched.resting.midX)
        #expect(wings.maxY == 982)

        let open = notched.frame(for: .expanded)
        #expect(open.size == IslandGeometry.expandedSize)
        #expect(open.midX == notched.resting.midX)
        #expect(open.maxY == 982)
    }

    @Test func leavesRoomForTheShouldersAndTheShadow() {
        let wings = notched.panelFrame(for: .wings)
        #expect(wings.width == notched.frame(for: .wings).width + 2 * IslandGeometry.shoulder(for: .wings))
        #expect(wings.maxY == 982 && wings.height == notched.frame(for: .wings).height)

        let open = notched.panelFrame(for: .expanded)
        let island = notched.frame(for: .expanded)
        #expect(open.contains(island) && open.maxY == 982 && open.midX == island.midX)
        #expect(open.minY == island.minY - IslandGeometry.shadowMargin)
    }

    @Test func fallsBackToATabWithoutANotch() {
        let plain = IslandGeometry(
            screen: CGRect(x: 1440, y: 0, width: 1920, height: 1080), topInset: 0, leftArea: nil, rightArea: nil
        )
        #expect(!plain.hasNotch)
        #expect(plain.resting.midX == CGFloat(2400))
        #expect(plain.resting.maxY == 1080)
        #expect(plain.resting.size == IslandGeometry.tabSize)
    }
}

struct MediaKeyTests {
    @Test func readsKeyStateAndRepeatFromTheEventData() throws {
        // Volume up, pressed: key 0 in the high half, 0x0A00 in the low.
        let down = try #require(MediaKeyPress(subtype: 8, data1: 0 << 16 | 0x0A00))
        #expect(down.key == .soundUp && down.isDown && !down.isRepeat && down.isVolume)

        let released = try #require(MediaKeyPress(subtype: 8, data1: 3 << 16 | 0x0B00))
        #expect(released.key == .brightnessDown && !released.isDown && released.isBrightness)

        let held = try #require(MediaKeyPress(subtype: 8, data1: 1 << 16 | 0x0A01))
        #expect(held.isRepeat)

        // Not subtype 8, or a key this does not handle.
        #expect(MediaKeyPress(subtype: 7, data1: 0x0A00) == nil)
        #expect(MediaKeyPress(subtype: 8, data1: 99 << 16 | 0x0A00) == nil)
    }

    @Test func stepsVolumeTheWayMacOSDoes() {
        #expect(SystemVolume.stepped(0.5, up: true) == 0.5625)
        #expect(SystemVolume.stepped(0.51, up: false) == 0.4375)
        #expect(SystemVolume.stepped(1, up: true) == 1)
        #expect(SystemVolume.stepped(0, up: false) == 0)
    }
}

struct NowPlayingTests {
    @Test func readsWhatThePlayersAnnounce() throws {
        let now = Date()
        let playing = try #require(NowPlaying(player: .spotify, userInfo: [
            "Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "Record",
            "Duration": NSNumber(value: 200_000), "Playback Position": NSNumber(value: 50.0),
        ], now: now))
        #expect(playing.player == .spotify && playing.title == "Song" && playing.isPlaying)
        #expect(playing.duration == 200 && playing.elapsed == 50)
        // Music gives only the length, in milliseconds.
        let music = try #require(NowPlaying(player: .music, userInfo: [
            "Player State": "Paused", "Name": "Song", "Total Time": NSNumber(value: 90_000),
        ]))
        #expect(!music.isPlaying && music.duration == 90 && music.elapsed == nil)
        #expect(NowPlaying(player: .music, userInfo: ["Player State": "Stopped", "Name": "Song"]) == nil)
    }

    @Test func countsOnWhilePlayingAndStopsAtTheEnd() {
        let start = Date(timeIntervalSince1970: 1000)
        let song = NowPlaying(
            bundleID: "com.google.Chrome", title: "Video", artist: "", album: "", isPlaying: true,
            duration: 100, elapsed: 40, timestamp: start
        )
        #expect(song.position(at: start.addingTimeInterval(10)) == 50)
        #expect(song.progress(at: start.addingTimeInterval(10)) == 0.5)
        #expect(song.position(at: start.addingTimeInterval(500)) == 100)
        var paused = song
        paused.isPlaying = false
        #expect(paused.position(at: start.addingTimeInterval(10)) == 40)
        #expect(song.player == nil)
    }

    @Test func readsTheAppleScriptAnswer() {
        let paused = NowPlaying(player: .music, scriptOutput: "paused\nSong\nBand\nRecord\n12,5\n240\n")
        #expect(paused?.title == "Song" && paused?.isPlaying == false)
        #expect(paused?.elapsed == 12.5 && paused?.duration == 240)
        #expect(NowPlaying(player: .music, scriptOutput: "stopped\n") == nil)
        #expect(NowPlaying.stateScript(for: .spotify).contains("tell application \"Spotify\""))
        #expect(NowPlaying.stateScript(for: .spotify).contains("/ 1000"))
    }

    @Test func turnsAppleScriptRawDataIntoBytes() {
        #expect(NowPlaying.artwork(fromScriptOutput: "«data JPEGFFD8FFE0»\n") == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(NowPlaying.artwork(fromScriptOutput: "missing value") == nil)
        #expect(NowPlaying.artwork(fromScriptOutput: "«data JPEGZZ»") == nil)
    }

    @Test func fetchesSpotifyArtworkOnlyFromSpotify() {
        #expect(NowPlaying.spotifyArtworkURL("https://i.scdn.co/image/ab67616d\n") != nil)
        #expect(NowPlaying.spotifyArtworkURL("http://i.scdn.co/image/x") == nil)
        #expect(NowPlaying.spotifyArtworkURL("https://example.com/i.scdn.co") == nil)
    }

    @Test func readsTheHelperLine() throws {
        let line = try #require(MediaRemoteLine(json: Data("""
        {"bundle":"com.google.Chrome.helper","parent":"com.google.Chrome","playing":true,"title":"Video",
         "artist":"Channel","duration":300,"elapsed":12,"rate":1,"timestamp":1000,"artworkID":7,"artwork":"AQID"}
        """.utf8)))
        #expect(line.bundleID == "com.google.Chrome")
        #expect(line.nowPlaying?.title == "Video" && line.nowPlaying?.isPlaying == true)
        #expect(line.nowPlaying?.duration == 300 && line.nowPlaying?.elapsed == 12)
        #expect(line.artworkID == 7 && line.artwork == Data([1, 2, 3]))

        let paused = try #require(MediaRemoteLine(json: Data(#"{"bundle":"com.apple.Safari","playing":true,"rate":0,"title":"T","artworkID":0}"#.utf8)))
        #expect(paused.nowPlaying?.isPlaying == false)

        let nothing = try #require(MediaRemoteLine(json: Data(#"{"bundle":"com.apple.Safari","playing":false,"artworkID":0}"#.utf8)))
        #expect(nothing.nowPlaying == nil && nothing.bundleID == "com.apple.Safari")
        #expect(MediaRemoteLine(json: Data(#"{"error":"unavailable"}"#.utf8)) == nil)
        #expect(MediaRemoteLine(json: Data("not json".utf8)) == nil)
    }
}
