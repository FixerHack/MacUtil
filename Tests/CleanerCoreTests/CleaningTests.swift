@testable import CleanerCore
import Foundation
import Testing

/// A fake home folder with junk in the usual places.
private struct FakeHome {
    let url: URL
    var path: String { SafetyGuard.resolve(url.path(percentEncoded: false)) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "mc-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, bytes: Int = 5000, modified: Date? = nil) throws {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: file)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: file.path(percentEncoded: false)
            )
        }
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relativePath).path(percentEncoded: false))
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Moves "trashed" items into a folder instead of the real Trash.
private struct FolderTrash: TrashDestination {
    let folder: URL

    func trash(_ url: URL) throws -> URL? {
        let destination = folder.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

struct SafetyGuardTests {
    let safety = SafetyGuard(home: URL(filePath: "/Users/tester"))

    @Test func allowsItemsInsideHome() {
        #expect(safety.check("/Users/tester/Library/Caches/com.example.app") == .allowed)
        #expect(safety.check("/Users/tester/Downloads/old.dmg") == .allowed)
    }

    @Test func blocksStandardFoldersThemselves() {
        for path in [
            "/Users/tester",
            "/Users/tester/Library",
            "/Users/tester/Library/Caches",
            "/Users/tester/Documents",
            "/Users/tester/.Trash",
        ] {
            #expect(safety.check(path) != .allowed, "\(path)")
        }
    }

    @Test func blocksProtectedData() {
        for path in [
            "/Users/tester/Library/Keychains/login.keychain-db",
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/file.txt",
            "/Users/tester/Library/Mail/V10/INBOX.mbox",
            "/Users/tester/.ssh/id_ed25519",
            "/Users/tester/Pictures/Photos Library.photoslibrary/database",
            "/Users/tester/Desktop/project/.git/objects/ab",
        ] {
            #expect(safety.check(path) != .allowed, "\(path)")
        }
    }

    @Test func blocksPathsOutsideHome() {
        for path in [
            "/",
            "/System/Library/Caches",
            "/usr/local/bin/tool",
            "/Applications/Safari.app",
            "/Users/other/file",
            "relative/path",
        ] {
            #expect(safety.check(path) != .allowed, "\(path)")
        }
    }

    @Test func uninstallerRootAllowsAppsButNotTheFolder() {
        let safety = SafetyGuard(home: URL(filePath: "/Users/tester"), extraAllowedRoots: ["/Applications"])
        #expect(safety.check("/Applications/Some App.app") == .allowed)
        #expect(safety.check("/Applications") != .allowed)
        #expect(safety.check("/Applications/Utilities") != .allowed)
    }

    @Test func blocksDotDotTricks() {
        #expect(safety.check("/Users/tester/Library/Caches/../../../../System") != .allowed)
        #expect(safety.check("/Users/tester/./Library") != .allowed)
    }

    @Test func blocksSymlinkedParentsPointingOutside() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let link = home.url.appending(path: "Library/Caches/sneaky")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(filePath: "/System/Library"))

        let safety = SafetyGuard(home: home.url)
        #expect(safety.check(link.path(percentEncoded: false) + "/Caches") != .allowed)
        // The link itself may go: trashing it does not touch the target.
        #expect(safety.check(link.path(percentEncoded: false)) == .allowed)
    }
}

struct CleanerTests {
    @Test func trashesUndoesAndLogs() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.write("Library/Caches/com.example/a.bin")
        try home.write("Library/Caches/loose.tmp")
        let log = ActionLog(url: home.url.appending(path: "history.jsonl"))
        let cleaner = Cleaner(
            safety: SafetyGuard(home: home.url),
            trash: FolderTrash(folder: home.url.appending(path: "FakeTrash")),
            log: log
        )
        let targets = [
            CleanupTarget(path: home.path + "/Library/Caches/com.example", size: 5000),
            CleanupTarget(path: home.path + "/Library/Caches/loose.tmp", size: 5000),
            CleanupTarget(path: home.path + "/Library/Caches", size: 1), // blocked: standard folder
        ]

        let result = await cleaner.clean(targets, mode: .trash, source: "test")
        #expect(result.removed.count == 2)
        #expect(result.failures.count == 1)
        #expect(result.freedBytes == 10000)
        #expect(result.canUndo)
        #expect(!home.exists("Library/Caches/com.example"))
        #expect(home.exists("Library/Caches"))

        let restored = await cleaner.undo(result)
        #expect(restored.removed.count == 2)
        #expect(home.exists("Library/Caches/com.example/a.bin"))
        #expect(home.exists("Library/Caches/loose.tmp"))

        let entries = log.entries()
        #expect(entries.map(\.action) == ["trash", "restore"])
        #expect(entries.first?.freedBytes == 10000)
    }

    @Test func deletesPermanently() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.write("Library/Logs/app.log")
        let cleaner = Cleaner(safety: SafetyGuard(home: home.url), trash: FolderTrash(folder: home.url), log: nil)

        let result = await cleaner.clean(
            [CleanupTarget(path: home.path + "/Library/Logs/app.log", size: 5000)], mode: .delete, source: "test"
        )
        #expect(result.removed.count == 1)
        #expect(!result.canUndo)
        #expect(!home.exists("Library/Logs/app.log"))
    }

    @Test func nestedTargetsAreRemovedOnce() {
        let targets = [
            CleanupTarget(path: "/h/a", size: 10),
            CleanupTarget(path: "/h/a/b", size: 5),
            CleanupTarget(path: "/h/ab", size: 1),
            CleanupTarget(path: "/h/a-x", size: 1), // sorts between "/h/a" and "/h/a/b"
            CleanupTarget(path: "/h/a/c/d", size: 1),
        ]
        #expect(Cleaner.removingNested(targets).map(\.path) == ["/h/a", "/h/a-x", "/h/ab"])
    }
}

struct JunkScannerTests {
    @Test func findsJunkAndRespectsExclusionsAndRunningApps() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.write("Library/Caches/com.example.app/data.bin", bytes: 20000)
        try home.write("Library/Caches/com.running.app/data.bin")
        try home.write("Library/Caches/CloudKit/state.db") // excluded
        try home.write("Library/Caches/Homebrew/bottle.tar.gz") // claimed by the Homebrew rule
        try home.write("Library/Logs/app.log")
        try home.write("Library/Preferences/com.broken.plist", bytes: 100) // 100 bytes of 0x07: not a plist
        try home.write("Downloads/old.dmg", modified: Date().addingTimeInterval(-30 * 86400))
        try home.write("Downloads/new.dmg")
        try home.write("Desktop/oldproject/package.json", modified: Date().addingTimeInterval(-60 * 86400))
        try home.write("Desktop/oldproject/node_modules/lib/index.js")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60 * 86400)],
            ofItemAtPath: home.url.appending(path: "Desktop/oldproject").path(percentEncoded: false)
        )

        let context = JunkContext(home: home.url, runningBundleIDs: ["com.running.app"])
        let categories = await JunkScanner.scan(JunkCatalog.all, context: context)
        let byRule = Dictionary(uniqueKeysWithValues: categories.map { ($0.rule.id, $0) })

        let caches = try #require(byRule["system.userCaches"])
        let cacheNames = Set(caches.items.map(\.name))
        #expect(cacheNames == ["com.example.app", "com.running.app"])
        #expect(caches.items.first { $0.name == "com.running.app" }?.inUseBy == "com.running.app")
        #expect(caches.removableSize < caches.size)

        #expect(byRule["packages.homebrew"]?.items.map(\.name) == ["Homebrew"])
        #expect(byRule["system.userLogs"]?.items.map(\.name) == ["app.log"])
        #expect(byRule["system.brokenPreferences"]?.items.map(\.name) == ["com.broken.plist"])
        #expect(byRule["system.oldInstallers"]?.items.map(\.name) == ["old.dmg"])
        #expect(byRule["projects.nodeModules"]?.items.map(\.path) == [home.path + "/Desktop/oldproject/node_modules"])
        #expect(byRule["xcode.derivedData"] == nil, "empty categories are dropped")

        // Everything found must pass the safety check.
        let safety = SafetyGuard(home: home.url)
        for item in categories.flatMap(\.items) {
            #expect(safety.check(item.path) == .allowed, "\(item.path)")
        }
    }

    @Test func expandsHomeAndGlobs() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.write("updates/a.ipsw")
        try home.write("updates/b.ipsw")
        try home.write("updates/c.txt")
        #expect(JunkScanner.expand("~/x", home: "/Users/t") == "/Users/t/x")
        #expect(JunkScanner.glob(home.path + "/updates/*.ipsw").count == 2)
    }
}
