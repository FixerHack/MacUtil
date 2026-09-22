import CryptoKit
import Foundation
@testable import SecurityCore
import Testing

/// Serialized: the tests share one stubbed URL protocol.
@Suite(.serialized) struct SelfUpdateTests {
    /// A trimmed copy of what the GitHub releases API returns.
    private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data(
            """
            {
              "tag_name": "\(tag)",
              "html_url": "https://github.com/FixerHack/MacUtil/releases/tag/\(tag)",
              "body": "notes",
              "draft": \(draft),
              "prerelease": \(prerelease),
              "assets": [
                {
                  "name": "MacUtil-9.9.9.zip", "size": 10, "digest": "sha256:aa",
                  "browser_download_url": "https://example.invalid/MacUtil-9.9.9.zip"
                },
                {
                  "name": "MacUtil-9.9.9.dmg", "size": 42, "digest": "sha256:bb",
                  "browser_download_url": "https://example.invalid/MacUtil-9.9.9.dmg"
                }
              ]
            }
            """.utf8
        )
    }

    private func check(_ data: Data, current: String) async throws -> MacUtilRelease? {
        StubbedURLProtocol.body = data
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedURLProtocol.self]
        return try await SelfUpdate.check(currentVersion: current, session: URLSession(configuration: configuration))
    }

    @Test func picksTheDiskImageAndStripsTheTagPrefix() async throws {
        let release = try #require(await check(releaseJSON(tag: "v9.9.9"), current: "0.1.1"))
        #expect(release.version == "9.9.9")
        #expect(release.downloadURL.lastPathComponent == "MacUtil-9.9.9.dmg")
        #expect(release.sha256 == "bb")
        #expect(release.size == 42)
        #expect(release.notes == "notes")
    }

    @Test func sameOrOlderVersionIsNoUpdate() async throws {
        #expect(try await check(releaseJSON(tag: "v0.1.1"), current: "0.1.1") == nil)
        #expect(try await check(releaseJSON(tag: "v0.1.0"), current: "0.1.1") == nil)
    }

    @Test func draftsAndPrereleasesAreIgnored() async throws {
        #expect(try await check(releaseJSON(tag: "v9.9.9", draft: true), current: "0.1.1") == nil)
        #expect(try await check(releaseJSON(tag: "v9.9.9", prerelease: true), current: "0.1.1") == nil)
    }

    @Test func versionsCompareByNumber() {
        #expect(SelfUpdate.isNewer("0.2.0", than: "0.1.9"))
        #expect(SelfUpdate.isNewer("0.10.0", than: "0.9.0"))
        #expect(SelfUpdate.isNewer("1.0.0", than: "0.99.0"))
        #expect(!SelfUpdate.isNewer("0.1.1", than: "0.1.1"))
        #expect(!SelfUpdate.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func hashesAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mu-\(UUID().uuidString)")
        try Data("MacUtil".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let expected = SHA256.hash(data: Data("MacUtil".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(try SelfUpdate.sha256(of: file) == expected)
    }

    @Test func refusesAnAppSignedBySomeoneElse() throws {
        // Calculator is signed by Apple, so it cannot satisfy another app's requirement.
        #expect(throws: SelfUpdate.Failure.notSameSigner) {
            try SelfUpdate.verifySameSigner(
                URL(filePath: "/System/Applications/Calculator.app"),
                as: URL(filePath: "/System/Applications/Chess.app")
            )
        }
    }

    @Test func acceptsTheSameApp() throws {
        let app = URL(filePath: "/System/Applications/Calculator.app")
        try SelfUpdate.verifySameSigner(app, as: app)
    }
}

/// Answers every request with the same body, so no test touches the network.
private final class StubbedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
