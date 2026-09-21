import Darwin
import Foundation

public struct RunningProcess: Sendable, Identifiable, Hashable {
    public let pid: Int32
    public let name: String
    public let user: String
    /// Share of one CPU core; can exceed 100 on multi-core Macs.
    public let cpu: Double
    /// Resident memory in bytes.
    public let memory: Int64
    public let path: String

    public var id: Int32 { pid }
    public var isOwnedByUser: Bool { user == NSUserName() }
}

public struct MemoryStats: Sendable, Equatable {
    public let total: Int64
    public let used: Int64
    public let wired: Int64
    public let compressed: Int64
    /// Files kept in memory that macOS can drop at any moment.
    public let cached: Int64

    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public enum ProcessMonitor {
    /// Every process with its CPU and memory use, from `ps`.
    public static func processes() async -> [RunningProcess] {
        let output = await Command.run("/bin/ps", ["-axo", "pid=,%cpu=,rss=,user=,comm="])
        return parse(output?.text ?? "")
    }

    static func parse(_ output: String) -> [RunningProcess] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let cpu = Double(fields[1]),
                  let rss = Int64(fields[2])
            else { return nil }
            let path = String(fields[4])
            return RunningProcess(
                pid: pid, name: (path as NSString).lastPathComponent, user: String(fields[3]),
                cpu: cpu, memory: rss * 1024, path: path
            )
        }
    }

    public static func memory() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(getpagesize())
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let cached = Int64(stats.external_page_count + stats.purgeable_count) * page
        // Same idea as Activity Monitor: app memory + wired + compressed.
        let app = Int64(stats.internal_page_count) * page - Int64(stats.purgeable_count) * page
        return MemoryStats(
            total: total, used: min(total, max(0, app) + wired + compressed),
            wired: wired, compressed: compressed, cached: cached
        )
    }

    /// Asks the process to quit, or kills it when `force` is set. Only the
    /// user's own processes can be signalled without administrator rights.
    public static func terminate(_ pid: Int32, force: Bool) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}

/// Starts or stops launch agents for this user without administrator rights.
public enum LaunchControl {
    public static func setEnabled(_ enabled: Bool, label: String, plist: String?) async -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let result = await Command.run("/bin/launchctl", [enabled ? "enable" : "disable", target])
        if enabled, let plist {
            _ = await Command.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
        } else if !enabled {
            _ = await Command.run("/bin/launchctl", ["bootout", target])
        }
        return result?.status == 0
    }

    /// Daemons run in the system domain and need administrator rights.
    public static func setDaemonEnabled(_ enabled: Bool, label: String, plist: String) async -> AdminRunner.Output {
        let quoted = "'" + plist.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let commands = enabled
            ? ["launchctl enable system/\(label)", "launchctl bootstrap system \(quoted) 2>/dev/null ; true"]
            : ["launchctl disable system/\(label)", "launchctl bootout system/\(label) 2>/dev/null ; true"]
        return await AdminRunner.run(
            commands,
            prompt: String(localized: "MacUtil needs your password to change a background service.")
        )
    }
}
