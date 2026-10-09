import Foundation
import IOKit

/// One reading from the chip that watches the hardware.
public struct SensorReading: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case temperature, fan, power
    }

    /// The four-character name the controller knows it by, such as `TC0P`.
    public let key: String
    public let kind: Kind
    /// What it measures, in words, when the key is a known one.
    public let label: String?
    /// Degrees Celsius, revolutions per minute, or watts.
    public let value: Double

    public var id: String { key }
}

/// Everything the hardware reports about itself: temperatures, fans and power draw.
///
/// The numbers come from the System Management Controller, which macOS talks to through the
/// AppleSMC driver. Nothing here writes to it: MacUtil only reads.
///
/// The shape of the request the driver expects was worked out from Vorssaint
/// (https://github.com/vorssaint/vorssaint-utils), which is under the same licence as MacUtil.
public enum SystemSensors {
    /// Reads every sensor worth showing. Opening the connection and listing keys takes a moment,
    /// so the keys are found once and kept.
    public static func read() -> [SensorReading] {
        shared.withLock { client in client?.readAll() ?? [] }
    }

    /// The warmest temperature the Mac reports, which is the one worth watching.
    public static func hottest() -> SensorReading? {
        read().filter { $0.kind == .temperature }.max { $0.value < $1.value }
    }

    private static let shared = Locked<SMCClient?>(SMCClient())
}

/// Talks to the AppleSMC driver. Read-only by design.
final class SMCClient: @unchecked Sendable {
    struct Key: Sendable, Hashable {
        let code: UInt32
        let name: String
        let size: UInt32
        let type: String
    }

    private var connection: io_connect_t = 0
    private let sensors: [Key]

    /// Commands of the SMC user client.
    private static let selector: UInt32 = 2
    private static let readKey: UInt8 = 5
    private static let keyByIndex: UInt8 = 8
    private static let keyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }

        var found: [Key] = []
        var probe = SMCParameters()
        probe.key = SMCClient.code(of: "#KEY")
        probe.keyInfo.size = 4
        probe.data8 = SMCClient.readKey
        guard let answer = SMCClient.send(&probe, to: connection), answer.result == 0 else { return nil }
        let count = withUnsafeBytes(of: answer.bytes) { raw in
            Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
        }

        for index in 0 ..< count {
            var byIndex = SMCParameters()
            byIndex.data8 = SMCClient.keyByIndex
            byIndex.data32 = UInt32(index)
            guard let named = SMCClient.send(&byIndex, to: connection), named.result == 0 else { continue }
            let name = SMCClient.name(of: named.key)
            guard SMCClient.kind(of: name) != nil else { continue }

            var info = SMCParameters()
            info.key = named.key
            info.data8 = SMCClient.keyInfo
            guard let described = SMCClient.send(&info, to: connection), described.result == 0 else { continue }
            found.append(Key(
                code: named.key, name: name,
                size: described.keyInfo.size, type: SMCClient.name(of: described.keyInfo.type)
            ))
        }
        sensors = found
        guard !sensors.isEmpty else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func readAll() -> [SensorReading] {
        sensors.compactMap { key in
            guard let kind = SMCClient.kind(of: key.name), let value = read(key) else { return nil }
            // A sensor that is not fitted reads as zero or as something impossible.
            switch kind {
            case .temperature where !(1 ... 125).contains(value): return nil
            case .fan where !(1 ... 12000).contains(value): return nil
            case .power where !(0.01 ... 1000).contains(value): return nil
            default: break
            }
            return SensorReading(key: key.name, kind: kind, label: SMCClient.labels[key.name], value: value)
        }
    }

    private func read(_ key: Key) -> Double? {
        guard key.size > 0, key.size <= 32 else { return nil }
        var request = SMCParameters()
        request.key = key.code
        request.keyInfo.size = key.size
        request.data8 = SMCClient.readKey
        guard let answer = SMCClient.send(&request, to: connection), answer.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: answer.bytes) { Array($0.prefix(Int(key.size))) }
        return SMCClient.decode(bytes, type: key.type)
    }

    // MARK: - Reading the wire format

    /// The controller answers in a handful of number formats, fixed point among them.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "ui8 ", "si8 ":
            return bytes.first.map(Double.init)
        case "ui16", "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }

    /// Which keys are worth reading, judged by the letter they start with.
    static func kind(of name: String) -> SensorReading.Kind? {
        guard name.count == 4 else { return nil }
        switch name.first {
        case "T": return .temperature
        // Fans report speed as F0Ac, F1Ac and so on; the other F keys are settings.
        case "F": return name.hasSuffix("Ac") ? .fan : nil
        case "P": return .power
        default: return nil
        }
    }

    /// Names for the keys worth putting in front of a person.
    static let labels: [String: String] = [
        "TC0P": String(localized: "Processor"),
        "TC0D": String(localized: "Processor"),
        "TG0P": String(localized: "Graphics"),
        "TG0D": String(localized: "Graphics"),
        "Tp09": String(localized: "Performance cores"),
        "Tp0T": String(localized: "Performance cores"),
        "Te05": String(localized: "Efficiency cores"),
        "Tg05": String(localized: "Graphics"),
        "TB0T": String(localized: "Battery"),
        "TB1T": String(localized: "Battery"),
        "Ts0S": String(localized: "Case"),
        "TW0P": String(localized: "Wi-Fi"),
        "TH0x": String(localized: "Drive"),
        "F0Ac": String(localized: "Fan"),
        "F1Ac": String(localized: "Second fan"),
        "PSTR": String(localized: "Whole machine"),
        "PPBR": String(localized: "Battery"),
        "PCPC": String(localized: "Processor"),
        "PGPC": String(localized: "Graphics"),
    ]

    static func code(of name: String) -> UInt32 {
        name.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func name(of code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private static func send(_ input: inout SMCParameters, to connection: io_connect_t) -> SMCParameters? {
        var output = SMCParameters()
        var size = MemoryLayout<SMCParameters>.stride
        let result = IOConnectCallStructMethod(
            connection, selector, &input, MemoryLayout<SMCParameters>.stride, &output, &size
        )
        return result == kIOReturnSuccess ? output : nil
    }
}

/// The fixed layout the AppleSMC driver expects, 80 bytes long.
private struct SMCParameters {
    var key: UInt32 = 0
    var version = Version()
    var limits = PowerLimits()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )

    struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PowerLimits {
        var version: UInt16 = 0, length: UInt16 = 0
        var processor: UInt32 = 0, graphics: UInt32 = 0, memory: UInt32 = 0
    }

    struct KeyInfo {
        var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0
    }
}
