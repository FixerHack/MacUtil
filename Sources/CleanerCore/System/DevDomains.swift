import Foundation
import Network

/// Names like `app.test` that point at this Mac, for running things in development.
///
/// macOS can send the questions for one domain to a resolver of its own choosing: a file in
/// `/etc/resolver` named after the domain says where. The answer comes from a small resolver
/// UniMacHub runs as a login agent on a high port, so it needs no root while running and
/// knows only these domains. Nothing else about how this Mac looks names up changes.
public enum DevDomains {
    public static let port: UInt16 = 53530
    public static let agentLabel = "com.fixerhack.unimachub.devdns"
    static let marker = "# UniMacHub development domains"
    public static let resolverFolder = "/etc/resolver"

    // MARK: - Resolver files

    /// The file for one domain. The first line marks it as ours, so only ours are ever removed.
    public static func resolverFile(port: UInt16 = port) -> String {
        "\(marker)\nnameserver 127.0.0.1\nport \(port)\n"
    }

    /// Domains with a resolver file of ours in the folder.
    public static func installedDomains(in folder: String = resolverFolder) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { name in
            let text = (try? String(contentsOfFile: folder + "/" + name, encoding: .utf8)) ?? ""
            return text.hasPrefix(marker)
        }.sorted()
    }

    /// A domain as a resolver file can be named: one label, letters, digits and hyphens.
    public static func isValidDomain(_ domain: String) -> Bool {
        HostsOverride.isValidHostname(domain) && !domain.contains(".")
            // These already mean something and must keep meaning it.
            && !["local", "localhost", "arpa", "com", "net", "org"].contains(domain)
    }

    /// Writes resolver files for these domains and removes ours for any other. One password.
    public static func install(_ domains: [String]) async -> AdminRunner.Output {
        let staged = FileManager.default.temporaryDirectory.appending(path: "unimachub-resolver-\(UUID().uuidString)")
        do {
            try resolverFile().write(to: staged, atomically: true, encoding: .utf8)
        } catch {
            return AdminRunner.Output(succeeded: false, text: error.localizedDescription, wasCancelled: false)
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        let stale = installedDomains().filter { !domains.contains($0) }
        var commands = ["/bin/mkdir -p \(resolverFolder)"]
        commands += domains.map {
            "/bin/cp \(InstallerReceipts.shellQuoted(staged.path)) \(InstallerReceipts.shellQuoted(resolverFolder + "/" + $0))"
        }
        commands += domains.map { "/bin/chmod 644 \(InstallerReceipts.shellQuoted(resolverFolder + "/" + $0))" }
        commands += stale.map { "/bin/rm -f \(InstallerReceipts.shellQuoted(resolverFolder + "/" + $0))" }
        commands += DNSControl.flushCommands
        return await AdminRunner.run(
            commands, prompt: String(localized: "UniMacHub needs your password to set up development domains.")
        )
    }

    // MARK: - The login agent

    public static var agentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
    }

    /// The agent runs the command-line tool inside the app, which answers for these domains.
    public static func agentPlist(tool: String, domains: [String], port: UInt16 = port) -> [String: Any] {
        [
            "Label": agentLabel,
            "ProgramArguments": [tool, "dns-serve", "--port", String(port)] + domains.flatMap { ["--domain", $0] },
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
        ]
    }

    /// Starts (or restarts) the agent for these domains, or stops it when there are none.
    public static func startAgent(tool: String, domains: [String]) async -> Bool {
        await stopAgent()
        guard !domains.isEmpty else { return true }
        let plist = agentPlist(tool: tool, domains: domains)
        do {
            try FileManager.default.createDirectory(
                atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(filePath: agentPath))
        } catch {
            return false
        }
        let output = await Command.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPath])
        return output?.status == 0
    }

    public static func stopAgent() async {
        _ = await Command.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(atPath: agentPath)
    }

    /// Asks the resolver for a name under the domain and checks it answers this Mac.
    public static func isAnswering(domain: String, port: UInt16 = port) async -> Bool {
        await DevDNS.lookup("unimachub-check.\(domain)", port: port) == "127.0.0.1"
    }
}

/// Just enough of the DNS wire format to answer "this name is 127.0.0.1".
public enum DevDNS {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28

    /// The reply to one query: this Mac's address for any name under the domains, nothing
    /// for other record types, and a refusal for names outside them.
    public static func answer(to query: Data, domains: [String]) -> Data? {
        let bytes = [UInt8](query)
        guard bytes.count >= 12 else { return nil }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        guard questions == 1, let (name, end) = readName(bytes, at: 12), end + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[end]) << 8 | UInt16(bytes[end + 1])
        let question = Array(bytes[12 ..< end + 4])

        let lowered = name.lowercased()
        let ours = domains.contains { lowered == $0 || lowered.hasSuffix("." + $0) }
        var answer: [UInt8] = []
        if ours {
            if type == typeA {
                answer = record(type: typeA, data: [127, 0, 0, 1])
            } else if type == typeAAAA {
                answer = record(type: typeAAAA, data: Array(repeating: 0, count: 15) + [1])
            }
        }

        // Response, the query's opcode and recursion-desired bit, authoritative.
        let flagsHigh: UInt8 = 0x80 | (bytes[2] & 0x79) | 0x04
        let rcode: UInt8 = ours ? 0 : 5
        var reply: [UInt8] = [bytes[0], bytes[1], flagsHigh, rcode, 0, 1, 0, answer.isEmpty ? 0 : 1, 0, 0, 0, 0]
        reply += question
        reply += answer
        return Data(reply)
    }

    /// An answer record naming the question by pointer, with a short time to live so a
    /// change of mind takes effect at once.
    static func record(type: UInt16, data: [UInt8]) -> [UInt8] {
        [0xC0, 0x0C, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0, 5, 0, UInt8(data.count)] + data
    }

    static func readName(_ bytes: [UInt8], at start: Int) -> (String, Int)? {
        var labels: [String] = []
        var position = start
        while position < bytes.count {
            let length = Int(bytes[position])
            if length == 0 { return (labels.joined(separator: "."), position + 1) }
            // Compression never appears in a question; anything else is not a query we answer.
            guard length < 64, position + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(position + 1) ... (position + length)], as: UTF8.self))
            position += 1 + length
        }
        return nil
    }

    public static func query(_ name: String, type: UInt16 = typeA, id: UInt16 = 0x5544) -> Data {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
        }
        bytes += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return Data(bytes)
    }

    /// The first IPv4 address in a reply, as text.
    static func address(in reply: Data) -> String? {
        let bytes = [UInt8](reply)
        guard bytes.count >= 12, bytes[3] & 0x0F == 0, (Int(bytes[6]) << 8 | Int(bytes[7])) > 0,
              let (_, end) = readName(bytes, at: 12)
        else { return nil }
        let record = end + 4
        guard record + 16 <= bytes.count, bytes[record + 2] == 0, bytes[record + 3] == 1 else { return nil }
        return bytes[(record + 12) ..< (record + 16)].map(String.init).joined(separator: ".")
    }

    /// Asks the resolver on this Mac directly, past the system's cache.
    public static func lookup(_ name: String, port: UInt16, timeout: Duration = .seconds(2)) async -> String? {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp
        )
        let reply: Data? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            connection.stateUpdateHandler = { state in
                if case .failed = state { once.resume(nil) }
            }
            connection.start(queue: .global())
            connection.send(content: query(name), completion: .contentProcessed { error in
                if error != nil { once.resume(nil) }
            })
            connection.receiveMessage { data, _, _, _ in once.resume(data) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                once.resume(nil)
            }
        }
        connection.cancel()
        return reply.flatMap(address(in:))
    }

    /// Hands a continuation its value once, whichever callback gets there first.
    final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<Data?, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<Data?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Data?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// The resolver itself: answers on the loopback address only, so nothing on the network sees it.
public final class DevDNSServer: @unchecked Sendable {
    private let listener: NWListener
    private let domains: [String]

    public init(port: UInt16, domains: [String]) throws {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.domains = domains.map { $0.lowercased() }
    }

    public func start() {
        let domains = domains
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receive() {
                connection.receiveMessage { data, _, _, error in
                    if let data, let reply = DevDNS.answer(to: data, domains: domains) {
                        connection.send(content: reply, completion: .idempotent)
                    }
                    if error == nil { receive() } else { connection.cancel() }
                }
            }
            receive()
        }
        listener.start(queue: .global())
    }

    public func stop() {
        listener.cancel()
    }
}
