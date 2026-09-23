import CleanerCore
import Foundation

/// A finding the person has settled: VirusTotal found nothing, or they said they trust it.
public struct SecurityDecision: Codable, Sendable, Hashable, Identifiable {
    public enum Reason: String, Codable, Sendable {
        /// VirusTotal checked the file and no engine flagged it.
        case virusTotalClean
        /// The person said they know this one and trust it.
        case trusted
    }

    public let issueID: String
    public let reason: Reason
    public let date: Date
    /// What was settled, for the list of resolved findings.
    public let title: String
    /// sha256 of the file when the decision was made. A file that changes since then
    /// is a different file, so the finding comes back.
    public let sha256: String?
    /// Engines that saw nothing, for `virusTotalClean`.
    public let engines: Int?

    public var id: String { issueID }

    public init(
        issueID: String, reason: Reason, title: String, date: Date = Date(),
        sha256: String? = nil, engines: Int? = nil
    ) {
        self.issueID = issueID
        self.reason = reason
        self.title = title
        self.date = date
        self.sha256 = sha256
        self.engines = engines
    }
}

/// Remembers which findings are settled, so a clean app stops being reported every scan.
public final class SecurityDecisions: Sendable {
    public static let standard = SecurityDecisions(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacUtil/SecurityDecisions.json")
    )

    private let url: URL
    private let decisions: Locked<[String: SecurityDecision]>

    public init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stored = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: SecurityDecision].self, from: $0) }
        decisions = Locked(stored ?? [:])
    }

    public var all: [SecurityDecision] {
        decisions.withLock { Array($0.values) }.sorted { $0.date > $1.date }
    }

    public func decision(for issueID: String) -> SecurityDecision? {
        decisions.withLock { $0[issueID] }
    }

    public func isResolved(_ issueID: String) -> Bool {
        decision(for: issueID) != nil
    }

    public func resolve(_ decision: SecurityDecision) {
        write { $0[decision.issueID] = decision }
    }

    /// Brings a finding back into the list.
    public func clear(_ issueID: String) {
        write { $0[issueID] = nil }
    }

    public func clearAll() {
        write { $0.removeAll() }
    }

    /// Drops decisions whose file has changed since, so a replaced binary is judged again.
    /// Returns the ids that were dropped.
    @discardableResult
    public func revalidate(paths: [String: String], hash: (String) -> String? = { try? FileHasher.sha256(of: $0) }) -> [String] {
        let stale = decisions.withLock { decisions in
            decisions.values.filter { decision in
                guard let expected = decision.sha256, let path = paths[decision.issueID] else { return false }
                return hash(path) != expected
            }.map(\.issueID)
        }
        guard !stale.isEmpty else { return [] }
        write { decisions in
            for id in stale { decisions[id] = nil }
        }
        return stale
    }

    private func write(_ change: (inout [String: SecurityDecision]) -> Void) {
        let snapshot = decisions.withLock { decisions -> [String: SecurityDecision] in
            change(&decisions)
            return decisions
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
