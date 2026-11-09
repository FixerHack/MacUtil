@testable import CleanerCore
import Foundation
import Testing

struct AppRuntimeTests {
    /// A folder shaped like an app bundle, with whatever else the test lays inside it.
    private func bundle(_ build: (URL) throws -> Void) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "mu-app-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try build(app)
        return app
    }

    @Test func recognisesElectronAndItsVersion() throws {
        let app = try bundle { app in
            let resources = app.appending(path: "Contents/Frameworks/Electron Framework.framework/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try (["CFBundleVersion": "30.1.2"] as NSDictionary).write(to: resources.appending(path: "Info.plist"))
        }
        defer { try? FileManager.default.removeItem(at: app) }

        let runtime = try #require(AppRuntimeDetector.detect(app.path))
        #expect(runtime.kind == .electron)
        #expect(runtime.version == "30.1.2")
        #expect(runtime.majorVersion == 30)
    }

    @Test func recognisesFlutterAndIPhoneApps() throws {
        let flutter = try bundle { app in
            try FileManager.default.createDirectory(
                at: app.appending(path: "Contents/Frameworks/FlutterMacOS.framework"), withIntermediateDirectories: true
            )
        }
        let iPhone = try bundle { app in
            try FileManager.default.createDirectory(at: app.appending(path: "Wrapper"), withIntermediateDirectories: true)
        }
        let plain = try bundle { _ in }
        defer { [flutter, iPhone, plain].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(AppRuntimeDetector.detect(flutter.path)?.kind == .flutter)
        #expect(AppRuntimeDetector.detect(iPhone.path)?.kind == .iOS)
        #expect(AppRuntimeDetector.detect(plain.path) == nil)
    }

    @Test func tellsAnOldElectronFromACurrentOne() throws {
        // 8 November 2026.
        let day = try Date("2026-11-08T12:00:00Z", strategy: .iso8601)
        #expect(ElectronReleases.estimatedLatest(on: day) == 45)
        #expect(AppRuntime(kind: .electron, version: "30.0.0").isOutdated(on: day))
        #expect(!AppRuntime(kind: .electron, version: "43.8.3").isOutdated(on: day))
        #expect(!AppRuntime(kind: .flutter).isOutdated(on: day))
        // Electron 39 came out eight weeks after 38.
        #expect(try ElectronReleases.estimatedLatest(on: Date("2025-10-28T12:00:00Z", strategy: .iso8601)) == 39)
    }

    @Test func readsThePlatformAndLibrariesFromLoadCommands() {
        func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        // LC_BUILD_VERSION for Mac Catalyst, then one LC_LOAD_DYLIB naming WebKit.
        var commands = le(0x32) + le(24) + le(6) + le(0) + le(0) + le(0)
        let name = Array("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit".utf8) + [0]
        let size = UInt32((24 + name.count + 7) / 8 * 8)
        commands += le(0xC) + le(size) + le(24) + le(0) + le(0) + le(0) + name
        commands += Array(repeating: 0, count: Int(size) - 24 - name.count)

        let info = MachOLoadInfo.parse(commands: Data(commands), count: 2)
        #expect(info.platform == MachOLoadInfo.macCatalyst)
        #expect(info.dylibs == ["/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"])
    }

    @Test func readsARealExecutable() throws {
        // A universal system binary, present on every Mac including a build runner.
        let info = try #require(MachOLoadInfo.read("/bin/ls"))
        #expect(info.platform == 1)
        #expect(info.dylibs.contains { $0.contains("libSystem") })
        #expect(AppRuntimeDetector.contains("/bin/ls", marker: Data("tauri".utf8)) == false)
    }
}

struct DNSControlTests {
    @Test func readsServicesAndServers() {
        let services = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Thunderbolt Bridge
        USB 10/100/1000 LAN
        """
        #expect(DNSControl.parseServices(services) == ["Wi-Fi", "USB 10/100/1000 LAN"])
        #expect(DNSControl.parseServers("There aren't any DNS Servers set on Wi-Fi.\n").isEmpty)
        #expect(DNSControl.parseServers("1.1.1.1\n2606:4700:4700::1111\n") == ["1.1.1.1", "2606:4700:4700::1111"])
    }

    @Test func namesAPresetFromItsServers() {
        #expect(DNSPreset.matching(["1.0.0.1", "1.1.1.1"])?.id == "cloudflare")
        #expect(DNSPreset.matching(["192.168.1.1"]) == nil)
        #expect(DNSPreset.matching([]) == nil)
    }

    @Test func writesAProfileMacOSCanRead() throws {
        let preset = try #require(DNSPreset.all.first { $0.id == "quad9" })
        let data = Data(DNSControl.encryptedProfile(for: preset).utf8)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["PayloadType"] as? String == "Configuration")
        let payload = try #require((plist["PayloadContent"] as? [[String: Any]])?.first)
        #expect(payload["PayloadType"] as? String == "com.apple.dnsSettings.managed")
        let settings = try #require(payload["DNSSettings"] as? [String: Any])
        #expect(settings["ServerURL"] as? String == "https://dns.quad9.net/dns-query")
        #expect(settings["DNSProtocol"] as? String == "HTTPS")
    }

    @Test func checksAddressesAndNames() {
        #expect(DNSControl.isAddress("10.0.0.1"))
        #expect(DNSControl.isAddress("::1"))
        #expect(!DNSControl.isAddress("example.com"))
        #expect(HostsOverride.isValidHostname("api.staging.example.com"))
        #expect(!HostsOverride.isValidHostname("bad host"))
        #expect(!HostsOverride.isValidHostname("-nope.com"))
        #expect(!HostsOverride.isValidHostname(""))
    }
}

struct HostsFileTests {
    private let original = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    10.0.0.5 nas.home

    """

    @Test func keepsEveryLineItDidNotWrite() throws {
        let until = try Date("2026-11-08T15:00:00Z", strategy: .iso8601)
        let overrides = [
            HostsOverride(hostname: "API.example.com", address: "10.1.1.1", until: until),
            HostsOverride(hostname: "local.dev", address: "127.0.0.1", until: nil),
        ]
        let updated = HostsFile.updated(original, with: overrides)

        #expect(updated.hasPrefix(original))
        #expect(HostsFile.overrides(in: updated) == [
            HostsOverride(hostname: "api.example.com", address: "10.1.1.1", until: until),
            HostsOverride(hostname: "local.dev", address: "127.0.0.1", until: nil),
        ])
        // Taking them all out leaves the file as it was.
        #expect(HostsFile.updated(updated, with: []) == original)
        #expect(ManagedBlock.outside(updated).trimmingCharacters(in: .newlines) == original.trimmingCharacters(in: .newlines))
    }

    @Test func knowsWhenAnOverrideRunsOut() {
        let soon = HostsOverride(hostname: "a.com", address: "1.2.3.4", until: Date(timeIntervalSinceNow: 60))
        #expect(!soon.hasExpired())
        #expect(soon.hasExpired(at: Date(timeIntervalSinceNow: 120)))
        #expect(!HostsOverride(hostname: "a.com", address: "1.2.3.4", until: nil).hasExpired())
    }
}

struct DevDomainTests {
    @Test func answersThisMacForItsDomainsOnly() {
        let a = DevDNS.answer(to: DevDNS.query("App.Test"), domains: ["test"])
        #expect(a.flatMap(DevDNS.address(in:)) == "127.0.0.1")

        let aaaa = [UInt8](DevDNS.answer(to: DevDNS.query("app.test", type: 28), domains: ["test"]) ?? Data())
        #expect(aaaa.count > 12 && aaaa[7] == 1)

        let other = [UInt8](DevDNS.answer(to: DevDNS.query("example.com"), domains: ["test"]) ?? Data())
        #expect(other.count >= 12 && other[3] & 0x0F == 5)
        // The reply carries the query's id, so the asker can match it up.
        #expect(Array(other.prefix(2)) == [0x55, 0x44])

        #expect(DevDNS.answer(to: Data([1, 2, 3]), domains: ["test"]) == nil)
    }

    @Test func servesOverUDPOnTheLoopback() async throws {
        let port = UInt16.random(in: 54000 ... 59000)
        let server = try DevDNSServer(port: port, domains: ["test"])
        server.start()
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))

        #expect(await DevDNS.lookup("shop.test", port: port) == "127.0.0.1")
        #expect(await DevDNS.lookup("shop.example", port: port, timeout: .seconds(1)) == nil)
    }

    @Test func writesResolverFilesAndKnowsItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mu-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try DevDomains.resolverFile(port: 5300).write(to: folder.appending(path: "test"), atomically: true, encoding: .utf8)
        try "nameserver 10.0.0.1\n".write(to: folder.appending(path: "corp"), atomically: true, encoding: .utf8)

        #expect(DevDomains.installedDomains(in: folder.path) == ["test"])
        #expect(DevDomains.resolverFile(port: 5300).contains("port 5300"))
        #expect(DevDomains.isValidDomain("test"))
        #expect(!DevDomains.isValidDomain("local"))
        #expect(!DevDomains.isValidDomain("my.test"))

        let plist = DevDomains.agentPlist(tool: "/x/mucli", domains: ["test", "dev"])
        #expect(plist["ProgramArguments"] as? [String] == ["/x/mucli", "dns-serve", "--port", "53530", "--domain", "test", "--domain", "dev"])
    }
}

/// Real encrypted images, made and opened by hdiutil.
@Suite(.serialized) struct VaultTests {
    @Test func locksOpensAndChangesItsPassword() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mu-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = "MUVault-\(UUID().uuidString.prefix(6))"

        var created = await Vault.create(at: folder.appending(path: "Secrets"), volumeName: name, size: 40 << 20, password: "first pass")
        if case .failure = created {
            // hdiutil now and then refuses under a busy full run; see TestImages.
            try await Task.sleep(for: .seconds(1))
            created = await Vault.create(at: folder.appending(path: "Secrets"), volumeName: name, size: 40 << 20, password: "first pass")
        }
        let file = try created.get()
        #expect(file.pathExtension == "sparseimage")
        #expect(await Vault.create(at: file, volumeName: name, size: 40 << 20, password: "x") == .failure(.alreadyExists))

        #expect(await Vault.open(file.path, password: "wrong") == .failure(.wrongPassword))

        let mountPoint = try await Vault.open(file.path, password: "first pass").get()
        #expect(await Vault.mountPoint(of: file.path) == mountPoint)
        try Data("kept safe".utf8).write(to: URL(filePath: mountPoint).appending(path: "note.txt"))
        #expect(await Vault.close(file.path))
        #expect(await Vault.mountPoint(of: file.path) == nil)

        let refused = await Vault.changePassword(file.path, from: "wrong", to: "x")
        #expect(throws: Vault.Failure.wrongPassword) { try refused.get() }
        try await Vault.changePassword(file.path, from: "first pass", to: "second pass").get()
        #expect(await Vault.open(file.path, password: "first pass") == .failure(.wrongPassword))

        let reopened = try await Vault.open(file.path, password: "second pass").get()
        #expect(try String(contentsOf: URL(filePath: reopened).appending(path: "note.txt"), encoding: .utf8) == "kept safe")
        #expect(await Vault.close(file.path, force: true))
    }
}
