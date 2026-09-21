import Darwin
import Foundation

/// A running program that looks out of place.
public struct SuspiciousProcess: Sendable, Identifiable, Hashable {
    /// Every running instance of the program.
    public let pids: [Int32]
    public let name: String
    public let executable: String
    public let signature: CodeSignature?
    public let findings: [PersistenceItem.Finding]

    public var id: String { executable }

    /// For something already running, ad-hoc signatures (every locally built or
    /// Homebrew tool on Apple silicon) and hidden tool folders are only worth a note.
    public var risk: PersistenceItem.Risk {
        findings.map { finding -> PersistenceItem.Risk in
            switch finding {
            case .adHocSigned, .hiddenLocation, .runsScript: .low
            case .missingExecutable: .medium
            default: PersistenceItem.risk(of: finding)
            }
        }.max() ?? .none
    }
}

public enum ProcessInspector {
    /// Programs on the protected system volume are sealed by Apple and skipped.
    private static let sealedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// Running processes that are unsigned, broken, deleted from disk or started
    /// from temporary or hidden folders.
    public static func inspect() async -> [SuspiciousProcess] {
        await Task.detached {
            var byPath: [String: CodeSignature] = [:]
            var pidsByPath: [String: [Int32]] = [:]
            var result: [SuspiciousProcess] = []
            for pid in allPIDs() {
                guard let path = executablePath(of: pid),
                      !sealedPrefixes.contains(where: { path.hasPrefix($0) })
                else { continue }
                pidsByPath[path, default: []].append(pid)
                guard pidsByPath[path]?.count == 1 else { continue }

                var findings: [PersistenceItem.Finding] = []
                var signature: CodeSignature?
                if !FileManager.default.fileExists(atPath: path) {
                    findings.append(.missingExecutable)
                } else {
                    let checked = byPath[path] ?? CodeSignature.inspect(path)
                    byPath[path] = checked
                    signature = checked
                    findings += PersistenceScanner.signatureFindings(checked).filter { $0 != .notNotarized }
                }
                if let location = PersistenceScanner.locationFinding(path) {
                    findings.append(location)
                }
                guard !findings.isEmpty, findings != [.cannotInspect] else { continue }
                result.append(SuspiciousProcess(
                    pids: [], name: (path as NSString).lastPathComponent, executable: path,
                    signature: signature, findings: findings
                ))
            }
            return result
                .map {
                    SuspiciousProcess(
                        pids: pidsByPath[$0.executable] ?? [], name: $0.name, executable: $0.executable,
                        signature: $0.signature, findings: $0.findings
                    )
                }
                .sorted { ($0.risk, $1.name) > ($1.risk, $0.name) }
        }.value
    }

    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(filled, 0)))).filter { $0 > 0 }
    }

    public static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
