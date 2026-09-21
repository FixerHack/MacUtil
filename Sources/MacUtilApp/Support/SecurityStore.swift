import Foundation
import Observation
import SecurityCore

/// Security Analyzer state: system checks, autostart items, app signatures and
/// VirusTotal lookups. VirusTotal only ever receives a hash unless the user
/// confirms an upload.
@MainActor
@Observable
final class SecurityStore {
    enum Phase {
        case idle, scanning, ready
    }

    enum VirusTotalState: Equatable {
        case working
        case done(VirusTotalLookup)
        case uploading
        case failed(String)
    }

    /// Something the overview lists for attention.
    struct Issue: Identifiable {
        enum Target {
            case check(SecurityCheck)
            case persistence(PersistenceItem)
            case app(InstalledApp)
            case permission(PermissionGrant)
            case port(ListeningPort)
            case process(SuspiciousProcess)
            case browserExtension(BrowserExtension)
            case secret(SecretFinding)
            case network(title: String, details: [String])
        }

        let id: String
        let severity: PersistenceItem.Risk
        let target: Target
    }

    private(set) var phase = Phase.idle
    private(set) var checks: [SecurityCheck] = []
    private(set) var persistence: [PersistenceItem] = []
    private(set) var apps: [InstalledApp] = []
    /// Nil when the TCC databases cannot be read without Full Disk Access.
    private(set) var permissions: [PermissionGrant]?
    private(set) var network = NetworkReport()
    private(set) var processes: [SuspiciousProcess] = []
    private(set) var extensions: [BrowserExtension] = []
    private(set) var secrets: [SecretFinding] = []
    private(set) var virusTotal: [String: VirusTotalState] = [:]
    private(set) var hasAPIKey = VirusTotalKey.exists()
    /// Checked and total items of a bulk VirusTotal run.
    private(set) var bulkProgress: (done: Int, total: Int)?
    private var client: VirusTotalClient?
    private let cache = VirusTotalCache.standard

    func scan() async {
        phase = .scanning
        async let checks = SystemSecurityScanner.run()
        async let persistence = PersistenceScanner().scan()
        async let apps = AppInventory.scan()
        async let network = NetworkInspector.inspect()
        async let processes = ProcessInspector.inspect()
        async let secrets = SecretScanner.scan()
        async let extensions = Task.detached { BrowserExtensions.scan() }.value
        permissions = try? PrivacyPermissions.load()
        (self.checks, self.persistence, self.apps) = await (checks, persistence, apps)
        (self.network, self.processes, self.secrets, self.extensions) = await (network, processes, secrets, extensions)
        phase = .ready
    }

    func resetPermission(_ grant: PermissionGrant) async {
        if await PrivacyPermissions.reset(grant) {
            permissions = try? PrivacyPermissions.load()
        }
    }

    /// Settings score, lowered by risky autostart items and untrusted apps.
    var score: Int {
        let high = persistence.filter { $0.risk == .high }.count
        let medium = persistence.filter { $0.risk == .medium }.count
        let untrusted = apps.filter { $0.signature.trust == .untrusted }.count
        let others: [PersistenceItem.Risk] = issues.compactMap { issue in
            switch issue.target {
            case .check, .persistence, .app: nil
            default: issue.severity
            }
        }
        let penalty = min(
            50,
            high * 10 + medium * 4 + untrusted * 2
                + others.filter { $0 == .high }.count * 10 + others.filter { $0 == .medium }.count * 3
        )
        return max(0, SystemSecurityScanner.score(checks) - penalty)
    }

    var issues: [Issue] {
        var issues: [Issue] = []
        for check in checks where check.status == .fail || check.status == .warning {
            issues.append(Issue(
                id: "check." + check.id,
                severity: check.status == .fail ? .high : .medium,
                target: .check(check)
            ))
        }
        for item in persistence where item.risk >= .medium {
            issues.append(Issue(id: "item." + item.id, severity: item.risk, target: .persistence(item)))
        }
        for app in apps where app.signature.trust == .untrusted {
            issues.append(Issue(id: "app." + app.id, severity: .medium, target: .app(app)))
        }
        for grant in permissions ?? [] where grant.risk >= .medium {
            issues.append(Issue(id: "tcc." + grant.id, severity: grant.risk, target: .permission(grant)))
        }
        for port in network.ports where port.risk >= .medium {
            issues.append(Issue(id: "port." + port.id, severity: port.risk, target: .port(port)))
        }
        for process in processes where process.risk >= .medium {
            issues.append(Issue(id: "proc." + process.id, severity: process.risk, target: .process(process)))
        }
        for item in extensions where item.risk >= .medium {
            issues.append(Issue(id: "ext." + item.id, severity: item.risk, target: .browserExtension(item)))
        }
        for secret in secrets where secret.risk >= .medium {
            issues.append(Issue(id: "secret." + secret.id, severity: secret.risk, target: .secret(secret)))
        }
        if !network.proxies.isEmpty {
            issues.append(Issue(
                id: "net.proxy",
                severity: .medium,
                target: .network(title: "proxy", details: network.proxies)
            ))
        }
        if !network.hostsEntries.isEmpty {
            issues.append(Issue(
                id: "net.hosts",
                severity: .medium,
                target: .network(title: "hosts", details: network.hostsEntries)
            ))
        }
        if !network.trustedCertificates.isEmpty {
            issues.append(Issue(
                id: "net.certs",
                severity: .high,
                target: .network(title: "certificates", details: network.trustedCertificates)
            ))
        }
        return issues.sorted { $0.severity > $1.severity }
    }

    // MARK: - VirusTotal

    func refreshKey() {
        hasAPIKey = VirusTotalKey.exists()
        client = nil
    }

    private func makeClient() -> VirusTotalClient? {
        if let client {
            return client
        }
        guard let key = VirusTotalKey.load() else { return nil }
        let client = VirusTotalClient(apiKey: key)
        self.client = client
        return client
    }

    func checkVirusTotal(_ path: String) async {
        guard let client = makeClient() else {
            virusTotal[path] = .failed(VirusTotalError.missingKey.localizedDescription)
            return
        }
        virusTotal[path] = .working
        do {
            let sha256 = try await Task.detached { try FileHasher.sha256(of: path) }.value
            if let cached = cache.lookup(sha256: sha256) {
                virusTotal[path] = .done(cached)
                return
            }
            let lookup = try await client.lookup(sha256: sha256)
            cache.store(lookup, sha256: sha256)
            virusTotal[path] = .done(lookup)
        } catch {
            virusTotal[path] = .failed(error.localizedDescription)
        }
    }

    /// Checks every autostart program that is not part of macOS, one by one
    /// within the free API rate limit.
    func checkAllAutostart() async {
        let paths = Array(Set(persistence.compactMap { item -> String? in
            guard let executable = item.executable, item.signature?.signer != .apple,
                  FileManager.default.isReadableFile(atPath: executable)
            else { return nil }
            return executable
        })).sorted()
        bulkProgress = (0, paths.count)
        for (index, path) in paths.enumerated() {
            if case .done = virusTotal[path] {} else {
                await checkVirusTotal(path)
            }
            bulkProgress = (index + 1, paths.count)
        }
        bulkProgress = nil
    }

    /// Sends the file itself to VirusTotal. Only called after the user confirmed.
    func upload(_ path: String) async {
        guard let client = makeClient() else { return }
        virusTotal[path] = .uploading
        do {
            var target = path
            if path.hasSuffix(".app"), let executable = Bundle(path: path)?.executablePath {
                target = executable
            }
            let sha256 = try await Task.detached { try FileHasher.sha256(of: path) }.value
            let report = try await client.upload(fileAt: URL(filePath: target), sha256: sha256)
            cache.store(.found(report), sha256: sha256)
            virusTotal[path] = .done(.found(report))
        } catch {
            virusTotal[path] = .failed(error.localizedDescription)
        }
    }
}
