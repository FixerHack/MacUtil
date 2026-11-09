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
    @Test func readsWhatThePlayersAnnounce() {
        let playing = NowPlaying(player: .spotify, userInfo: [
            "Player State": "Playing", "Name": "Song", "Artist": "Band", "Album": "Record",
        ])
        #expect(playing == NowPlaying(player: .spotify, title: "Song", artist: "Band", album: "Record", isPlaying: true))
        #expect(NowPlaying(player: .music, userInfo: ["Player State": "Paused", "Name": "Song"])?.isPlaying == false)
        #expect(NowPlaying(player: .music, userInfo: ["Player State": "Stopped", "Name": "Song"]) == nil)
    }

    @Test func readsTheAppleScriptAnswer() {
        let paused = NowPlaying(player: .music, scriptOutput: "paused\nSong\nBand\nRecord\n")
        #expect(paused?.title == "Song" && paused?.isPlaying == false)
        #expect(NowPlaying(player: .music, scriptOutput: "stopped\n") == nil)
        #expect(NowPlaying.stateScript(for: .spotify).contains("tell application \"Spotify\""))
    }

    @Test func turnsAppleScriptRawDataIntoBytes() {
        #expect(NowPlaying.artwork(fromScriptOutput: "«data JPEGFFD8FFE0»\n") == Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(NowPlaying.artwork(fromScriptOutput: "missing value") == nil)
        #expect(NowPlaying.artwork(fromScriptOutput: "«data JPEGZZ»") == nil)
    }
}
