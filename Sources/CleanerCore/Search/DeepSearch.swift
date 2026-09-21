import Foundation
import Synchronization

public struct SearchQuery: Sendable, Hashable {
    public enum Matching: String, Sendable, CaseIterable {
        /// The name contains the text, ignoring case and accents.
        case contains
        /// Shell-style pattern for the whole name: `*.log`, `IMG_????.JPG`.
        case wildcard
        /// Regular expression anywhere in the name.
        case regex
    }

    public enum Mode: String, Sendable, CaseIterable {
        /// Spotlight's index: instant, but skips ~/Library, hidden and system files.
        case spotlight
        /// Walks the folder itself: slower, finds everything.
        case deep
    }

    public var text = ""
    public var matching = Matching.contains
    public var mode = Mode.spotlight
    /// Look for the text inside files instead of in their names.
    public var searchContents = false
    public var kind: FileKind?
    public var minimumSize: Int64 = 0
    public var modifiedWithinDays: Int?
    public var includeHidden = false
    public var includeFolders = true

    public init() {}
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public let path: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
    public var kind: FileKind { FileKind(fileName: name) }
}

public enum SearchError: LocalizedError {
    case invalidPattern(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPattern(message): String(localized: "The pattern is not valid: \(message)")
        }
    }
}

public struct SearchProgress: Sendable, Equatable {
    public var examined = 0
    public var found = 0

    public init() {}
}

/// Finds files by name, contents, kind, size and date, either through Spotlight
/// or by walking the folder with `DiskScanner`.
public final class DeepSearch: Sendable {
    public static let resultLimit = 5000
    /// Larger files are skipped when searching contents.
    public static let contentSizeLimit: Int64 = 20_000_000

    private let scanner = DiskScanner()
    private let state = Mutex(SearchProgress())

    public init() {}

    public var progress: SearchProgress {
        var progress = state.withLock { $0 }
        progress.examined = max(progress.examined, scanner.progress.files)
        return progress
    }

    public func cancel() {
        scanner.cancel()
    }

    public func run(_ query: SearchQuery, in root: URL) async throws -> [SearchHit] {
        let matcher = try Matcher(query)
        let hits: [SearchHit] = switch query.mode {
        case .spotlight where query.matching != .regex:
            try await spotlight(query, root: root, matcher: matcher)
        case .spotlight, .deep:
            try await walk(query, root: root, matcher: matcher)
        }
        return hits.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Walking

    private func walk(_ query: SearchQuery, root: URL, matcher: Matcher) async throws -> [SearchHit] {
        let tree = try await scanner.scan(root).root
        let cutoff = query.modifiedWithinDays.map { Int64(Date().timeIntervalSince1970) - Int64($0) * 86400 }

        var hits: [SearchHit] = []
        var contentCandidates: [SearchHit] = []
        var stack = [tree]
        walking: while let node = stack.popLast() {
            for directory in node.directories where query.includeHidden || !directory.name.hasPrefix(".") {
                stack.append(directory)
                if query.includeFolders, !query.searchContents, query.kind == nil,
                   directory.allocatedSize >= query.minimumSize,
                   cutoff.map({ directory.modificationTime >= $0 }) ?? true,
                   matcher.matchesName(directory.name)
                {
                    hits.append(SearchHit(
                        path: directory.path, isDirectory: true, size: directory.allocatedSize,
                        modificationDate: Date(timeIntervalSince1970: TimeInterval(directory.modificationTime))
                    ))
                }
            }
            for file in node.files {
                guard query.includeHidden || !file.isHidden,
                      !file.isDataless,
                      file.logicalSize >= query.minimumSize,
                      cutoff.map({ file.modificationTime >= $0 }) ?? true,
                      query.kind.map({ file.kind == $0 }) ?? true
                else { continue }
                let hit = SearchHit(
                    path: node.path(of: file), isDirectory: false, size: file.logicalSize,
                    modificationDate: file.modificationDate
                )
                if query.searchContents {
                    if file.type == .regular, file.logicalSize <= Self.contentSizeLimit {
                        contentCandidates.append(hit)
                    }
                } else if matcher.matchesName(file.name) {
                    hits.append(hit)
                    if hits.count >= Self.resultLimit {
                        break walking
                    }
                }
            }
        }
        if query.searchContents {
            hits = try await searchContents(of: contentCandidates, matcher: matcher)
        }
        state.withLock { $0.found = hits.count }
        return hits
    }

    private func searchContents(of candidates: [SearchHit], matcher: Matcher) async throws -> [SearchHit] {
        let found = Mutex([SearchHit]())
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = candidates.makeIterator()
            func addNext() -> Bool {
                guard let candidate = iterator.next() else { return false }
                group.addTask {
                    if self.scanner.isCancelled {
                        throw CancellationError()
                    }
                    let matches = matcher.matchesContents(ofFile: candidate.path)
                    self.state.withLock { $0.examined += 1 }
                    if matches {
                        found.withLock { $0.append(candidate) }
                    }
                }
                return true
            }
            for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount where addNext() {}
            while try await group.next() != nil {
                if found.withLock({ $0.count }) >= Self.resultLimit {
                    break
                }
                _ = addNext()
            }
            group.cancelAll()
        }
        return Array(found.withLock { $0 }.prefix(Self.resultLimit))
    }

    // MARK: - Spotlight

    private func spotlight(_ query: SearchQuery, root: URL, matcher: Matcher) async throws -> [SearchHit] {
        let output = await Command.run(
            "/usr/bin/mdfind",
            ["-onlyin", root.path(percentEncoded: false), Self.spotlightQuery(query)],
            timeout: .seconds(60)
        )
        if scanner.isCancelled {
            throw CancellationError()
        }
        let cutoff = query.modifiedWithinDays.map { Date().addingTimeInterval(-Double($0) * 86400) }

        var hits: [SearchHit] = []
        for path in (output?.text ?? "").split(separator: "\n").map(String.init) {
            let name = (path as NSString).lastPathComponent
            guard query.includeHidden || !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
            else { continue }
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR
            let hit = SearchHit(
                path: path, isDirectory: isDirectory, size: Int64(info.st_size),
                modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            )
            state.withLock { $0.examined += 1 }
            guard isDirectory ? query.includeFolders : true,
                  hit.size >= query.minimumSize,
                  cutoff.map({ hit.modificationDate >= $0 }) ?? true,
                  query.kind.map({ !isDirectory && FileKind(fileName: name) == $0 }) ?? true,
                  query.searchContents || matcher.matchesName(name)
            else { continue }
            hits.append(hit)
            if hits.count >= Self.resultLimit {
                break
            }
        }
        state.withLock { $0.found = hits.count }
        return hits
    }

    /// A Spotlight query in mdfind's syntax. `c` ignores case, `d` ignores accents.
    static func spotlightQuery(_ query: SearchQuery) -> String {
        let text = query.text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var conditions: [String] = []
        if !text.isEmpty {
            let attribute = query.searchContents ? "kMDItemTextContent" : "kMDItemFSName"
            let pattern = query.matching == .wildcard && !query.searchContents ? text : "*\(text)*"
            conditions.append("\(attribute) == \"\(pattern)\"cd")
        }
        if query.minimumSize > 0 {
            conditions.append("kMDItemFSSize >= \(query.minimumSize)")
        }
        if let days = query.modifiedWithinDays {
            conditions.append("kMDItemFSContentChangeDate >= $time.today(-\(days))")
        }
        return conditions.isEmpty ? "kMDItemFSName == \"*\"" : conditions.joined(separator: " && ")
    }
}

/// Compiled name and contents matching for one query.
struct Matcher: Sendable {
    private let text: String
    private let regex: NSRegularExpression?

    init(_ query: SearchQuery) throws {
        text = query.text
        switch query.matching {
        case .contains:
            regex = nil
        case .wildcard where query.searchContents:
            // Wildcards describe names; inside files the text is looked up as is.
            regex = nil
        case .wildcard:
            let escaped = NSRegularExpression.escapedPattern(for: query.text)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            regex = try NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive])
        case .regex:
            do {
                regex = try NSRegularExpression(pattern: query.text, options: [.caseInsensitive])
            } catch {
                throw SearchError.invalidPattern(query.text)
            }
        }
    }

    func matchesName(_ name: String) -> Bool {
        matches(name)
    }

    func matchesContents(ofFile path: String) -> Bool {
        guard !text.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return false }
        // Binary files contain NUL bytes near the start; text files do not.
        if data.prefix(4096).contains(0) {
            return false
        }
        return matches(String(decoding: data, as: UTF8.self))
    }

    private func matches(_ string: String) -> Bool {
        if text.isEmpty {
            return true
        }
        if let regex {
            return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
        }
        return string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
