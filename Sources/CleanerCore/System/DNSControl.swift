import CryptoKit
import Foundation

/// A public DNS service that can be chosen in one press.
public struct DNSPreset: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let servers: [String]
    /// For an encrypted profile: DNS over HTTPS.
    public let httpsURL: String

    public static let all: [DNSPreset] = [
        DNSPreset(
            id: "cloudflare", name: "Cloudflare",
            servers: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
            httpsURL: "https://cloudflare-dns.com/dns-query"
        ),
        DNSPreset(
            id: "quad9", name: "Quad9",
            servers: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
            httpsURL: "https://dns.quad9.net/dns-query"
        ),
        DNSPreset(
            id: "adguard", name: "AdGuard",
            servers: ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"],
            httpsURL: "https://dns.adguard-dns.com/dns-query"
        ),
        DNSPreset(
            id: "google", name: "Google",
            servers: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
            httpsURL: "https://dns.google/dns-query"
        ),
    ]

    /// The preset these servers are, in any order, or nil for anything else.
    public static func matching(_ servers: [String]) -> DNSPreset? {
        guard !servers.isEmpty else { return nil }
        return all.first { Set($0.servers).isSuperset(of: servers) }
    }
}

/// The DNS servers of each network service, and changing them.
public enum DNSControl {
    /// Network services as System Settings lists them, without the switched-off ones.
    public static func services() async -> [String] {
        guard let output = await Command.run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return [] }
        return parseServices(output.text)
    }

    static func parseServices(_ text: String) -> [String] {
        text.split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    /// The servers set by hand for a service. Empty means automatic: whatever the network hands out.
    public static func servers(for service: String) async -> [String] {
        guard let output = await Command.run("/usr/sbin/networksetup", ["-getdnsservers", service]) else { return [] }
        return parseServers(output.text)
    }

    static func parseServers(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { isAddress($0) }
    }

    /// Sets the servers for a service, or automatic when the list is empty. These are
    /// settings for the whole Mac, so macOS asks for the password.
    public static func setServers(_ servers: [String], for service: String) async -> AdminRunner.Output {
        let list = servers.isEmpty ? "Empty" : servers.map(InstallerReceipts.shellQuoted).joined(separator: " ")
        return await AdminRunner.run(
            ["/usr/sbin/networksetup -setdnsservers \(InstallerReceipts.shellQuoted(service)) \(list)"] + flushCommands,
            prompt: String(localized: "UniMacHub needs your password to change the DNS servers.")
        )
    }

    public static let flushCommands = ["/usr/bin/dscacheutil -flushcache", "/usr/bin/killall -HUP mDNSResponder"]

    /// A configuration profile that turns on DNS over HTTPS for the whole Mac.
    ///
    /// Only the person can install a profile: macOS puts it in System Settings to be
    /// reviewed and approved, which is the point — encrypted DNS changes where every name
    /// on this Mac is looked up.
    ///
    /// Laid out like the profiles known to install on macOS. Two things matter: the scope is
    /// System, because macOS sets encrypted DNS up as a system network service (installed for
    /// one user it fails with "could not create VPN service"), and the identifiers are fixed
    /// per provider, so installing it again replaces the old one instead of adding a second.
    public static func encryptedProfile(for preset: DNSPreset) -> String {
        let addresses = preset.servers.map { "\t\t\t\t\t<string>\($0)</string>" }.joined(separator: "\n")
        let inner = stableUUID("dns.settings." + preset.id)
        let outer = stableUUID("dns.profile." + preset.id)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>PayloadContent</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>DNSSettings</key>
        \t\t\t<dict>
        \t\t\t\t<key>DNSProtocol</key>
        \t\t\t\t<string>HTTPS</string>
        \t\t\t\t<key>ServerAddresses</key>
        \t\t\t\t<array>
        \(addresses)
        \t\t\t\t</array>
        \t\t\t\t<key>ServerURL</key>
        \t\t\t\t<string>\(preset.httpsURL)</string>
        \t\t\t</dict>
        \t\t\t<key>PayloadDescription</key>
        \t\t\t<string>Looks names up through \(preset.name) over HTTPS.</string>
        \t\t\t<key>PayloadDisplayName</key>
        \t\t\t<string>\(preset.name) DNS over HTTPS</string>
        \t\t\t<key>PayloadIdentifier</key>
        \t\t\t<string>com.apple.dnsSettings.managed.\(inner.lowercased())</string>
        \t\t\t<key>PayloadType</key>
        \t\t\t<string>com.apple.dnsSettings.managed</string>
        \t\t\t<key>PayloadUUID</key>
        \t\t\t<string>\(inner)</string>
        \t\t\t<key>PayloadVersion</key>
        \t\t\t<integer>1</integer>
        \t\t\t<key>ProhibitDisablement</key>
        \t\t\t<false/>
        \t\t</dict>
        \t</array>
        \t<key>PayloadDescription</key>
        \t<string>Encrypted DNS through \(preset.name), prepared by UniMacHub. Remove it here to go back to ordinary DNS.</string>
        \t<key>PayloadDisplayName</key>
        \t<string>\(preset.name) encrypted DNS (UniMacHub)</string>
        \t<key>PayloadIdentifier</key>
        \t<string>com.fixerhack.unimachub.dns.\(preset.id)</string>
        \t<key>PayloadRemovalDisallowed</key>
        \t<false/>
        \t<key>PayloadScope</key>
        \t<string>System</string>
        \t<key>PayloadType</key>
        \t<string>Configuration</string>
        \t<key>PayloadUUID</key>
        \t<string>\(outer)</string>
        \t<key>PayloadVersion</key>
        \t<integer>1</integer>
        </dict>
        </plist>
        """
    }

    /// The same UUID every time for the same name.
    static func stableUUID(_ name: String) -> String {
        var hash = Array(Insecure.SHA1.hash(data: Data(("com.fixerhack.unimachub." + name).utf8)).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50  // version 5
        hash[8] = (hash[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15])).uuidString
    }

    /// Whether this is an IPv4 or IPv6 address, as macOS itself parses one.
    public static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }
}

/// A name pointed somewhere else in /etc/hosts for a while.
public struct HostsOverride: Sendable, Hashable, Identifiable {
    public let hostname: String
    public let address: String
    /// When it stops applying; nil keeps it until removed.
    public let until: Date?

    public var id: String { hostname }

    public init(hostname: String, address: String, until: Date?) {
        self.hostname = hostname.lowercased()
        self.address = address
        self.until = until
    }

    public func hasExpired(at date: Date = .now) -> Bool {
        until.map { $0 <= date } ?? false
    }

    /// A name made of letters, digits, hyphens and dots, as a hostname must be.
    public static func isValidHostname(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.count <= 253, !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// UniMacHub's lines in /etc/hosts, kept between its markers like every file it writes into.
public enum HostsFile {
    public static let path = "/etc/hosts"
    static let untilPrefix = "# until "

    public static func overrides(in text: String) -> [HostsOverride] {
        ManagedBlock.read(in: text).compactMap(parse)
    }

    public static func overrides() -> [HostsOverride] {
        overrides(in: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
    }

    static func line(for override: HostsOverride) -> String {
        var line = "\(override.address) \(override.hostname)"
        if let until = override.until {
            line += " " + untilPrefix + until.formatted(.iso8601)
        }
        return line
    }

    static func parse(_ line: String) -> HostsOverride? {
        let parts = line.components(separatedBy: untilPrefix)
        let fields = parts[0].split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, DNSControl.isAddress(String(fields[0])) else { return nil }
        let until = parts.count > 1 ? try? Date(parts[1].trimmingCharacters(in: .whitespaces), strategy: .iso8601) : nil
        return HostsOverride(hostname: String(fields[1]), address: String(fields[0]), until: until)
    }

    /// The whole file with UniMacHub's block replaced by these overrides; everything else
    /// in it stays exactly as it was.
    public static func updated(_ text: String, with overrides: [HostsOverride]) -> String {
        ManagedBlock.replacing(overrides.map(line(for:)), in: text)
    }

    /// Writes the overrides into /etc/hosts. The file belongs to the system, so macOS asks
    /// for the password; the new text is staged in a file of our own and copied over.
    public static func apply(
        _ overrides: [HostsOverride],
        prompt: String = String(localized: "UniMacHub needs your password to change /etc/hosts.")
    ) async -> AdminRunner.Output {
        let current = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let staged = FileManager.default.temporaryDirectory.appending(path: "unimachub-hosts-\(UUID().uuidString)")
        do {
            try updated(current, with: overrides).write(to: staged, atomically: true, encoding: .utf8)
        } catch {
            return AdminRunner.Output(succeeded: false, text: error.localizedDescription, wasCancelled: false)
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        return await AdminRunner.run(
            ["/bin/cp \(InstallerReceipts.shellQuoted(staged.path)) \(path)", "/bin/chmod 644 \(path)"]
                + DNSControl.flushCommands,
            prompt: prompt
        )
    }
}
