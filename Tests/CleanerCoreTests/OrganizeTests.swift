@testable import CleanerCore
import Foundation
import Testing

/// A folder with files in it, cleaned up when the test ends.
private struct Folder {
    let url: URL

    init(_ names: [String]) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "mc-org-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            try Data(repeating: 1, count: 1024).write(to: url.appending(path: name))
        }
    }

    var path: String { url.path(percentEncoded: false) }

    func makeFolder(_ name: String, containing files: [String] = []) throws {
        let directory = url.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data(repeating: 1, count: 512).write(to: directory.appending(path: file))
        }
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: relativePath).path(percentEncoded: false))
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct OrganizeRulesTests {
    @Test func sendsFilesToTheFolderTheirExtensionNames() throws {
        let folder = try Folder(["holiday.jpg", "notes.pdf", "song.mp3"])
        defer { folder.remove() }

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [
            ExtensionRule(extensions: "jpg, png", destination: "Images"),
            ExtensionRule(extensions: "pdf", destination: "Documents"),
        ]

        let plan = FolderOrganizer.plan(watched)
        let byName = Dictionary(uniqueKeysWithValues: plan.map { ($0.name, $0.folder) })
        #expect(byName == ["holiday.jpg": "Images", "notes.pdf": "Documents"])
        // Nothing claims the mp3, so it stays where it is.
        #expect(!plan.contains { $0.name == "song.mp3" })
    }

    @Test func aNameRuleWinsOverAnExtensionRule() throws {
        let folder = try Folder(["Invoice-2026.pdf", "manual.pdf"])
        defer { folder.remove() }

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "pdf", destination: "Documents")]
        watched.nameRules = [NameRule(pattern: "Invoice*", destination: "Invoices")]

        let plan = FolderOrganizer.plan(watched)
        let byName = Dictionary(uniqueKeysWithValues: plan.map { ($0.name, $0.folder) })
        #expect(byName == ["Invoice-2026.pdf": "Invoices", "manual.pdf": "Documents"])
    }

    @Test func patternsIgnoreCaseAndHonourExceptions() {
        let rule = NameRule(pattern: "*screenshot*", destination: "Shots", exceptions: ["*keep*"])
        #expect(rule.matches(name: "Screenshot 2026.png"))
        #expect(rule.matches(name: "my-SCREENSHOT.png"))
        #expect(!rule.matches(name: "keep-screenshot.png"))
        #expect(!rule.matches(name: "photo.png"))
    }

    @Test func neverSortsTheFoldersTheRulesFill() throws {
        let folder = try Folder(["a.jpg"])
        defer { folder.remove() }
        try folder.makeFolder("Images", containing: ["already-filed.jpg"])

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "jpg", destination: "Images")]

        let plan = FolderOrganizer.plan(watched)
        #expect(plan.map(\.name) == ["a.jpg"])
    }

    @Test func leavesOrdinaryFoldersAlone() throws {
        let folder = try Folder([])
        defer { folder.remove() }
        try folder.makeFolder("my project", containing: ["notes.pdf"])

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "pdf", destination: "Documents")]

        #expect(FolderOrganizer.plan(watched).isEmpty)
    }

    @Test func givesANewNameRatherThanOverwriting() throws {
        let folder = try Folder(["report.pdf"])
        defer { folder.remove() }
        try folder.makeFolder("Documents", containing: ["report.pdf"])

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "pdf", destination: "Documents")]

        let move = try #require(FolderOrganizer.plan(watched).first)
        #expect(move.wasRenamed)
        #expect(move.newName == "report 2.pdf")
    }

    @Test func twoFilesNeverAimAtTheSameName() throws {
        let folder = try Folder([])
        defer { folder.remove() }
        // Both match, and both would be called "shot.png" in Images.
        try folder.makeFolder("one", containing: [])
        try Data(repeating: 1, count: 16).write(to: folder.url.appending(path: "shot.png"))
        try folder.makeFolder("Images", containing: ["shot.png"])

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "png", destination: "Images")]

        let plan = FolderOrganizer.plan(watched)
        #expect(Set(plan.map(\.destination)).count == plan.count)
    }

    @Test func aDisabledRuleDoesNothing() throws {
        let folder = try Folder(["a.jpg"])
        defer { folder.remove() }

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [ExtensionRule(extensions: "jpg", destination: "Images", isEnabled: false)]
        #expect(FolderOrganizer.plan(watched).isEmpty)
    }

    @Test func filesTheFilesAndPutsThemBackAgain() async throws {
        let folder = try Folder(["holiday.jpg", "notes.pdf"])
        defer { folder.remove() }

        var watched = WatchedFolder(path: folder.path)
        watched.extensionRules = [
            ExtensionRule(extensions: "jpg", destination: "Images"),
            ExtensionRule(extensions: "pdf", destination: "Documents"),
        ]

        let result = await FolderOrganizer.apply(FolderOrganizer.plan(watched))
        #expect(result.moved.count == 2)
        #expect(result.failures.isEmpty)
        #expect(folder.exists("Images/holiday.jpg"))
        #expect(folder.exists("Documents/notes.pdf"))
        #expect(!folder.exists("holiday.jpg"))

        let back = await FolderOrganizer.undo(result)
        #expect(back.moved.count == 2)
        #expect(folder.exists("holiday.jpg"))
        #expect(folder.exists("notes.pdf"))
    }

    @Test func keepsFoldersAndRulesBetweenLaunches() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "mc-store-\(UUID().uuidString)")
        let file = directory.appending(path: "Folders.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var watched = WatchedFolder(path: "/tmp/whatever")
        watched.nameRules = [NameRule(pattern: "Invoice*", destination: "Invoices")]
        watched.organizesAutomatically = true
        OrganizeStore.save([watched], to: file)

        let loaded = try #require(OrganizeStore.load(from: file).first)
        #expect(loaded.path == "/tmp/whatever")
        #expect(loaded.organizesAutomatically)
        #expect(loaded.nameRules.first?.pattern == "Invoice*")
    }

    @Test func theReadyMadeRulesCoverTheUsualPileUp() {
        let destinations = Set(FolderOrganizer.presets.map(\.destination))
        #expect(destinations.contains("Images"))
        #expect(destinations.contains("Installers"))
        #expect(destinations.contains("Archives"))
        // No extension may be claimed by two rules, or the result would depend on order.
        let all = FolderOrganizer.presets.flatMap(\.list)
        #expect(all.count == Set(all).count)
    }
}
