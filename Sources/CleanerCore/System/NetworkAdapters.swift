import Darwin
import Foundation

/// One network interface of this Mac, with what macOS calls it and what it carries.
public struct NetworkAdapter: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case wifi, ethernet, tether, bridge, vpn, loopback, other
    }

    /// The BSD name: en0, utun3, bridge0.
    public let device: String
    /// What System Settings calls it, when it is a service there. Otherwise the device name.
    public let name: String
    public let kind: Kind
    /// The interface is switched on.
    public let isUp: Bool
    /// It is switched on and has a link.
    public let isRunning: Bool
    public let addresses: [String]
    public let mac: String?
    /// Megabits per second the link negotiated, when the driver reports one.
    public let linkSpeed: Int?
    public let received: UInt64
    public let sent: UInt64
    /// Position in the order macOS tries services, if it is one. Lower goes first.
    public let order: Int?
    /// Traffic with nowhere better to go leaves through this one.
    public let carriesDefaultRoute: Bool

    public var id: String { device }

    /// Switched on, linked and addressed: actually usable.
    public var isActive: Bool { isRunning && !addresses.isEmpty }
}

public struct NetworkSnapshot: Sendable {
    public var adapters: [NetworkAdapter] = []
    public var dnsServers: [String] = []
    public var defaultDevice: String?

    public init(adapters: [NetworkAdapter] = [], dnsServers: [String] = [], defaultDevice: String? = nil) {
        self.adapters = adapters
        self.dnsServers = dnsServers
        self.defaultDevice = defaultDevice
    }

    /// Only what could carry traffic, in the order macOS would pick them.
    public var usable: [NetworkAdapter] {
        adapters
            .filter { $0.isActive && $0.kind != .loopback }
            .sorted { ($0.order ?? .max, $0.device) < ($1.order ?? .max, $1.device) }
    }
}

/// Reads the network interfaces and how macOS ranks them.
///
/// This is the ground floor for anything that treats adapters as a set rather than one at a
/// time: which ones exist, which carry traffic, and which macOS would reach for first.
public enum NetworkAdapters {
    public static func load() async -> NetworkSnapshot {
        async let order = serviceOrder()
        async let defaultDevice = defaultRouteDevice()
        async let speeds = linkSpeeds()

        let services = await order
        let interfaces = readInterfaces()
        let defaultOne = await defaultDevice
        let media = await speeds

        var adapters: [NetworkAdapter] = []
        for interface in interfaces.values.sorted(by: { $0.device < $1.device }) {
            let service = services[interface.device]
            adapters.append(NetworkAdapter(
                device: interface.device,
                name: service?.name ?? interface.device,
                kind: kind(of: interface.device, service: service?.name),
                isUp: interface.isUp,
                isRunning: interface.isRunning,
                addresses: interface.addresses,
                mac: interface.mac,
                linkSpeed: media[interface.device],
                received: interface.received,
                sent: interface.sent,
                order: service?.order,
                carriesDefaultRoute: interface.device == defaultOne
            ))
        }
        return NetworkSnapshot(
            adapters: adapters,
            dnsServers: await dnsServers(),
            defaultDevice: defaultOne
        )
    }

    // MARK: - Interfaces

    struct Interface {
        let device: String
        var isUp = false
        var isRunning = false
        var addresses: [String] = []
        var mac: String?
        var received: UInt64 = 0
        var sent: UInt64 = 0
    }

    /// Everything `getifaddrs` knows: addresses, hardware address, flags and byte counters.
    static func readInterfaces() -> [String: Interface] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [:] }
        defer { freeifaddrs(pointer) }

        var found: [String: Interface] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let device = String(cString: entry.pointee.ifa_name)
            var interface = found[device] ?? Interface(device: device)
            let flags = Int32(entry.pointee.ifa_flags)
            interface.isUp = flags & IFF_UP != 0
            interface.isRunning = interface.isUp && flags & IFF_RUNNING != 0

            if let address = entry.pointee.ifa_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET, AF_INET6:
                    if let text = Self.text(of: address), !interface.addresses.contains(text) {
                        interface.addresses.append(text)
                    }
                case AF_LINK:
                    if let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        interface.received = UInt64(data.pointee.ifi_ibytes)
                        interface.sent = UInt64(data.pointee.ifi_obytes)
                    }
                    interface.mac = hardwareAddress(address)
                default:
                    break
                }
            }
            found[device] = interface
        }
        return found
    }

    /// The numeric address, without the scope suffix IPv6 link-local addresses carry.
    static func text(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        let text = String(cString: host)
        return text.split(separator: "%").first.map(String.init) ?? text
    }

    /// Where the name and the hardware address begin inside a `sockaddr_dl`:
    /// after sdl_len, sdl_family, sdl_index, sdl_type, sdl_nlen, sdl_alen and sdl_slen.
    static let linkDataOffset = 8

    /// Reads the six bytes of a link-level address as "a1:b2:…".
    ///
    /// `sdl_data` is declared as twelve bytes, but the record really runs to `sa_len` and
    /// holds the interface name first, the address after it. Reading through the declared
    /// field walks off the end as soon as the name is long — "bridge0" and six bytes of
    /// address already make thirteen.
    static func hardwareAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let total = Int(address.pointee.sa_len)
        return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
            let nameLength = Int(link.pointee.sdl_nlen)
            guard link.pointee.sdl_alen == 6, linkDataOffset + nameLength + 6 <= total else { return nil }
            let bytes = UnsafeRawPointer(link)
                .advanced(by: linkDataOffset + nameLength)
                .assumingMemoryBound(to: UInt8.self)
            return (0 ..< 6).map { String(format: "%02x", bytes[$0]) }.joined(separator: ":")
        }
    }

    // MARK: - What macOS calls them

    struct Service {
        let name: String
        let order: Int
    }

    /// `networksetup` lists the services in the order macOS tries them, with their devices.
    static func serviceOrder() async -> [String: Service] {
        guard let output = await Command.run(
            "/usr/sbin/networksetup", ["-listnetworkserviceorder"], timeout: .seconds(20)
        ) else { return [:] }
        return parseServiceOrder(output.text)
    }

    static func parseServiceOrder(_ text: String) -> [String: Service] {
        var services: [String: Service] = [:]
        var pending: (name: String, order: Int)?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("("), trimmed.contains("Hardware Port:") {
                // "(Hardware Port: Wi-Fi, Device: en0)"
                guard let device = trimmed
                    .components(separatedBy: "Device:").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " )")),
                    !device.isEmpty, let entry = pending
                else { continue }
                services[device] = Service(name: entry.name, order: entry.order)
                pending = nil
            } else if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")") {
                // "(5) Wi-Fi", or "(*) Wi-Fi" when the service is switched off.
                let marker = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
                let name = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                // A disabled service keeps its place in the list but has no rank.
                pending = (name: name, order: Int(marker) ?? Int.max)
            }
        }
        return services
    }

    static func kind(of device: String, service: String?) -> NetworkAdapter.Kind {
        let label = (service ?? "").lowercased()
        if device == "lo0" { return .loopback }
        if device.hasPrefix("utun") || device.hasPrefix("ipsec") || device.hasPrefix("ppp") { return .vpn }
        if device.hasPrefix("bridge") { return .bridge }
        if label.contains("wi-fi") || label.contains("airport") || device.hasPrefix("awdl") { return .wifi }
        // A phone shared over USB and a USB adapter both arrive as Ethernet; the name tells them apart.
        if label.contains("iphone") || label.contains("ipad") || label.contains("usb") { return .tether }
        if device.hasPrefix("en") { return .ethernet }
        return .other
    }

    // MARK: - Routing and names

    static func defaultRouteDevice() async -> String? {
        guard let output = await Command.run("/sbin/route", ["-n", "get", "default"], timeout: .seconds(10))
        else { return nil }
        return parseDefaultRoute(output.text)
    }

    static func parseDefaultRoute(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func dnsServers() async -> [String] {
        guard let output = await Command.run("/usr/sbin/scutil", ["--dns"], timeout: .seconds(15))
        else { return [] }
        return parseDNS(output.text)
    }

    static func parseDNS(_ text: String) -> [String] {
        var servers: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver["), let range = trimmed.range(of: "] : ") else { continue }
            let address = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !address.isEmpty, !servers.contains(address) { servers.append(address) }
        }
        return servers
    }

    /// Link speed in megabits per second, where the driver says.
    static func linkSpeeds() async -> [String: Int] {
        guard let output = await Command.run("/sbin/ifconfig", ["-a"], timeout: .seconds(15))
        else { return [:] }
        return parseLinkSpeeds(output.text)
    }

    static func parseLinkSpeeds(_ text: String) -> [String: Int] {
        var speeds: [String: Int] = [:]
        var device: String?
        for line in text.split(separator: "\n") {
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                device = String(line[line.startIndex ..< colon])
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("media:"), let device else { continue }
            // "media: autoselect (1000baseT <full-duplex>)" — the number before "base" is Mbit/s.
            guard let range = trimmed.range(of: "base") else { continue }
            let digits = String(trimmed[trimmed.startIndex ..< range.lowerBound].reversed()
                .prefix { $0.isNumber }.reversed())
            if let speed = Int(digits) { speeds[device] = speed }
        }
        return speeds
    }
}
