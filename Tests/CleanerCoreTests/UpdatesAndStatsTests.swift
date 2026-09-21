@testable import CleanerCore
import Foundation
import Testing

struct AppUpdatesTests {
    let apps = [
        AppRecord(
            path: "/Applications/Visual Studio Code.app",
            name: "Code",
            bundleID: "com.microsoft.VSCode",
            version: "1.90.0",
            isAppStore: false,
            lastUsed: nil,
            size: 1
        ),
        AppRecord(
            path: "/Applications/Xcode.app",
            name: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            version: "26.0",
            isAppStore: true,
            lastUsed: nil,
            size: 1
        ),
    ]

    @Test func readsTheNewestAppcastItem() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
          <item><title>2.9</title><sparkle:version>290</sparkle:version><sparkle:shortVersionString>2.9</sparkle:shortVersionString>
            <enclosure url="https://example.com/2.9.zip"/></item>
          <item><title>2.10</title><enclosure url="https://example.com/2.10.zip" sparkle:version="2100" sparkle:shortVersionString="2.10"/></item>
        </channel></rss>
        """
        let latest = try #require(AppUpdates.latestAppcastItem(Data(xml.utf8)))
        #expect(latest.version == "2.10")
        #expect(latest.url?.absoluteString == "https://example.com/2.10.zip")
    }

    @Test func comparesVersionsNumerically() {
        #expect(AppUpdates.compare("1.10", "1.9") == .orderedDescending)
        #expect(AppUpdates.compare("2.0", "2.0") == .orderedSame)
    }

    @Test func parsesHomebrewAndAppStore() {
        let json = #"{"formulae":[],"casks":[{"name":"visual-studio-code","installed_versions":["1.90.0"],"current_version":"1.95.2"}]}"#
        let brew = AppUpdates.parseBrewOutdated(Data(json.utf8), apps: apps)
        #expect(brew.first?.availableVersion == "1.95.2")
        #expect(brew.first?.source == .homebrew(cask: "visual-studio-code"))

        let mas = AppUpdates.parseMasOutdated("497799835 Xcode (26.0 -> 27.0)\n123 Unknown (1 -> 2)", apps: apps)
        #expect(mas.count == 1)
        #expect(mas.first?.availableVersion == "27.0")
        #expect(mas.first?.source == .appStore(id: "497799835"))
    }
}

struct SystemStatsTests {
    @Test func samplesRealValues() async throws {
        let stats = SystemStats()
        _ = stats.sample() // first sample only sets the baseline for rates
        try await Task.sleep(for: .milliseconds(300))
        let sample = stats.sample()
        #expect(sample.cpu >= 0 && sample.cpu <= 1)
        #expect(sample.memory != nil)
        #expect(sample.disk != nil)
        #expect(sample.download >= 0 && sample.upload >= 0)
    }
}
