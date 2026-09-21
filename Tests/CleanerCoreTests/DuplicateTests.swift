@testable import CleanerCore
import Foundation
import Testing

struct DuplicateFinderTests {
    @Test func findsIdenticalFilesAndCountsClonesAndHardLinksRight() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mc-dup-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let content = Data((0 ..< 300_000).map { UInt8($0 % 251) })
        try content.write(to: root.appending(path: "original.bin"))
        try content.write(to: root.appending(path: "a/copy.bin"))
        // Same size and same first/last 64 KB, different middle: not a duplicate.
        var tricky = content
        tricky[150_000] ^= 0xFF
        try tricky.write(to: root.appending(path: "a/b/almost.bin"))
        // A hard link is the same file, not a duplicate.
        try fm.linkItem(at: root.appending(path: "original.bin"), to: root.appending(path: "a/b/link.bin"))
        // An APFS clone shares blocks: removing it frees nothing.
        let clone = Process()
        clone.executableURL = URL(filePath: "/bin/cp")
        clone.arguments = ["-c", root.appending(path: "a/copy.bin").path(percentEncoded: false),
                           root.appending(path: "a/b/clone.bin").path(percentEncoded: false)]
        try clone.run()
        clone.waitUntilExit()
        // Small files are ignored.
        try Data(count: 10).write(to: root.appending(path: "tiny1"))
        try Data(count: 10).write(to: root.appending(path: "tiny2"))

        let groups = try await DuplicateFinder(minimumSize: 1000).find(in: root)
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        let names = Set(group.files.map(\.name))
        #expect(names.contains("copy.bin") && names.contains("clone.bin"))
        #expect(!names.contains("almost.bin"))
        #expect(names.contains("original.bin") != names.contains("link.bin"), "only one of the hard links")
        #expect(group.files.count == 3)

        // original (private) + copy and clone sharing blocks: keeping one copy frees one file's worth.
        #expect(group.reclaimableSize >= 290_000 && group.reclaimableSize <= 320_000)
        let copy = try #require(group.files.first { $0.name == "copy.bin" })
        let cloned = try #require(group.files.first { $0.name == "clone.bin" })
        #expect(group.freedSpace(removing: [copy.path]) < 10000, "the clone still uses the blocks")
        #expect(group.freedSpace(removing: [copy.path, cloned.path]) >= 290_000)
    }

    @Test func selectionAlwaysKeepsOneCopy() {
        let old = DuplicateFile(path: "/x/old", modificationDate: Date(timeIntervalSince1970: 1), privateSize: 1)
        let new = DuplicateFile(
            path: "/long/path/new",
            modificationDate: Date(timeIntervalSince1970: 2),
            privateSize: 1
        )
        let group = DuplicateGroup(hash: "h", size: 1, files: [old, new])
        #expect(DuplicateSelection.keepOldest.filesToRemove(in: group) == [new])
        #expect(DuplicateSelection.keepNewest.filesToRemove(in: group) == [old])
        #expect(DuplicateSelection.keepShortestPath.filesToRemove(in: group) == [new])
    }
}
