@testable import CleanerCore
import Foundation
import Testing

private func makeHome(_ files: [String]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appending(path: "mc-apps-\(UUID().uuidString)")
    for file in files {
        let url = home.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3000).write(to: url)
    }
    return home
}

struct AppLeftoversTests {
    @Test func findsDataByBundleIDAndName() async throws {
        let home = try makeHome([
            "Library/Application Support/com.acme.Rocket/db.sqlite",
            "Library/Application Support/Rocket/state.json",
            "Library/Caches/com.acme.Rocket/cache.bin",
            "Library/Preferences/com.acme.Rocket.plist",
            "Library/Preferences/com.acme.Rocket.helper.plist",
            "Library/Preferences/com.acme.RocketLauncher.plist", // a different app
            "Library/Containers/com.acme.Rocket.ShareExtension/Data/x",
            "Library/Group Containers/ABCDE12345.com.acme.Rocket/shared",
            "Library/Saved Application State/com.acme.Rocket.savedState/windows.plist",
            "Library/Caches/Rocketship/unrelated",
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let found = await AppLeftovers.find(
            bundleID: "com.acme.Rocket", name: "Rocket", home: home.path(percentEncoded: false)
        )
        let names = Set(found.map(\.name))
        #expect(names == [
            "com.acme.Rocket", "Rocket", "com.acme.Rocket.plist", "com.acme.Rocket.helper.plist",
            "com.acme.Rocket.ShareExtension", "ABCDE12345.com.acme.Rocket", "com.acme.Rocket.savedState",
        ])
        #expect(found.first { $0.name == "Rocket" }?.match == .name)
        #expect(found.allSatisfy { !$0.requiresAdmin })
    }

    @Test func genericNamesAreNotMatched() async throws {
        let home = try makeHome(["Library/Application Support/Google/data"])
        defer { try? FileManager.default.removeItem(at: home) }
        let found = await AppLeftovers.find(bundleID: nil, name: "Google", home: home.path(percentEncoded: false))
        #expect(found.isEmpty)
    }
}

struct InstalledAppsTests {
    let installed = InstalledApps(
        bundleIDs: ["com.docker.docker", "com.brave.Browser"],
        commandLineTools: ["swiftformat"]
    )

    @Test func recognizesOwnedData() {
        #expect(installed.owns("com.brave.Browser"))
        #expect(installed.owns("com.brave.Browser.helper"))
        #expect(installed.owns("com.docker.vmnetd"), "same vendor")
        #expect(installed.owns("com.apple.Safari"))
        #expect(installed.owns("com.charcoaldesign.swiftformat"), "a command-line tool")
        #expect(!installed.owns("com.removed.App"))
    }

    @Test func recognizesBundleIDShapes() {
        #expect(InstalledApps.looksLikeBundleID("com.example.App"))
        #expect(InstalledApps.looksLikeBundleID("org.videolan.vlc"))
        #expect(!InstalledApps.looksLikeBundleID("Google"))
        #expect(!InstalledApps.looksLikeBundleID("Code Cache.v2.x"))
        #expect(!InstalledApps.looksLikeBundleID("2024.05.backup"))
    }

    @Test func findsLeftoversOfRemovedApps() async throws {
        let home = try makeHome([
            "Library/Caches/com.removed.App/cache.db",
            "Library/Caches/com.brave.Browser/cache.db",
            "Library/Caches/Firefox/profile",
            "Library/Caches/org.swift.swiftpm/manifests", // claimed by Developer Junk
            "Library/Preferences/com.removed.App.plist",
            "Library/Preferences/com.brave.Browser.plist",
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        // A launch agent pointing to a program that no longer exists.
        let agent = home.appending(path: "Library/LaunchAgents/com.removed.App.agent.plist")
        try FileManager.default.createDirectory(
            at: agent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": "com.removed.App.agent",
            "Program": "/Applications/Removed.app/Contents/MacOS/agent",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agent)

        let context = JunkContext(home: home, installed: installed)
        let categories = await JunkScanner.scan(JunkCatalog.rules(in: .leftovers), context: context)
        let byRule = Dictionary(uniqueKeysWithValues: categories.map { ($0.rule.id, $0.items.map(\.name)) })

        #expect(byRule["leftovers.caches"] == ["com.removed.App"])
        #expect(byRule["leftovers.preferences"] == ["com.removed.App.plist"])
        #expect(byRule["leftovers.launchAgents"] == ["com.removed.App.agent.plist"])
    }
}
