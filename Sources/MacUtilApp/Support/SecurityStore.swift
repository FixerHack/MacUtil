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
        }

        let id: String
        let severity: PersistenceItem.Risk
        let target: Target
    }

    private(set) var phase = Phase.idle
    private(set) var checks: [SecurityCheck] = []
    private(set) var persistence: [PersistenceItem] = []
    private(set) var apps: [InstalledApp] = []
    private(set) var virusTotal: [String: VirusTotalState] = [:]
    private(set) var hasAPIKey = VirusTotalKey.load() != nil
    /// Checked and total items of a bulk VirusTotal run.
    private(set) var bulkProgress: (done: Int, total: Int)?
    private var client: VirusTotalClient?
    private let cache = VirusTotalCache.standard

    func scan() async {
        phase = .scanning
        async let checks = SystemSecurityScanner.run()
        async let persistence = PersistenceScanner().scan()
        async let apps = AppInventory.scan()
        (self.checks, self.persistence, self.apps) = await (checks, persistence, apps)
        phase = .ready
    }

    /// Settings score, lowered by risky autostart items and untrusted apps.
    var score: Int {
        let high = persistence.filter { $0.risk == .high }.count
        let medium = persistence.filter { $0.risk == .medium }.count
        let untrusted = apps.filter { $0.signature.trust == .untrusted }.count
        let penalty = min(40, high * 10 + medium * 4 + untrusted * 2)
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
        return issues.sorted { $0.severity > $1.severity }
    }

    // MARK: - VirusTotal

    func refreshKey() {
        hasAPIKey = VirusTotalKey.load() != nil
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
