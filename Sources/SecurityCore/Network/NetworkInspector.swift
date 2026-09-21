import CleanerCore
import Foundation

/// A program accepting network connections.
public struct ListeningPort: Sendable, Identifiable, Hashable {
    public let pid: Int32
    public let command: String
    public let executable: String?
    public let address: String
    public let port: Int
    public let signature: CodeSignature?

    public var id: String { "\(pid):\(address):\(port)" }

    /// Reachable from other computers, not only from this Mac.
    public var isExposed: Bool {
        !(address.hasPrefix("127.") || address == "[::1]" || address == "localhost")
    }

    public var risk: PersistenceItem.Risk {
        guard let signature else { return .none }
        switch signature.trust {
        case .trusted: return .none
        case .caution: return isExposed ? .medium : .low
        case .untrusted: return isExposed ? .high : .medium
        }
    }
}

public struct NetworkReport: Sendable {
    public var ports: [ListeningPort] = []
    public var dnsServers: [String] = []
    /// Proxy servers set for the whole Mac ("HTTP proxy.example.com:8080").
    public var proxies: [String] = []
    /// Lines in /etc/hosts beyond the macOS defaults.
    public var hostsEntries: [String] = []
    /// Certificates someone marked as trusted by hand; they allow reading HTTPS traffic.
    public var trustedCertificates: [String] = []

    public init() {}
}

public enum NetworkInspector {
    public static func inspect() async -> NetworkReport {
        async let lsof = Command.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
        async let dns = Command.run("/usr/sbin/scutil", ["--dns"])
        async let proxy = Command.run("/usr/sbin/scutil", ["--proxy"])
        async let userTrust = Command.run("/usr/bin/security", ["dump-trust-settings"])
        async let adminTrust = Command.run("/usr/bin/security", ["dump-trust-settings", "-d"])

        var report = NetworkReport()
        report.ports = await parseListeningPorts(lsof?.text ?? "")
        report.dnsServers = await parseNameservers(dns?.text ?? "")
        report.proxies = await parseProxies(proxy?.text ?? "")
        report.hostsEntries = parseHosts((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "")
        report.trustedCertificates = await parseTrustSettings((userTrust?.text ?? "") + "\n" + (adminTrust?.text ?? ""))
        return report
    }

    /// Parses `lsof -F pcn` output: records start with p (pid), then c (command) and n (address) lines.
    static func parseListeningPorts(_ output: String) -> [ListeningPort] {
        var ports: [ListeningPort] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        var signatures: [String: CodeSignature] = [:]
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid):\(address):\(port)"
                guard seen.insert(key).inserted else { continue }
                let executable = ProcessInspector.executablePath(of: pid)
                var signature: CodeSignature?
                if let executable {
                    signature = signatures[executable] ?? CodeSignature.inspect(executable)
                    signatures[executable] = signature
                }
                ports.append(ListeningPort(
                    pid: pid, command: command, executable: executable,
                    address: address, port: port, signature: signature
                ))
            default: continue
            }
        }
        return ports.sorted { ($0.risk, $1.port) > ($1.risk, $0.port) }
    }

    static func parseNameservers(_ output: String) -> [String] {
        var servers: [String] = []
        for line in output.split(separator: "\n") where line.contains("nameserver[") {
            if let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
               !servers.contains(value)
            {
                servers.append(value)
            }
        }
        return servers
    }

    /// Reads `scutil --proxy` keys such as `HTTPEnable : 1` and `HTTPProxy : host`.
    static func parseProxies(_ output: String) -> [String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }
        var proxies: [String] = []
        for (kind, prefix) in [("HTTP", "HTTP"), ("HTTPS", "HTTPS"), ("SOCKS", "SOCKS")]
            where values[prefix + "Enable"] == "1"
        {
            let host = values[prefix + "Proxy"] ?? "?"
            let port = values[prefix + "Port"].map { ":" + $0 } ?? ""
            proxies.append("\(kind) \(host)\(port)")
        }
        if values["ProxyAutoConfigEnable"] == "1" {
            proxies.append("PAC \(values["ProxyAutoConfigURLString"] ?? "?")")
        }
        return proxies
    }

    static func parseHosts(_ contents: String) -> [String] {
        let defaults: Set = [
            "127.0.0.1 localhost",
            "255.255.255.255 broadcasthost",
            "::1 localhost",
            "fe80::1%lo0 localhost",
        ]
        return contents.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let normalized = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized.isEmpty || defaults.contains(normalized) ? nil : normalized
        }
    }

    /// Certificate names from `security dump-trust-settings` ("Cert 0: Name").
    static func parseTrustSettings(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("Cert "), let colon = line.firstIndex(of: ":") else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
}
