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

    // MARK: - Top processes (ps-based)

    static func topProcesses(limit: Int = 8) -> [ProcessEntry] {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-ArcO %cpu -o pid=%PID%…` mangles the columns on this ps (default
        // set first, custom columns appended) — every row failed Double parse
        // on the TT column and the list was ALWAYS empty. `-r` sorts by CPU.
        proc.arguments = ["-c", "ps -Arcro pid,pcpu,pmem,comm | head -\(limit + 1)"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line -> ProcessEntry? in
            let parts = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard parts.count >= 4, let pid = Int(parts[0]),
                  let cpu = Double(parts[1]), let mem = Double(parts[2]) else { return nil }
            return ProcessEntry(pid: pid, cpu: cpu, mem: mem, command: parts[3...].joined(separator: " "))
        }
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
