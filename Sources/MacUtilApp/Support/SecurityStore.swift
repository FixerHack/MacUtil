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

        /// The file this finding is about, when there is one to check or hash.
        var path: String? {
            switch target {
            case let .persistence(item): item.executable
            case let .app(app): app.path
            case let .process(process): process.executable
            case let .permission(grant): grant.clientIsPath ? grant.client : nil
            default: nil
            }
        }

        var title: String {
            switch target {
            case let .check(check): String(localized: check.title)
            case let .persistence(item): item.label
            case let .app(app): app.name
            case let .permission(grant): grant.client
            case let .port(port): "\(port.command):\(port.port)"
            case let .process(process): process.name
            case let .browserExtension(item): item.name
            case let .secret(secret): secret.path
            case let .network(title, _): title
            }
        }
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
    private let decisions: SecurityDecisions
    /// Findings settled earlier, so they stay out of the list and out of the score.
    private(set) var resolved: [SecurityDecision] = []

    init(decisions: SecurityDecisions = .standard) {
        self.decisions = decisions
        resolved = decisions.all
    }

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
        await dropDecisionsForChangedFiles()
    }

    /// A settled file that has changed since is a different file, so its finding comes back.
    private func dropDecisionsForChangedFiles() async {
        var paths: [String: String] = [:]
        for issue in allIssues {
            if let path = issue.path { paths[issue.id] = path }
        }
        let store = decisions
        let stale = await Task.detached { store.revalidate(paths: paths) }.value
        if !stale.isEmpty { resolved = decisions.all }
    }

    func resetPermission(_ grant: PermissionGrant) async {
        if await PrivacyPermissions.reset(grant) {
            permissions = try? PrivacyPermissions.load()
        }
    }

    /// Settings score, lowered by risky autostart items and untrusted apps.
    var score: Int {
        // Settled findings are left out: a file VirusTotal cleared is not a threat.
        let open = issues
        var high = 0, medium = 0, untrusted = 0, otherHigh = 0, otherMedium = 0
        for issue in open {
            switch issue.target {
            case .persistence:
                if issue.severity == .high { high += 1 } else { medium += 1 }
            case .app:
                untrusted += 1
            case .check:
                continue
            default:
                if issue.severity == .high { otherHigh += 1 } else if issue.severity == .medium { otherMedium += 1 }
            }
        }
        let penalty = min(50, high * 10 + medium * 4 + untrusted * 2 + otherHigh * 10 + otherMedium * 3)
        let openChecks = Set(open.compactMap { issue -> String? in
            if case let .check(check) = issue.target { return check.id }
            return nil
        })
        let counted = checks.filter { $0.status == .pass || $0.status == .info || openChecks.contains($0.id) }
        return max(0, SystemSecurityScanner.score(counted) - penalty)
    }

    /// Findings still asking for attention.
    var issues: [Issue] {
        allIssues.filter { !decisions.isResolved($0.id) }
    }

    /// Every finding, including the settled ones.
    var allIssues: [Issue] {
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

    // MARK: - Settling findings

    func isResolved(_ issue: Issue) -> Bool {
        decisions.isResolved(issue.id)
    }

    /// Marks a finding as known and trusted by the person.
    func trust(_ issue: Issue) async {
        var sha256: String?
        if let path = issue.path {
            sha256 = await Task.detached { try? FileHasher.sha256(of: path) }.value
        }
        decisions.resolve(SecurityDecision(
            issueID: issue.id, reason: .trusted, title: issue.title, sha256: sha256
        ))
        resolved = decisions.all
    }

    /// Brings a settled finding back into the list.
    func unresolve(_ issueID: String) {
        decisions.clear(issueID)
        resolved = decisions.all
    }

    /// Settles every finding about a file VirusTotal found clean.
    private func resolveCleanVirusTotal(path: String, report: VirusTotalReport) {
        guard report.isClean() else { return }
        for issue in allIssues where issue.path == path {
            decisions.resolve(SecurityDecision(
                issueID: issue.id, reason: .virusTotalClean, title: issue.title,
                sha256: report.sha256, engines: report.engines
            ))
        }
        resolved = decisions.all
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
                if case let .found(report) = cached { resolveCleanVirusTotal(path: path, report: report) }
                return
            }
            let lookup = try await client.lookup(sha256: sha256)
            cache.store(lookup, sha256: sha256)
            virusTotal[path] = .done(lookup)
            if case let .found(report) = lookup { resolveCleanVirusTotal(path: path, report: report) }
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
            resolveCleanVirusTotal(path: path, report: report)
        } catch {
            virusTotal[path] = .failed(error.localizedDescription)
        }
    }
}
