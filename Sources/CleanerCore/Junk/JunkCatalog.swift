import Foundation

/// Every junk rule MacUtil knows. Paths starting with `~` are relative to the
/// home folder. More specific rules come first: their folders are excluded from
/// the broad ones (for example the Homebrew cache from "User caches").
public enum JunkCatalog {
    public static let all: [JunkRule] = developer + system

    public static func rules(in group: JunkRule.Group) -> [JunkRule] {
        all.filter { $0.group == group }
    }

    // MARK: - Developer

    static let developer: [JunkRule] = [
        JunkRule(
            id: "xcode.derivedData", group: .developer,
            title: "Xcode build data",
            details: "Intermediate build products in DerivedData. Xcode rebuilds them on the next build.",
            safety: .safe,
            sources: [.contents(of: "~/Library/Developer/Xcode/DerivedData")],
            appBundleIDs: ["com.apple.dt.Xcode"]
        ),
        JunkRule(
            id: "xcode.deviceSupport", group: .developer,
            title: "Device support files",
            details: "Debug symbols copied from connected iPhones and other devices. Xcode copies them again when a device connects.",
            safety: .safe,
            sources: [
                .contents(of: "~/Library/Developer/Xcode/iOS DeviceSupport"),
                .contents(of: "~/Library/Developer/Xcode/watchOS DeviceSupport"),
                .contents(of: "~/Library/Developer/Xcode/tvOS DeviceSupport"),
                .contents(of: "~/Library/Developer/Xcode/visionOS DeviceSupport"),
            ]
        ),
        JunkRule(
            id: "xcode.archives", group: .developer,
            title: "Xcode archives",
            details: "Archived app builds. You need them to symbolicate crash reports of released versions.",
            safety: .review,
            sources: [.contents(of: "~/Library/Developer/Xcode/Archives")]
        ),
        JunkRule(
            id: "xcode.caches", group: .developer,
            title: "Xcode and simulator caches",
            details: "Caches of Xcode, SwiftUI previews and the iOS Simulator.",
            safety: .safe,
            sources: [
                .paths(["~/Library/Caches/com.apple.dt.Xcode"]),
                .contents(of: "~/Library/Developer/Xcode/UserData/Previews"),
                .contents(of: "~/Library/Developer/CoreSimulator/Caches"),
            ],
            appBundleIDs: ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
        ),
        JunkRule(
            id: "packages.javascript", group: .developer,
            title: "JavaScript package caches",
            details: "Download caches of npm, Yarn, pnpm, Bun and node-gyp. Packages are downloaded again when needed.",
            safety: .safe,
            sources: [.paths([
                "~/.npm/_cacache", "~/Library/Caches/Yarn", "~/Library/Caches/pnpm", "~/.bun/install/cache",
                "~/Library/Caches/node-gyp", "~/.cache/node-gyp",
            ])]
        ),
        JunkRule(
            id: "packages.python", group: .developer,
            title: "Python package caches",
            details: "Download caches of pip, uv and Poetry.",
            safety: .safe,
            sources: [.paths(["~/Library/Caches/pip", "~/.cache/pip", "~/.cache/uv", "~/Library/Caches/pypoetry"])]
        ),
        JunkRule(
            id: "packages.homebrew", group: .developer,
            title: "Homebrew downloads",
            details: "Downloaded bottles and installers kept after installation.",
            safety: .safe,
            sources: [.paths(["~/Library/Caches/Homebrew"])]
        ),
        JunkRule(
            id: "packages.other", group: .developer,
            title: "Other package caches",
            details: "Caches of CocoaPods, Carthage, Swift Package Manager, Gradle, Maven, Cargo and Go builds.",
            safety: .safe,
            sources: [.paths([
                "~/Library/Caches/CocoaPods", "~/Library/Caches/org.carthage.CarthageKit",
                "~/Library/Caches/org.swift.swiftpm", "~/.gradle/caches", "~/.m2/repository",
                "~/.cargo/registry/cache", "~/Library/Caches/go-build",
            ])]
        ),
        JunkRule(
            id: "tools.browsersForTesting", group: .developer,
            title: "Test browsers",
            details: "Browsers downloaded by Playwright and Puppeteer for automated tests.",
            safety: .review,
            sources: [.paths(["~/Library/Caches/ms-playwright", "~/.cache/puppeteer"])]
        ),
        JunkRule(
            id: "editors.vscode", group: .developer,
            title: "VS Code caches",
            details: "Caches and logs of Visual Studio Code and Cursor.",
            safety: .safe,
            sources: [.paths([
                "~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData",
                "~/Library/Application Support/Code/CachedExtensionVSIXs", "~/Library/Application Support/Code/logs",
                "~/Library/Application Support/Cursor/Cache", "~/Library/Application Support/Cursor/CachedData",
                "~/Library/Application Support/Cursor/logs",
            ])],
            appBundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        ),
        JunkRule(
            id: "editors.jetbrains", group: .developer,
            title: "JetBrains caches",
            details: "Indexes and caches of IntelliJ IDEA, PyCharm, WebStorm and other JetBrains IDEs.",
            safety: .safe,
            sources: [.contents(of: "~/Library/Caches/JetBrains")]
        ),
        JunkRule(
            id: "projects.nodeModules", group: .developer,
            title: "Old node_modules",
            details: "Dependencies of JavaScript projects not changed for 30 days. Run npm install to restore them.",
            safety: .review,
            sources: [.staleNodeModules(olderThanDays: 30)]
        ),
    ]

    // MARK: - System

    static let system: [JunkRule] = [
        JunkRule(
            id: "system.userCaches", group: .system,
            title: "User caches",
            details: "Temporary data apps keep to work faster. Apps recreate what they need.",
            safety: .safe,
            sources: [.contents(of: "~/Library/Caches", excluding: [
                // Apple services that sync, download or hold state here.
                "com.apple.bird", "CloudKit", "com.apple.nsurlsessiond", "com.apple.containermanagerd",
                "com.apple.HomeKit", "com.apple.homed", "FamilyCircle", "com.apple.akd", "com.apple.ap.adprivacyd",
                "com.apple.Safari", "com.apple.WebKit.Networking", "GeoServices", "com.apple.findmy.fmipcore",
                // Accounts and Wallet: rebuilding these can ask the user to sign in again.
                "com.apple.passd", "PassKit", "com.apple.accountsd", "com.apple.appleaccountd",
                "com.apple.amsaccountsd", "com.apple.iCloudNotificationAgent",
                "com.fixerhack.MacUtil",
            ])]
        ),
        JunkRule(
            id: "system.userLogs", group: .system,
            title: "User logs",
            details: "Diagnostic logs written by apps.",
            safety: .safe,
            sources: [.contents(of: "~/Library/Logs", excluding: ["DiagnosticReports", "CrashReporter", "MacUtil"])]
        ),
        JunkRule(
            id: "system.crashReports", group: .system,
            title: "Crash reports",
            details: "Reports about apps that quit unexpectedly.",
            safety: .safe,
            sources: [
                .contents(of: "~/Library/Logs/DiagnosticReports"),
                .contents(of: "~/Library/Logs/CrashReporter"),
            ]
        ),
        JunkRule(
            id: "system.savedState", group: .system,
            title: "Saved window states",
            details: "Lets apps reopen their windows after a restart. Apps will open with new windows instead.",
            safety: .review,
            sources: [.contents(of: "~/Library/Saved Application State")]
        ),
        JunkRule(
            id: "system.brokenPreferences", group: .system,
            title: "Broken preferences",
            details: "Settings files that are damaged and can no longer be read.",
            safety: .safe,
            sources: [.brokenPreferences]
        ),
        JunkRule(
            id: "system.oldInstallers", group: .system,
            title: "Old installers",
            details: "Disk images and installer packages in Downloads older than 2 weeks.",
            safety: .review,
            sources: [.oldFiles(in: "~/Downloads", extensions: ["dmg", "pkg", "mpkg", "xip"], olderThanDays: 14)]
        ),
        JunkRule(
            id: "system.mailDownloads", group: .system,
            title: "Mail attachments",
            details: "Copies of attachments you opened in Mail. The originals stay in your mailbox.",
            safety: .review,
            sources: [.contents(of: "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads")],
            appBundleIDs: ["com.apple.mail"]
        ),
        JunkRule(
            id: "system.deviceUpdates", group: .system,
            title: "iPhone and iPad updates",
            details: "Downloaded iOS and iPadOS software updates.",
            safety: .safe,
            sources: [.paths([
                "~/Library/iTunes/iPhone Software Updates/*.ipsw", "~/Library/iTunes/iPad Software Updates/*.ipsw",
            ])]
        ),
    ]
}
