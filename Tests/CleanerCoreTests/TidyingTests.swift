@testable import CleanerCore
import Foundation
import Testing

/// A folder that cleans itself up when the test ends.
private struct Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "mc-tidy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path(percentEncoded: false) }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: relativePath), withIntermediateDirectories: true
        )
    }

    @discardableResult
    func write(_ relativePath: String, bytes: Int = 2048) throws -> String {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 3, count: bytes).write(to: file)
        return file.path(percentEncoded: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct InstallerFilesTests {
    @Test func matchesAnInstallerToTheAppItDelivered() {
        let apps = [(key: "slack", name: "Slack"), (key: "visualstudiocode", name: "Visual Studio Code")]
        #expect(InstallerFiles.match("Slack-4.35.126-macOS", against: apps) == "Slack")
        #expect(InstallerFiles.match("VisualStudioCode-darwin-arm64", against: apps) == "Visual Studio Code")
    }

    @Test func leavesInstallersWithNoMatchingAppAlone() {
        let apps = [(key: "slack", name: "Slack")]
        #expect(InstallerFiles.match("SomeDriver", against: apps) == nil)
        // Too short to mean anything on its own.
        #expect(InstallerFiles.match("S", against: apps) == nil)
    }

    @Test func findsOnlyInstallerWrappers() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("Downloads/Thing-1.0.dmg")
        try scratch.write("Downloads/notes.zip")
        try scratch.write("Downloads/photo.png")

        let found = await InstallerFiles.scan(home: scratch.url, apps: [], protected: ProtectedPaths())
        #expect(found.map(\.name) == ["Thing-1.0.dmg"])
        #expect(found.first?.isSpent == false)
    }

    @Test func leavesOutWhatThePersonProtected() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let installer = try scratch.write("Downloads/Thing-1.0.dmg")

        let protected = ProtectedPaths(paths: [installer])
        let found = await InstallerFiles.scan(home: scratch.url, apps: [], protected: protected)
        #expect(found.isEmpty)
    }
}

@Suite struct ProjectBuildsTests {
    @Test func needsTheFileThatProvesABuildToolOwnsTheFolder() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A real project: package.json beside node_modules.
        try scratch.write("app/package.json")
        try scratch.write("app/node_modules/left-pad/index.js")
        // No package.json here, so "dist" is somebody's own folder.
        try scratch.write("writing/dist/chapter.txt")

        let found = await ProjectBuilds.scan(roots: [scratch.path], protected: ProtectedPaths())
        #expect(found.map(\.kind) == ["node_modules"])
        #expect(found.first?.project == "app")
        #expect(found.first?.isSafe == true)
    }

    @Test func doesNotDescendIntoWhatItAlreadyFound() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.write("app/package.json")
        // A nested project inside node_modules must not be reported separately.
        try scratch.write("app/node_modules/thing/package.json")
        try scratch.write("app/node_modules/thing/node_modules/deep/index.js")

        let found = await ProjectBuilds.scan(roots: [scratch.path], protected: ProtectedPaths())
        #expect(found.count == 1)
    }

    @Test func generousNamesAreNeverPreselected() {
        let generic = ProjectBuilds.kinds.filter { ["build", "dist"].contains($0.directory) }
        #expect(generic.count == 2)
        #expect(generic.allSatisfy { !$0.isSafe })
    }
}

@Suite struct AppSlimmingTests {
    /// Builds a universal-binary header: magic, count, then one entry per architecture.
    private func fatHeader(_ architectures: [(cpuType: UInt32, size: UInt32)]) -> Data {
        var data = Data()
        func append(_ value: UInt32) {
            data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) })
        }
        append(0xCAFE_BABE)
        append(UInt32(architectures.count))
        for architecture in architectures {
            append(architecture.cpuType)
            append(0) // cpusubtype
            append(4096) // offset
            append(architecture.size)
            append(14) // align
        }
        return data
    }

    @Test func readsEveryArchitectureAndItsSize() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let path = scratch.url.appending(path: "binary").path(percentEncoded: false)
        try fatHeader([
            (AppSlimming.x86_64, 4_000_000), (AppSlimming.arm64, 3_000_000),
        ]).write(to: URL(filePath: path))

        let slices = try #require(AppSlimming.architectures(of: path))
        #expect(slices.count == 2)
        #expect(slices[0].cpuType == AppSlimming.x86_64)
        #expect(slices[0].size == 4_000_000)
        #expect(slices[1].size == 3_000_000)
    }

    @Test func ignoresAJavaClassFileWithTheSameFirstFourBytes() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let path = scratch.url.appending(path: "Thing.class").path(percentEncoded: false)
        // CAFEBABE, then minor and major version — far too many "architectures" to be real.
        try Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x41]).write(to: URL(filePath: path))

        #expect(AppSlimming.architectures(of: path) == nil)
    }

    @Test func passesOverFilesThatAreNotBinaries() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let path = try scratch.write("notes.txt")
        #expect(AppSlimming.architectures(of: path) == nil)
    }

    @Test func refusesAnAppItCannotWriteTo() async throws {
        let app = SlimmableApp(
            path: "/System/Applications/Chess.app", name: "Chess", version: nil,
            size: 1000, savings: 500, binaryCount: 1, isAppStore: false, isWritable: false
        )
        let result = await AppSlimming.slim(app)
        #expect(result == .failure(.notWritable))
    }
}

@Suite struct ProtectedPathsTests {
    @Test func coversThePathItselfAndWhatIsInside() {
        let protected = ProtectedPaths(paths: ["/tmp/keep"])
        #expect(protected.covers("/tmp/keep"))
        #expect(protected.covers("/tmp/keep/inside/file"))
        #expect(!protected.covers("/tmp/keepsake"))
        #expect(!protected.covers("/tmp/other"))
    }

    @Test func emptyListProtectsNothing() {
        #expect(!ProtectedPaths().covers("/tmp/anything"))
    }

    @Test func addingTheSamePlaceTwiceChangesNothing() {
        let once = ProtectedPaths().adding("/tmp/keep")
        #expect(once.adding("/tmp/keep").paths == once.paths)
        #expect(once.removing("/tmp/keep").isEmpty)
    }

    @Test func theGuardRefusesAProtectedPath() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.makeDirectory("Library/Caches/keep-me")
        let kept = scratch.url.appending(path: "Library/Caches/keep-me").path(percentEncoded: false)

        let guarded = SafetyGuard(home: scratch.url, protected: ProtectedPaths(paths: [kept]))
        #expect(guarded.check(kept) == .blocked("on your protected list"))

        let open = SafetyGuard(home: scratch.url, protected: ProtectedPaths())
        #expect(open.check(kept) == .allowed)
    }
}

@Suite struct SudoTouchIDTests {
    @Test func seesTheModuleOnlyWhenTheLineIsLive() {
        #expect(SudoTouchID.contains(pamTouchID: "auth       sufficient     pam_tid.so"))
        #expect(!SudoTouchID.contains(pamTouchID: "# auth       sufficient     pam_tid.so"))
        #expect(!SudoTouchID.contains(pamTouchID: "auth sufficient pam_smartcard.so"))
        #expect(!SudoTouchID.contains(pamTouchID: ""))
    }
}

@Suite struct HistoryTests {
    @Test func keepsWhatWasRemovedAndForgetsItOnRequest() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let log = ActionLog(url: scratch.url.appending(path: "History.jsonl"))

        var result = CleanupResult(mode: .trash)
        result.removed = [RemovedItem(path: "/tmp/a", size: 100, trashPath: "/tmp/.Trash/a")]
        log.record(ActionLog.Entry(action: "trash", source: "junk.system", result: result))

        let entries = log.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.freedBytes == 100)
        #expect(entries.first?.source == "junk.system")

        log.clear()
        #expect(log.entries().isEmpty)
    }

    @Test func recordsNothingWhenNothingHappened() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let log = ActionLog(url: scratch.url.appending(path: "History.jsonl"))
        log.record(ActionLog.Entry(action: "trash", source: "junk.system", result: CleanupResult(mode: .trash)))
        #expect(log.entries().isEmpty)
    }
}
