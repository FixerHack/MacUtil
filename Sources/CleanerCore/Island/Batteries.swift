import Foundation
import IOKit
import IOKit.ps

/// The charge of this Mac and of what is paired with it.
public struct DeviceBattery: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case mac, keyboard, mouse, trackpad, headphones, other

        public var symbol: String {
            switch self {
            case .mac: "laptopcomputer"
            case .keyboard: "keyboard"
            case .mouse: "computermouse"
            case .trackpad: "rectangle.and.hand.point.up.left"
            case .headphones: "airpods"
            case .other: "dot.radiowaves.left.and.right"
            }
        }
    }

    public let name: String
    public let kind: Kind
    /// 0 to 100; for earbuds, the lower of the two.
    public let level: Int
    public let isCharging: Bool
    /// Earbuds report each side and the case.
    public let left: Int?
    public let right: Int?
    public let caseLevel: Int?

    public var id: String { name }

    public init(name: String, kind: Kind, level: Int, isCharging: Bool = false, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.name = name
        self.kind = kind
        self.level = level
        self.isCharging = isCharging
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }
}

public enum Batteries {
    /// The built-in battery; nil on a Mac without one.
    public static func mac() -> DeviceBattery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return DeviceBattery(
                name: Host.current().localizedName ?? "Mac", kind: .mac,
                level: current * 100 / maximum, isCharging: charging || onPower
            )
        }
        return nil
    }

    /// Bluetooth keyboards, mice and trackpads, which publish their charge in the I/O registry.
    public static func accessories() -> [DeviceBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [DeviceBattery] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let level = property("BatteryPercent") as? Int,
                  let name = property("Product") as? String,
                  !found.contains(where: { $0.name == name })
            else { continue }
            let charging = (property("BatteryStatusFlags") as? Int).map { $0 & 0x3 != 0 } ?? false
            found.append(DeviceBattery(name: name, kind: kind(ofProduct: name), level: level, isCharging: charging))
        }
        return found
    }

    static func kind(ofProduct name: String) -> DeviceBattery.Kind {
        let lower = name.lowercased()
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("mouse") { return .mouse }
        return .other
    }

    /// Earbuds and headphones, as `system_profiler SPBluetoothDataType -json` reports them.
    /// That is the only public place their charge shows up, and it is slow, so the island asks
    /// only now and then.
    public static func headphones(fromSystemProfiler json: Data) -> [DeviceBattery] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sections = object["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        var found: [DeviceBattery] = []
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let device = value as? [String: Any] else { continue }
                    let left = percent(device["device_batteryLevelLeft"])
                    let right = percent(device["device_batteryLevelRight"])
                    let main = percent(device["device_batteryLevelMain"])
                    let levels = [left, right, main].compactMap { $0 }
                    guard let level = levels.min() else { continue }
                    let minor = (device["device_minorType"] as? String ?? "").lowercased()
                    let isHeadphones = left != nil || minor.contains("headphones") || minor.contains("headset")
                    // Keyboards and mice come from the I/O registry already.
                    guard isHeadphones else { continue }
                    found.append(DeviceBattery(
                        name: name, kind: .headphones, level: level,
                        left: left, right: right, caseLevel: percent(device["device_batteryLevelCase"])
                    ))
                }
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// "80%" or 80.
    static func percent(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
    }
}
