@testable import CleanerCore
import Foundation
import Testing

struct SystemDockTests {
    @Test func putsBackExactlyWhatWasThere() {
        // Keys that were not set are deleted again, not written with a guess.
        #expect(SystemDock.restoreCommands(.init(autohide: nil, delay: nil)) == [
            ["delete", "com.apple.dock", "autohide"],
            ["delete", "com.apple.dock", "autohide-delay"],
        ])
        #expect(SystemDock.restoreCommands(.init(autohide: false, delay: 0.2)) == [
            ["write", "com.apple.dock", "autohide", "-bool", "false"],
            ["write", "com.apple.dock", "autohide-delay", "-float", "0.2"],
        ])
        #expect(SystemDock.hideCommands().contains(["write", "com.apple.dock", "autohide-delay", "-float", "1000"]))
    }

    @Test func knowsItsOwnHiding() {
        #expect(SystemDock.isHiddenByUs(.init(autohide: true, delay: 1000)))
        #expect(!SystemDock.isHiddenByUs(.init(autohide: true, delay: 0.5)))
        #expect(!SystemDock.isHiddenByUs(.init(autohide: nil, delay: nil)))
    }

    @Test func readsThePinnedApps() {
        let entries: [Any] = [
            ["tile-data": ["file-data": ["_CFURLString": "file:///System/Applications/Mail.app/", "_CFURLStringType": 15]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Applications/Visual%20Studio%20Code.app/"]]],
            ["tile-data": ["file-data": ["_CFURLString": "file:///Users/me/Downloads/"]]],
            ["tile-type": "spacer-tile"],
        ]
        let apps = SystemDock.pinnedApps(from: entries)
        #expect(apps.map(\.path) == ["/System/Applications/Mail.app", "/Applications/Visual Studio Code.app"])
    }

    @Test func growsUnderThePointerAndEasesOff() {
        let size: CGFloat = 96
        #expect(DockMagnification.scale(distance: 0, iconSize: size, magnification: 1.335) == 1.335)
        let near = DockMagnification.scale(distance: 60, iconSize: size, magnification: 1.335)
        let far = DockMagnification.scale(distance: 180, iconSize: size, magnification: 1.335)
        #expect(near < 1.335 && near > far && far > 1)
        #expect(DockMagnification.scale(distance: 300, iconSize: size, magnification: 1.335) == 1)
        #expect(DockMagnification.scale(distance: 0, iconSize: size, magnification: 1) == 1)
    }
}

struct WeatherTests {
    @Test func findsTheTownAndReadsTheWeather() throws {
        let search = Data(#"{"results":[{"name":"Київ","latitude":50.45466,"longitude":30.5238,"country":"Україна"}]}"#.utf8)
        let place = try #require(Weather.place(fromSearch: search))
        #expect(place.name == "Київ" && place.latitude == 50.45466)
        #expect(Weather.place(fromSearch: Data(#"{"generationtime_ms":0.5}"#.utf8)) == nil)

        let url = try #require(Weather.forecastURL(for: place))
        #expect(url.absoluteString.contains("latitude=50.455") && url.host() == "api.open-meteo.com")
        #expect(Weather.searchURL(for: "Київ", language: "uk")?.query?.contains("language=uk") == true)

        let forecast = Data(#"{"current":{"temperature_2m":3.4,"weather_code":61,"is_day":0},"daily":{"temperature_2m_max":[5.1],"temperature_2m_min":[-1.2]}}"#.utf8)
        let now = try #require(Weather.now(fromForecast: forecast))
        #expect(now.temperature == 3.4 && now.code == 61 && !now.isDay && now.high == 5.1 && now.low == -1.2)
        #expect(Weather.symbol(for: 61, isDay: false) == "cloud.rain.fill")
        #expect(Weather.symbol(for: 0, isDay: false) == "moon.stars.fill")
    }
}
