import Foundation
@testable import SecurityCore
import Testing

struct SecurityDecisionsTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "decisions-\(UUID().uuidString).json")
    }

    @Test func remembersDecisionsAcrossLaunches() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let decisions = SecurityDecisions(url: file)
        decisions.resolve(SecurityDecision(
            issueID: "app./Applications/Game.app", reason: .virusTotalClean,
            title: "Game", sha256: "abc", engines: 76
        ))
        #expect(decisions.isResolved("app./Applications/Game.app"))

        let reopened = SecurityDecisions(url: file)
        let decision = try #require(reopened.decision(for: "app./Applications/Game.app"))
        #expect(decision.reason == .virusTotalClean)
        #expect(decision.engines == 76)
        #expect(decision.title == "Game")
    }

    @Test func bringingBackRemovesTheDecision() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let decisions = SecurityDecisions(url: file)
        decisions.resolve(SecurityDecision(issueID: "proc.1", reason: .trusted, title: "helper"))
        decisions.clear("proc.1")

        #expect(!decisions.isResolved("proc.1"))
        #expect(SecurityDecisions(url: file).all.isEmpty)
    }

    @Test func aChangedFileComesBackToTheList() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let decisions = SecurityDecisions(url: file)
        decisions.resolve(SecurityDecision(issueID: "app.a", reason: .virusTotalClean, title: "A", sha256: "old"))
        decisions.resolve(SecurityDecision(issueID: "app.b", reason: .trusted, title: "B", sha256: "same"))

        let dropped = decisions.revalidate(paths: ["app.a": "/tmp/a", "app.b": "/tmp/b"]) { path in
            path == "/tmp/a" ? "new" : "same"
        }

        #expect(dropped == ["app.a"])
        #expect(!decisions.isResolved("app.a"))
        #expect(decisions.isResolved("app.b"))
    }

    @Test func decisionsWithoutAFileAreKept() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let decisions = SecurityDecisions(url: file)
        decisions.resolve(SecurityDecision(issueID: "check.firewall", reason: .trusted, title: "Firewall"))

        #expect(decisions.revalidate(paths: [:]) { _ in nil }.isEmpty)
        #expect(decisions.isResolved("check.firewall"))
    }
}

struct VirusTotalVerdictTests {
    private func report(malicious: Int, suspicious: Int = 0, harmless: Int, undetected: Int) -> VirusTotalReport {
        VirusTotalReport(
            sha256: "abc", malicious: malicious, suspicious: suspicious, harmless: harmless,
            undetected: undetected, name: nil, analysisDate: nil
        )
    }

    @Test func noDetectionsFromEnoughEnginesIsClean() {
        #expect(report(malicious: 0, harmless: 40, undetected: 30).isClean())
    }

    @Test func anyDetectionIsNotClean() {
        #expect(!report(malicious: 1, harmless: 40, undetected: 30).isClean())
        #expect(!report(malicious: 0, suspicious: 2, harmless: 40, undetected: 30).isClean())
    }

    @Test func tooFewEnginesProveNothing() {
        #expect(!report(malicious: 0, harmless: 2, undetected: 1).isClean())
    }
}
