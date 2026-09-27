import Darwin
import Foundation

/// One process as the task manager shows it.
public struct TaskProcess: Sendable, Identifiable, Hashable {
    public enum State: String, Sendable {
        case running, sleeping, stopped, zombie, idle, unknown

        init(psState: Substring) {
            self = switch psState.first {
            case "R": .running
            case "S": .sleeping
            case "I": .idle
            case "T": .stopped
            case "Z": .zombie
            default: .unknown
            }
        }
    }

    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let path: String
    public let user: String
    public let state: State
    /// Share of one core; 800 means eight cores are busy with it.
    public let cpu: Double
    /// What Activity Monitor calls Memory: the process's physical footprint.
    public let memory: Int64
    public let threads: Int
    /// Scheduling priority; 0 is normal, higher means the Mac runs it later.
    public let niceness: Int32
    public let startedAt: Date?
    /// Bytes read and written since the process started.
    public let diskRead: Int64
    public let diskWritten: Int64
    /// Wakeups the process caused; the reason apps drain a battery while idle.
    public let wakeups: Int64

    public var id: Int32 { pid }
    public var isOwnedByUser: Bool { user == NSUserName() }
    public var isApp: Bool { path.contains(".app/Contents/MacOS/") }

    /// The bundle of an app process, for its icon and real name.
    public var appBundlePath: String? {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(path[path.startIndex ..< range.lowerBound]) + ".app"
    }
}

/// Load of the whole Mac at one moment.
public struct SystemLoad: Sendable, Equatable {
    public var cores: [Double] = []
    public var memory: MemoryStats?
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double] = []
    public var uptime: TimeInterval = 0
    public var processCount = 0
    public var threadCount = 0
    /// Bytes per second across every process, measured between samples.
    public var diskRead: Double = 0
    public var diskWritten: Double = 0

    public var cpu: Double {
        cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
    }

    public init() {}

    /// How hard memory is squeezed, the way Activity Monitor's pressure graph reads.
    public var memoryPressure: Double {
        guard let memory, memory.total > 0 else { return 0 }
        return Double(memory.wired + memory.compressed) / Double(memory.total)
    }
}

/// Samples every process and the machine's load, repeatedly.
///
/// CPU percentages come from `ps`, which reports an average over the process's life. Everything
/// else comes from the kernel directly, so the numbers match Activity Monitor rather than `top`.
public struct TaskManager: Sendable {
    public init() {}

    public func sample(previous: [Int32: (read: Int64, written: Int64)] = [:], interval: TimeInterval = 1)
        async -> (processes: [TaskProcess], load: SystemLoad)
    {
        // No lstart: its text is translated, and the kernel gives the start time anyway.
        let listing = await Command.run(
            "/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,user=,nice=,state=,comm="], timeout: .seconds(20)
        )
        let processes = Self.parse(listing?.text ?? "")
        var load = SystemLoad()
        load.cores = Self.perCoreUsage()
        load.memory = ProcessMonitor.memory()
        (load.swapUsed, load.swapTotal) = Self.swap()
        load.loadAverage = Self.loadAverage()
        load.uptime = Self.uptime()
        load.processCount = processes.count
        load.threadCount = processes.reduce(0) { $0 + $1.threads }
        if interval > 0 {
            var read: Int64 = 0
            var written: Int64 = 0
            for process in processes {
                guard let before = previous[process.pid] else { continue }
                read += max(0, process.diskRead - before.read)
                written += max(0, process.diskWritten - before.written)
            }
            load.diskRead = Double(read) / interval
            load.diskWritten = Double(written) / interval
        }
        return (processes, load)
    }

    static func parse(_ output: String) -> [TaskProcess] {
        output.split(separator: "\n").compactMap { line in
            // pid ppid %cpu rss user nice state command
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 8, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let cpu = number(fields[2]), let rss = Int64(fields[3]), let nice = Int32(fields[5])
            else { return nil }
            let path = fields[7...].joined(separator: " ")
            let kernel = Self.kernelInfo(pid: pid)
            return TaskProcess(
                pid: pid, parentPID: parent, name: (path as NSString).lastPathComponent, path: path,
                user: String(fields[4]), state: TaskProcess.State(psState: fields[6]), cpu: cpu,
                memory: kernel.footprint > 0 ? kernel.footprint : rss * 1024,
                threads: kernel.threads, niceness: nice, startedAt: kernel.startedAt,
                diskRead: kernel.diskRead, diskWritten: kernel.diskWritten, wakeups: kernel.wakeups
            )
        }
    }

    /// `ps` prints numbers the way the language of the Mac writes them, so "0,3" has to read
    /// the same as "0.3".
    static func number(_ text: Substring) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// Footprint, threads and disk use straight from the kernel. Processes of other users
    /// answer only partly, and the caller falls back to what `ps` reported.
    static func kernelInfo(pid: Int32)
        -> (footprint: Int64, threads: Int, diskRead: Int64, diskWritten: Int64, wakeups: Int64, startedAt: Date?)
    {
        var threads = 0
        var startedAt: Date?
        var taskInfo = proc_taskinfo()
        var allInfo = proc_taskallinfo()
        if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &allInfo, Int32(MemoryLayout<proc_taskallinfo>.size)) > 0 {
            threads = Int(allInfo.ptinfo.pti_threadnum)
            taskInfo = allInfo.ptinfo
            startedAt = Date(timeIntervalSince1970: Double(allInfo.pbsd.pbi_start_tvsec))
        } else if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
            threads = Int(taskInfo.pti_threadnum)
        }
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard ok == 0 else {
            return (Int64(taskInfo.pti_resident_size), threads, 0, 0, 0, startedAt)
        }
        return (
            Int64(usage.ri_phys_footprint), threads,
            Int64(usage.ri_diskio_bytesread), Int64(usage.ri_diskio_byteswritten),
            Int64(usage.ri_interrupt_wkups + usage.ri_pkg_idle_wkups), startedAt
        )
    }

    /// Busy share of each core since the last call.
    static func perCoreUsage() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var usage: [Double] = []
        var ticks: [[UInt32]] = []
        for core in 0 ..< Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ticks.append([user, system, idle, nice])
            let previous = previousTicks.withLock { $0.count > core ? $0[core] : [0, 0, 0, 0] }
            let busy = Double((user &- previous[0]) &+ (system &- previous[1]) &+ (nice &- previous[3]))
            let total = busy + Double(idle &- previous[2])
            usage.append(total > 0 ? busy / total : 0)
        }
        previousTicks.withLock { $0 = ticks }
        return usage
    }

    private static let previousTicks = Locked<[[UInt32]]>([])

    static func swap() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    static func loadAverage() -> [Double] {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return [] }
        return averages
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    // MARK: - Acting on a process

    public enum Signal: Sendable {
        case quit, forceQuit, pause, resume

        var raw: Int32 {
            switch self {
            case .quit: SIGTERM
            case .forceQuit: SIGKILL
            case .pause: SIGSTOP
            case .resume: SIGCONT
            }
        }
    }

    /// Sends a signal to a process the user owns. Returns false when the kernel refuses,
    /// which for another user's process means it needs administrator rights.
    @discardableResult
    public static func send(_ signal: Signal, to pid: Int32) -> Bool {
        kill(pid, signal.raw) == 0
    }

    /// Changes scheduling priority. Lowering it below zero needs administrator rights,
    /// so that case goes through `AdminRunner`.
    public static func setPriority(_ niceness: Int32, for pid: Int32) async -> Bool {
        if setpriority(PRIO_PROCESS, UInt32(pid), niceness) == 0 { return true }
        let result = await AdminRunner.run(
            ["/usr/bin/renice \(niceness) -p \(pid)"],
            prompt: String(localized: "MacUtil needs your password to change the priority of this program.")
        )
        return result.succeeded
    }

    /// Files and sockets the process has open, from `lsof`.
    public static func openFiles(pid: Int32, limit: Int = 200) async -> [String] {
        guard let output = await Command.run("/usr/sbin/lsof", ["-p", "\(pid)", "-Fn"], timeout: .seconds(20))
        else { return [] }
        var files: [String] = []
        for line in output.text.split(separator: "\n") where line.hasPrefix("n") {
            let path = String(line.dropFirst())
            guard path.hasPrefix("/") || path.contains("->") else { continue }
            if !files.contains(path) { files.append(path) }
            if files.count >= limit { break }
        }
        return files
    }

    /// The command line the process was started with.
    public static func arguments(pid: Int32) async -> String? {
        let output = await Command.run("/bin/ps", ["-o", "args=", "-p", "\(pid)"], timeout: .seconds(10))
        let text = output?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// A short CPU sample, the same one `sample(1)` in the Terminal produces.
    public static func sampleStack(pid: Int32, seconds: Int = 3) async -> String? {
        let output = await Command.run("/usr/bin/sample", ["\(pid)", "\(seconds)", "-mayDie"], timeout: .seconds(60))
        return output?.status == 0 ? output?.text : nil
    }
}
