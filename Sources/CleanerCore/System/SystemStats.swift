import Darwin
import Foundation
import IOKit.ps

public struct BatteryStatus: Sendable, Equatable {
    public let percent: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
}

/// Point-in-time readings for the menu bar monitor. CPU and network are rates,
/// so they are computed from the difference to the previous sample.
public final class SystemStats: @unchecked Sendable {
    public struct Sample: Sendable, Equatable {
        /// 0…1 across all cores.
        public var cpu: Double = 0
        public var memory: MemoryStats?
        public var disk: VolumeInfo?
        /// Bytes per second.
        public var download: Int64 = 0
        public var upload: Int64 = 0
        public var battery: BatteryStatus?

        public init() {}
    }

    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var lastNetwork: (received: UInt64, sent: UInt64, time: ContinuousClock.Instant)?
    private let lock = NSLock()

    public init() {}

    public func sample() -> Sample {
        lock.lock()
        defer { lock.unlock() }
        var sample = Sample()
        sample.cpu = cpuUsage()
        sample.memory = ProcessMonitor.memory()
        sample.disk = try? VolumeInfo.forVolume()
        (sample.download, sample.upload) = networkRates()
        sample.battery = Self.battery()
        return sample
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastCPU = (busy, total) }
        guard let last = lastCPU, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private func networkRates() -> (Int64, Int64) {
        let (received, sent) = Self.interfaceBytes()
        let now = ContinuousClock.now
        defer { lastNetwork = (received, sent, now) }
        guard let last = lastNetwork else { return (0, 0) }
        let seconds = Double((now - last.time).components.seconds) + Double((now - last.time).components.attoseconds) /
            1e18
        guard seconds > 0 else { return (0, 0) }
        let down = received >= last.received ? Double(received - last.received) / seconds : 0
        let up = sent >= last.sent ? Double(sent - last.sent) / seconds : 0
        return (Int64(down), Int64(up))
    }

    /// Total bytes through physical interfaces (en*), from getifaddrs.
    static func interfaceBytes() -> (UInt64, UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            let name = String(cString: entry.pointee.ifa_name)
            if name.hasPrefix("en"), let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            current = entry.pointee.ifa_next
        }
        return (received, sent)
    }

    public static func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return BatteryStatus(
                percent: current * 100 / maximum,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }
}
