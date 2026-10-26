@testable import CleanerCore
import Foundation
import Testing

@Suite struct InstallerReceiptTests {
    @Test func readsWhatPkgutilSaysAboutAPackage() throws {
        let output = """
        package-id: com.example.Driver
        version: 2.4.1
        volume: /
        location: Library/Extensions
        install-time: 1700000000
        """
        let receipt = try #require(InstallerReceipts.parseInfo(output, packageID: "com.example.Driver"))
        #expect(receipt.packageID == "com.example.Driver")
        #expect(receipt.version == "2.4.1")
        #expect(receipt.location == "Library/Extensions")
        #expect(receipt.installedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!receipt.isApple)
    }

    @Test func buildsTheFolderRelativePathsHangFrom() throws {
        let rooted = try #require(InstallerReceipts.parseInfo(
            "package-id: a\nvolume: /\nlocation: Library/Extensions\n", packageID: "a"
        ))
        #expect(rooted.root == "/Library/Extensions")

        // A package with no location lays its files straight onto the volume.
        let bare = try #require(InstallerReceipts.parseInfo("package-id: b\nvolume: /\nlocation: \n", packageID: "b"))
        #expect(bare.root == "/")
    }

    @Test func recognisesApplesOwnPackages() throws {
        let apple = try #require(InstallerReceipts.parseInfo("package-id: com.apple.pkg.CLTools\n", packageID: "x"))
        #expect(apple.isApple)
    }

    @Test func refusesThePlacesNoPackageMayEmpty() {
        let refused = InstallerReceipts.refused(in: [
            "/System/Library/Frameworks/Thing",
            "/usr/bin/thing",
            "/usr/local/bin/thing",
            "/Library/Application Support/Example/thing",
            "/private/etc/hosts",
        ])
        #expect(refused.contains("/System/Library/Frameworks/Thing"))
        #expect(refused.contains("/usr/bin/thing"))
        #expect(refused.contains("/private/etc/hosts"))
        // Things a package legitimately owns stay removable.
        #expect(!refused.contains("/usr/local/bin/thing"))
        #expect(!refused.contains("/Library/Application Support/Example/thing"))
    }

    @Test func quotesPathsTheShellWouldOtherwiseSplit() {
        #expect(InstallerReceipts.shellQuoted("/Library/My App/file") == "'/Library/My App/file'")
        #expect(InstallerReceipts.shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test func readsTheReceiptsOfThisMac() async {
        // Every Mac has Apple's own, and none of them may be offered for removal.
        let apple = await InstallerReceipts.list(includingApple: true)
        #expect(!apple.isEmpty)
        #expect(apple.allSatisfy { !$0.packageID.isEmpty })
    }
}

@Suite struct HomebrewCaskTests {
    @Test func takesTheAppsOutOfWhatACaskInstalled() {
        let cask = HomebrewCask(
            token: "ghostty", version: "1.3.1", artifacts: ["Ghostty.app", "ghostty.1", "README"]
        )
        #expect(cask.apps == ["Ghostty.app"])
    }

    @Test func findsTheCaskThatInstalledAnApp() {
        let casks = [
            HomebrewCask(token: "ghostty", version: "1.3.1", artifacts: ["Ghostty.app"]),
            HomebrewCask(token: "prismlauncher", version: "11.1.0", artifacts: ["Prism Launcher.app"]),
            HomebrewCask(token: "ngrok", version: "3.39.9", artifacts: ["ngrok"]),
        ]
        #expect(HomebrewCasks.cask(forAppAt: "/Applications/Ghostty.app", in: casks)?.token == "ghostty")
        #expect(HomebrewCasks.cask(forAppAt: "/Applications/Prism Launcher.app", in: casks)?.token == "prismlauncher")
        // An app nobody brewed belongs to nobody.
        #expect(HomebrewCasks.cask(forAppAt: "/Applications/Safari.app", in: casks) == nil)
        // A cask with no app cannot claim one.
        #expect(!casks.contains { $0.token == "ngrok" && !$0.apps.isEmpty })
    }

    @Test func readsTheCaskroomOfThisMac() {
        guard HomebrewCasks.isInstalled else { return }
        let casks = HomebrewCasks.installed()
        // Nothing hidden, and every cask has a version folder behind it.
        #expect(casks.allSatisfy { !$0.token.hasPrefix(".") && !$0.version.hasPrefix(".") })
    }
}
