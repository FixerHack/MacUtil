@testable import CleanerCore
import Foundation
import Testing

struct TranscriptTests {
    /// Feeds partial results one by one, as macOS sends them.
    private func stitch(_ parts: [String]) -> String {
        var committed = "", latest = ""
        for part in parts {
            (committed, latest) = Transcript.merge(committed: committed, latest: latest, incoming: part)
        }
        return Transcript.collapseRepeats(latest.trimmingCharacters(in: .whitespaces))
    }

    @Test func aRevisionReplacesInsteadOfRepeating() {
        // From the log: "В мене досить" revised into "У мене досить добре…" came out twice.
        #expect(stitch(["В мене", "В мене досить", "У мене досить добре розкажи анекдот"]) == "У мене досить добре розкажи анекдот")
        #expect(stitch(["Кошик", "Честь кошик"]) == "Честь кошик")
        #expect(stitch(["Поки можеш відпочивати", "Можеш відпочивати"]) == "Можеш відпочивати")
    }

    @Test func aFreshStartAfterAPauseIsKept() {
        #expect(stitch(["Відкрий браузер", "і знайди погоду в Києві"]) == "Відкрий браузер і знайди погоду в Києві")
    }

    @Test func aPhraseSaidTwiceIsKeptOnce() {
        #expect(Transcript.collapseRepeats("А які файли знаходяться в кошику Які файли знаходяться в кошику")
            == "А які файли знаходяться в кошику")
        #expect(Transcript.collapseRepeats("так так") == "так так")
        #expect(Transcript.collapseRepeats("Відкрий ютуб") == "Відкрий ютуб")
    }
}

struct WakeWordTests {
    @Test func findsTheWordAnywhereAndTakesItOut() {
        #expect(WakeWord.request(in: "Хабе, відкрий ютуб", word: "Хабе") == "відкрий ютуб")
        #expect(WakeWord.request(in: "відкрий ютуб, Хабе", word: "Хабе") == "відкрий ютуб")
        #expect(WakeWord.request(in: "Хабе", word: "Хабе") == "")
    }

    @Test func toleratesALetterMisheard() {
        #expect(WakeWord.request(in: "Хаба привіт", word: "Хабе") == "привіт")
        #expect(WakeWord.request(in: "Хаббе привіт", word: "Хабе") == "привіт")
        #expect(WakeWord.request(in: "Артур привіт", word: "Хабе") == nil)
        #expect(WakeWord.request(in: "хліб купи", word: "Хабе") == nil)
    }
}

struct GoodbyeTests {
    @Test func endsOnARealGoodbye() {
        for text in ["Відпочивай", "Дякую, відпочивай", "Смішно, добре, відпочивай", "Можеш відпочивати",
                     "Поки можеш відпочивати", "Ні, відпочивай", "Дякую", "Ну все, дякую", "па-па"] {
            #expect(Goodbye.isGoodbye(text), "\(text)")
        }
    }

    @Test func doesNotEndARequest() {
        for text in ["Відкрий ютуб, дякую", "Все добре, відкрий ютуб", "Стоп музику", "Дякую, а тепер відкрий пошту", "Так", "Ні"] {
            #expect(!Goodbye.isGoodbye(text), "\(text)")
        }
    }
}

struct MusicSourceTests {
    @Test func onlyMusicPlayers() {
        #expect(NowPlaying.isMusic(bundleID: "com.apple.Music", appName: "Music", album: ""))
        #expect(NowPlaying.isMusic(bundleID: "com.spotify.client", appName: "Spotify", album: ""))
        #expect(NowPlaying.isMusic(bundleID: "com.github.th-ch.youtube-music", appName: "YouTube Music", album: ""))
        #expect(NowPlaying.isMusic(bundleID: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod", appName: "YouTube Music", album: ""))
        // A YouTube Music tab reports the album; a video does not.
        #expect(NowPlaying.isMusic(bundleID: "com.brave.Browser", appName: "Brave Browser", album: "Hope"))
        #expect(!NowPlaying.isMusic(bundleID: "com.brave.Browser", appName: "Brave Browser", album: ""))
        // A voice message in Telegram.
        #expect(!NowPlaying.isMusic(bundleID: "ru.keepcoder.Telegram", appName: "Telegram", album: ""))
    }

    @Test func playingLongPastTheEndIsStale() {
        let start = Date(timeIntervalSince1970: 0)
        let note = NowPlaying(bundleID: "com.apple.Music", title: "x", artist: "y", album: "", isPlaying: true,
                              duration: 40, elapsed: 10, timestamp: start)
        #expect(!note.isStale(at: start.addingTimeInterval(20)))
        #expect(note.isStale(at: start.addingTimeInterval(3600)))
    }
}
