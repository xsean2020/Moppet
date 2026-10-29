import Foundation
import IOKit
import IOKit.ps

/// Live system metrics — SwiftUI cousin of `mo status` (gopsutil → Mach/sysctl/IOKit).
enum SystemStatus {

    struct CPU {
        let usage: Double          // 0…1 all cores
        let cores: Int
    }

    struct Memory {
        let totalBytes: Int64
        let usedBytes: Int64
        let freeBytes: Int64
        let pressure: Double       // 0…1
    }

    struct Network {
        let bytesIn: Int64         // cumulative
        let bytesOut: Int64
        let rateIn: Double         // bytes/sec since last sample
        let rateOut: Double
    }

    struct Battery {
        let percentage: Double
        let charging: Bool
        let present: Bool
    }

    struct ProcessEntry: Identifiable {
        let id = UUID()
        let pid: Int
        let cpu: Double
        let mem: Double
        let command: String
    }

    // MARK: - CPU (delta between samples)

    private static var lastTicks: (user: Double, system: Double, idle: Double, total: Double)?
    private static var lastSampleTime = Date()
    /// The status view and the MCP system_status tool sample concurrently —
    /// torn reads of the delta state produced negative/spiky numbers.
    private static let sampleLock = NSLock()

    static var cpu: CPU {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        // host_statistics reads `count` as the INPUT buffer size — it must be
        // pre-set to HOST_CPU_LOAD_INFO_COUNT or the call fails (was 0 → the
        // metric silently returned zeros).
        var count = natural_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuLoad = host_cpu_load_info_t.allocate(capacity: 1)
        defer { cpuLoad.deallocate() }

        let result = withUnsafeMutablePointer(to: &count) { countPointer in
            cpuLoad.withMemoryRebound(to: integer_t.self, capacity: 4) { loadPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                                loadPointer, countPointer)
            }
        }
        guard result == KERN_SUCCESS else { return CPU(usage: 0, cores: ProcessInfo.processInfo.activeProcessorCount) }

        let user = Double(cpuLoad[0].cpu_ticks.0)      // TICKS_USER
        let system = Double(cpuLoad[0].cpu_ticks.1)    // TICKS_SYSTEM
        let idle = Double(cpuLoad[0].cpu_ticks.2)      // TICKS_IDLE
        let total = user + system + idle + Double(cpuLoad[0].cpu_ticks.3)

        var usage: Double = 0
        if let last = lastTicks {
            let idleDelta = idle - last.idle
            let totalDelta = total - last.total
            if totalDelta > 0 { usage = 1 - (idleDelta / totalDelta) }
        } else {
            // First sample: usage since boot.
            if total > 0 { usage = 1 - (idle / total) }
        }
        lastTicks = (user, system, idle, total)
        lastSampleTime = Date()
        return CPU(usage: max(0, min(1, usage)), cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - Memory

    static var memory: Memory {
        var total: Int64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Memory(totalBytes: total, usedBytes: 0, freeBytes: total, pressure: 0)
        }
        let pageSize = Int64(vm_kernel_page_size)
        let freePages: Int64 = Int64(vmStats.free_count) + Int64(vmStats.inactive_count)
        let usedPages: Int64 = Int64(vmStats.active_count) + Int64(vmStats.wire_count)
            + Int64(vmStats.compressor_page_count) - Int64(vmStats.purgeable_count)
        let free = freePages * pageSize
        let used = max(0, usedPages * pageSize)
        let pressure: Double = total > 0 ? Double(used) / Double(total) : 0
        return Memory(totalBytes: total, usedBytes: used, freeBytes: free, pressure: pressure)
    }

    // MARK: - Network (getifaddrs deltas)

    private static var lastNet: (in: Int64, out: Int64, at: Date)?

    static var network: Network {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        var totalIn: Int64 = 0
        var totalOut: Int64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else {
            return Network(bytesIn: 0, bytesOut: 0, rateIn: 0, rateOut: 0)
        }
        defer { freeifaddrs(ifap) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            // Physical/primary interfaces only: utun & friends tunnel the
            // same packets as en*, summing both inflates the real rate.
            guard name.hasPrefix("en"),
                  let data = current.pointee.ifa_data else { continue }
            let ifData = data.assumingMemoryBound(to: if_data.self)
            totalIn += Int64(ifData.pointee.ifi_ibytes)
            totalOut += Int64(ifData.pointee.ifi_obytes)
        }

        var rateIn = 0.0, rateOut = 0.0
        let now = Date()
        if let last = lastNet {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0.2 {
                // Counter reset (interface restart) → negative delta → 0.
                rateIn = max(0, Double(totalIn - last.in) / dt)
                rateOut = max(0, Double(totalOut - last.out) / dt)
            }
        }
        lastNet = (totalIn, totalOut, now)
        return Network(bytesIn: totalIn, bytesOut: totalOut, rateIn: rateIn, rateOut: rateOut)
    }

    // MARK: - Battery (IOKit power sources)

    static var battery: Battery {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return Battery(percentage: 0, charging: false, present: false) }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            return Battery(
                percentage: max > 0 ? Double(current) / Double(max) : 0,
                charging: state == kIOPSACPowerValue,
                present: true
            )
        }
        return Battery(percentage: 0, charging: false, present: false)
    }

    // MARK: - Top processes (libproc/sysctl — no external binary)

    /// Top consumers, `%CPU` computed the same way `ps` does it:
    /// cumulative CPU time ÷ process lifetime.
    ///
    /// This used to shell out to `/bin/ps`, which made the metric die
    /// entirely in restricted environments (hardened sandboxes refuse to
    /// exec external binaries → `proc.run()` throws → 0 rows → the Status
    /// process card was empty and the smoke test failed). Everything needed
    /// is available in-process:
    /// - `sysctl(KERN_PROC_ALL)` — pid, start time, short name (readable for
    ///   every process, no entitlement)
    /// - `proc_pidinfo(PROC_PIDTASKINFO)` — cumulative CPU ns + resident
    ///   bytes (readable for the calling user's processes; root-owned
    ///   processes without extra entitlements are skipped)
    /// - `proc_pidpath` — full executable path when readable
    static func topProcesses(limit: Int = 8) -> [ProcessEntry] {
        let now = Date()
        let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)
        var rows: [ProcessEntry] = []
        rows.reserveCapacity(256)

        for proc in allProcesses() {
            guard proc.pid > 0 else { continue }
            let elapsed = now.timeIntervalSince(proc.started)
            guard elapsed > 0.5 else { continue }
            // CPU % from cumulative CPU nanoseconds ÷ lifetime (ps parity).
            // Processes whose task info is inaccessible (root daemons) still
            // show up with a 0 estimate rather than vanishing from the list.
            var cpu = 0.0
            var mem = 0.0
            if let task = taskInfo(proc.pid) {
                let cpuSeconds = Double(task.totalUser + task.totalSystem) / 1_000_000_000
                cpu = min(999, max(0, 100 * cpuSeconds / elapsed))
                mem = min(100, max(0, 100 * Double(task.resident) / physicalMemory))
            }
            rows.append(ProcessEntry(pid: Int(proc.pid), cpu: cpu, mem: mem,
                                     command: proc.name))
        }
        return Array(rows.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }

    private struct ProcFork {
        var pid: pid_t
        var started: Date
        var name: String
    }

    /// One `sysctl(KERN_PROC_ALL)` pass — pid, start time, 16-char comm name.
    private static func allProcesses() -> [ProcFork] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The sysctl can grow between the size probe and the call — retry
        // once with a generous margin instead of failing the whole metric.
        for extra in [0, 256] {
            var data = [UInt8](repeating: 0, count: size + extra * MemoryLayout<kinfo_proc>.stride)
            var actual = data.count
            guard sysctl(&mib, 3, &data, &actual, nil, 0) == 0 else { return [] }
            return data.withUnsafeBytes { raw in
                let procs = raw.bindMemory(to: kinfo_proc.self)
                return procs.prefix(actual / MemoryLayout<kinfo_proc>.stride).map { kp in
                    let tv = kp.kp_proc.p_starttime
                    let started = Date(timeIntervalSince1970:
                        Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
                    let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
                        guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                        return String(cString: base)
                    }
                    let pid = kp.kp_proc.p_pid
                    // Prefer the full executable path (what `ps comm=` showed);
                    // unreadable for root-only processes → keep the short name.
                    var path = name
                    if !name.isEmpty {
                        var buffer = [CChar](repeating: 0, count: 4096)
                        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                            path = String(cString: buffer)
                        }
                    }
                    return ProcFork(pid: pid, started: started, name: path)
                }
            }
        }
        return []
    }

    private struct TaskInfo {
        var totalUser: UInt64
        var totalSystem: UInt64
        var resident: UInt64
    }

    /// Cumulative CPU nanoseconds + resident bytes for one pid. Returns nil
    /// for processes the caller may not inspect (root daemons).
    private static func taskInfo(_ pid: pid_t) -> TaskInfo? {
        var info = proc_taskinfo()
        let result = withUnsafeMutableBytes(of: &info) { pointer -> Int32 in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer.baseAddress,
                         Int32(MemoryLayout<proc_taskinfo>.size))
        }
        guard result == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return TaskInfo(totalUser: info.pti_total_user,
                        totalSystem: info.pti_total_system,
                        resident: info.pti_resident_size)
    }

    // MARK: - Uptime

    static var uptimeFormatted: String {
        let interval = Int(ProcessInfo.processInfo.systemUptime)
        let days = interval / 86400
        let hours = (interval % 86400) / 3600
        let minutes = (interval % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
