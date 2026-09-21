@testable import CleanerCore
import Foundation
import Testing

struct DeepSearchTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mc-search-\(UUID().uuidString)")
        let files: [String: String] = [
            "notes/Todo.txt": "buy milk\nfix the Mac",
            "notes/Résumé.md": "experience",
            "logs/app-2026.log": "ERROR disk full",
            "logs/app-2025.log": "all good",
            "photos/IMG_0001.JPG": "jpeg",
            ".hidden/secret.txt": "fix the Mac",
            "big.bin": String(repeating: "x", count: 50000),
        ]
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func names(_ query: SearchQuery, in root: URL) async throws -> Set<String> {
        var query = query
        query.mode = .deep
        return try await Set(DeepSearch().run(query, in: root).map(\.name))
    }

    @Test func matchesNames() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        var query = SearchQuery()
        query.text = "resume" // ignores case and accents
        #expect(try await names(query, in: root) == ["Résumé.md"])

        query.text = "app-*.log"
        query.matching = .wildcard
        #expect(try await names(query, in: root) == ["app-2026.log", "app-2025.log"])

        query.text = #"^IMG_\d{4}"#
        query.matching = .regex
        #expect(try await names(query, in: root) == ["IMG_0001.JPG"])

        query.text = "notes"
        query.matching = .contains
        #expect(try await names(query, in: root) == ["notes"], "folders match too")
    }

    @Test func filtersAndHiddenFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        var query = SearchQuery()
        query.minimumSize = 10000
        query.includeFolders = false
        #expect(try await names(query, in: root) == ["big.bin"])

        query = SearchQuery()
        query.kind = .image
        #expect(try await names(query, in: root) == ["IMG_0001.JPG"])

        query = SearchQuery()
        query.text = "secret"
        #expect(try await names(query, in: root).isEmpty)
        query.includeHidden = true
        #expect(try await names(query, in: root) == ["secret.txt"])
    }

    @Test func searchesContents() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        var query = SearchQuery()
        query.text = "fix the mac"
        query.searchContents = true
        #expect(try await names(query, in: root) == ["Todo.txt"])

        query.text = #"ERROR\s+disk"#
        query.matching = .regex
        #expect(try await names(query, in: root) == ["app-2026.log"])
    }

    @Test func rejectsBadRegex() async throws {
        var query = SearchQuery()
        query.text = "(unclosed"
        query.matching = .regex
        await #expect(throws: SearchError.self) {
            try await DeepSearch().run(query, in: FileManager.default.temporaryDirectory)
        }
    }

    @Test func buildsSpotlightQueries() {
        var query = SearchQuery()
        query.text = #"say "hi""#
        #expect(DeepSearch.spotlightQuery(query) == #"kMDItemFSName == "*say \"hi\"*"cd"#)

        query = SearchQuery()
        query.text = "*.pdf"
        query.matching = .wildcard
        query.minimumSize = 1000
        query.modifiedWithinDays = 7
        #expect(DeepSearch.spotlightQuery(query)
            == #"kMDItemFSName == "*.pdf"cd && kMDItemFSSize >= 1000 && kMDItemFSContentChangeDate >= $time.today(-7)"#)

        query = SearchQuery()
        query.text = "invoice"
        query.searchContents = true
        #expect(DeepSearch.spotlightQuery(query) == #"kMDItemTextContent == "*invoice*"cd"#)
    }
}
