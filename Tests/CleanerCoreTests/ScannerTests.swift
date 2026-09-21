@testable import CleanerCore
import CoreGraphics
import Foundation
import Testing

/// A throwaway folder tree with known contents.
private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mc-scan-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "a/b"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: root.appending(path: "a/big.bin"))
        try Data(count: 10000).write(to: root.appending(path: "a/b/small.txt"))
        try Data(count: 50000).write(to: root.appending(path: "top.zip"))
        try fm.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "hardlink.bin"))
        try fm.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "a"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func allocated(_ relativePath: String) throws -> Int64 {
        let values = try root.appending(path: relativePath).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}

struct DiskScannerTests {
    @Test func buildsTreeWithAggregatedSizes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await DiskScanner().scan(fixture.root)
        let root = result.root

        // big.bin + small.txt + top.zip + the symlink; the hard link is counted once.
        let expected = try fixture.allocated("a/big.bin") + fixture.allocated("a/b/small.txt")
            + fixture.allocated("top.zip")
        #expect(root.allocatedSize >= expected)
        #expect(root.allocatedSize < expected + 16384) // at most the symlink's block
        #expect(root.fileCount == 5)
        #expect(result.directoryCount == 4)

        let a = try #require(root.directories.first { $0.name == "a" })
        #expect(a.fileCount == 2)
        #expect(a.parent === root)
        #expect(a.directories.first?.name == "b")
        #expect(root.directories.first?.name == "a", "children are sorted by size")

        let hardLinked = root.files.filter { $0.name == "hardlink.bin" } + a.files.filter { $0.name == "big.bin" }
        #expect(hardLinked.count == 2)
        #expect(hardLinked.filter { $0.allocatedSize > 0 }.count == 1)

        let link = try #require(root.files.first { $0.name == "link" })
        #expect(link.type == .symlink, "symlinks are not followed")
    }

    @Test func listsFilesWithFullPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = try await DiskScanner().scan(fixture.root)

        let zips = result.root.files { $0.kind == .archive }
        #expect(zips.count == 1)
        #expect(zips.first?.path.hasSuffix("/top.zip") == true)

        let small = try #require(result.root.files { $0.name == "small.txt" }.first)
        let b = try #require(result.root.directories.first { $0.name == "a" }?.directories.first)
        #expect(small.path == b.path(of: small.entry))
        #expect(b.lineage.map(\.name) == [result.root.name, "a", "b"])
    }

    @Test func excludedPathsAreSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var options = ScanOptions()
        let aPath = fixture.root.appending(path: "a").standardizedFileURL.path(percentEncoded: false)
        options.excludedPaths = [aPath.hasSuffix("/") ? String(aPath.dropLast()) : aPath]

        let result = try await DiskScanner(options: options).scan(fixture.root)
        let a = try #require(result.root.directories.first { $0.name == "a" })
        #expect(a.status == .excluded)
        #expect(a.fileCount == 0)
    }

    @Test func rejectsFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: ScanError.self) {
            try await DiskScanner().scan(fixture.root.appending(path: "top.zip"))
        }
    }

    @Test func cancelledScanThrows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let scanner = DiskScanner()
        scanner.cancel()
        await #expect(throws: CancellationError.self) {
            try await scanner.scan(fixture.root)
        }
    }
}

struct FileKindTests {
    @Test func classifiesByExtension() {
        #expect(FileKind(fileName: "Movie.MOV") == .video)
        #expect(FileKind(fileName: "backup.tar.gz") == .archive)
        #expect(FileKind(fileName: "Installer.dmg") == .diskImage)
        #expect(FileKind(fileName: "README") == .other)
    }
}

struct TreemapTests {
    @Test func areasAreProportionalAndInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.squarify(values, in: bounds)
        let total = values.reduce(0, +)

        #expect(rects.count == values.count)
        for (value, rect) in zip(values, rects) {
            let expectedArea = value / total * 600 * 400
            #expect(abs(Double(rect.width * rect.height) - expectedArea) < 0.5)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func handlesEmptyInput() {
        #expect(Treemap.squarify([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(Treemap.squarify([0, 0], in: CGRect(x: 0, y: 0, width: 10, height: 10)) == [.zero, .zero])
    }
}
