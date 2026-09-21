import Foundation
@testable import SecurityCore
import Testing

struct CodeSignatureTests {
    @Test func appleAppIsTrusted() {
        let signature = CodeSignature.inspect("/System/Applications/Calculator.app")
        #expect(signature.signer == .apple)
        #expect(signature.validity == .valid)
        #expect(signature.trust == .trusted)
    }

    @Test func plainFileIsUnsigned() throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "mc-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }

        let signature = CodeSignature.inspect(script.path(percentEncoded: false))
        #expect(signature.signer == .unsigned)
        #expect(signature.trust == .untrusted)
    }

    @Test func unreadableFileIsNotCalledUnsigned() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mc-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o111],
            ofItemAtPath: file.path(percentEncoded: false)
        )

        let signature = CodeSignature.inspect(file.path(percentEncoded: false))
        #expect(signature.validity == .unreadable)
        #expect(PersistenceScanner.signatureFindings(signature) == [.cannotInspect])
    }

    @Test func extractsOrganizationFromCertificateName() {
        #expect(CodeSignature
            .organization(from: "Developer ID Application: Brave Software, Inc. (KL8N8XSYF4)") ==
            "Brave Software, Inc.")
        #expect(CodeSignature.organization(from: "Apple Development: Jane Doe (ABC123)") == "Jane Doe")
    }

    @Test func parsesQuarantineAttribute() {
        let info = QuarantineInfo.parse("0083;66a1b2c3;Safari;0F3C2A1B-0000-0000-0000-000000000000")
        #expect(info?.agent == "Safari")
        #expect(info?.date == Date(timeIntervalSince1970: TimeInterval(0x66A1_B2C3)))
    }
}

struct SystemSecurityTests {
    @Test func parsesCommandOutput() {
        #expect(SystemSecurityScanner.sipCheck("System Integrity Protection status: enabled.").status == .pass)
        #expect(SystemSecurityScanner.sipCheck("System Integrity Protection status: disabled.").status == .fail)
        #expect(SystemSecurityScanner.gatekeeperCheck("assessments disabled").status == .fail)
        #expect(SystemSecurityScanner.fileVaultCheck("FileVault is On.").status == .pass)
        #expect(SystemSecurityScanner.firewallCheck("Firewall is disabled. (State = 0)").status == .warning)
    }

    @Test func parsesScreenLockDelay() {
        #expect(SystemSecurityScanner.screenLockDelay("screenLock delay is 300 seconds") == .some(300))
        #expect(SystemSecurityScanner.screenLockDelay("screenLock delay is immediate") == .some(0))
        #expect(SystemSecurityScanner.screenLockDelay("screenLock is off") == .some(nil))
        #expect(SystemSecurityScanner.screenLockCheck("screenLock delay is 300 seconds").status == .warning)
        #expect(SystemSecurityScanner.screenLockCheck("screenLock delay is 5 seconds").status == .pass)
    }

    @Test func parsesDisabledServices() {
        let output = """
        disabled services = {
            "com.openssh.sshd" => enabled
            "com.apple.screensharing" => disabled
            "com.apple.smbd" => false
        }
        """
        let services = SystemSecurityScanner.parseDisabledServices(output)
        #expect(services["com.openssh.sshd"] == true)
        #expect(services["com.apple.screensharing"] == false)
        #expect(services["com.apple.smbd"] == true)
    }

    @Test func scoreWeighsChecks() {
        func check(_ status: SecurityCheck.Status, _ weight: Int) -> SecurityCheck {
            SecurityCheck(id: UUID().uuidString, title: "t", status: status, summary: "s", weight: weight)
        }
        #expect(SystemSecurityScanner.score([check(.pass, 10), check(.fail, 10)]) == 50)
        #expect(SystemSecurityScanner.score([check(.pass, 10), check(.warning, 10)]) == 75)
        #expect(SystemSecurityScanner.score([check(.pass, 10), check(.info, 0)]) == 100)
    }

    @Test func realScanReturnsEveryCheck() async {
        let checks = await SystemSecurityScanner.run()
        #expect(checks.count == 15)
        #expect(Set(checks.map(\.id)).count == checks.count)
    }
}

struct PersistenceTests {
    @Test func assessesLaunchAgents() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mc-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func agent(_ label: String, _ arguments: [String]) throws {
            let plist: [String: Any] = ["Label": label, "ProgramArguments": arguments, "RunAtLoad": true]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: folder.appending(path: "\(label).plist"))
        }
        try agent("com.apple.like", ["/usr/bin/true"])
        try agent("com.evil.tmp", ["/tmp/payload"])
        try agent("com.script.runner", ["/bin/bash", "-c", "/Users/me/run.sh"])
        try agent("com.gone.app", ["/Applications/Removed.app/Contents/MacOS/Removed"])

        var scanner = PersistenceScanner(home: "/nonexistent")
        scanner.userAgents = folder.path(percentEncoded: false)
        scanner.agents = "/nonexistent"
        scanner.daemons = "/nonexistent"
        scanner.kernelExtensions = "/nonexistent"
        scanner.includesCron = false
        let items = await Dictionary(uniqueKeysWithValues: scanner.scan().map { ($0.label, $0) })

        #expect(items["com.apple.like"]?.risk == PersistenceItem.Risk.none)
        #expect(items["com.evil.tmp"]?.findings.contains(.suspiciousLocation("/tmp/")) == true)
        #expect(items["com.evil.tmp"]?.risk == .high)
        #expect(items["com.script.runner"]?.risk == .medium)
        #expect(items["com.gone.app"]?.findings == [.missingExecutable])
    }

    @Test func parsesCrontab() {
        let crontab = """
        # comment
        PATH=/usr/bin:/bin
        */5 * * * * /usr/local/bin/backup --quiet
        @reboot /Users/Shared/.hidden/agent
        """
        let items = PersistenceScanner(home: "/nonexistent").cronItems(crontab)
        #expect(items.count == 2)
        #expect(items.first?.executable == "/usr/local/bin/backup")
        #expect(items.last?.risk == .high)
    }

    @Test func flagsHiddenFolders() {
        #expect(PersistenceScanner.locationFinding("/Users/me/.hidden/tool") == .hiddenLocation(".hidden"))
        #expect(PersistenceScanner.locationFinding("/Users/me/.cargo/bin/tool") == nil)
        #expect(PersistenceScanner.locationFinding("/Applications/App.app/Contents/MacOS/App") == nil)
    }
}

/// Serves canned responses instead of the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var requestedKeys: [String] = []

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestedKeys.append(request.value(forHTTPHeaderField: "x-apikey") ?? "")
        let (status, body) = Self.responses[request.url?.lastPathComponent ?? ""] ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct VirusTotalTests {
    func client() -> VirusTotalClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return VirusTotalClient(
            apiKey: "test-key",
            session: URLSession(configuration: configuration),
            minimumInterval: .zero
        )
    }

    @Test func parsesKnownUnknownAndErrors() async throws {
        StubProtocol.responses = [
            "known": (200, """
            {"data":{"attributes":{"meaningful_name":"tool","last_analysis_date":1700000000,
            "last_analysis_stats":{"malicious":2,"suspicious":1,"harmless":0,"undetected":60}}}}
            """),
            "unseen": (404, #"{"error":{"code":"NotFoundError"}}"#),
            "badkey": (401, ""),
            "busy": (429, ""),
        ]
        let client = client()

        guard case let .found(report) = try await client.lookup(sha256: "known") else {
            Issue.record("expected a report")
            return
        }
        #expect(report.detections == 3)
        #expect(report.engines == 63)
        #expect(report.name == "tool")
        #expect(report.permalink.absoluteString.hasSuffix("/gui/file/known"))

        #expect(try await client.lookup(sha256: "unseen") == .unknown(sha256: "unseen"))
        await #expect(throws: VirusTotalError.invalidKey) { try await client.lookup(sha256: "badkey") }
        await #expect(throws: VirusTotalError.rateLimited) { try await client.lookup(sha256: "busy") }
        #expect(StubProtocol.requestedKeys.allSatisfy { $0 == "test-key" })
    }

    @Test func hashesFilesAndAppExecutables() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "mc-hash-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try FileHasher.sha256(of: file.path(percentEncoded: false))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // An app is identified by its main executable.
        #expect(try FileHasher.sha256(of: "/System/Applications/Calculator.app")
            == FileHasher.sha256(of: "/System/Applications/Calculator.app/Contents/MacOS/Calculator"))
    }

    @Test func cacheExpires() {
        let url = FileManager.default.temporaryDirectory.appending(path: "mc-vt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let cache = VirusTotalCache(url: url, maxAge: 100)
        cache.store(.unknown(sha256: "x"), sha256: "x", now: now)

        #expect(VirusTotalCache(url: url, maxAge: 100).lookup(sha256: "x", now: now) == .unknown(sha256: "x"))
        #expect(cache.lookup(sha256: "x", now: now.addingTimeInterval(200)) == nil)
    }
}
