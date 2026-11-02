import Foundation
import Observation

/// One status snapshot — everything the Status dashboard renders, in
/// UI-ready structs (requirement: 数据采集与 UI 完全解耦, UI 不直接调系统 API).
/// The UI reads fields; only providers touch Mach/IOKit/getifaddrs.
struct StatusSample: Equatable {
    var cpu: SystemStatus.CPU
    var memory: SystemStatus.Memory
    var network: SystemStatus.Network
    var battery: SystemStatus.Battery
    var disk: DiskInfo.Snapshot
    /// Machine-wide disk throughput in B/s (delta of `SystemStatus.diskIOBytes`).
    var diskReadRate: Double = 0
    var diskWriteRate: Double = 0
    var timestamp: Date = Date()

    static let initial = StatusSample(
        cpu: .init(usage: 0, cores: 0, userShare: 0, systemShare: 0),
        memory: .init(totalBytes: 0, usedBytes: 0, freeBytes: 0, pressure: 0, compressedBytes: 0),
        network: .init(bytesIn: 0, bytesOut: 0, rateIn: 0, rateOut: 0),
        battery: .init(percentage: 0, plugged: false, charging: false, full: false, present: false),
        disk: DiskInfo.snapshot()
    )
}

/// Data-source abstraction behind the status dashboard. `sample()` advances
/// one tick: it reads the hardware and computes deltas against the previous
/// call, so an instance IS the sampling session (two instances would each
/// see a zero first delta — callers hold exactly one).
///
/// Implementations are `@unchecked Sendable` because the sample runs OFF the
/// main actor (requirement: 后台采集不能阻塞主线程); internal delta state is
/// lock-guarded.
protocol StatusProviding: Sendable {
    func sample() -> StatusSample
}

/// Real hardware provider — thin composition over `SystemStatus` (Mach
/// host_statistics / vm_statistics64, getifaddrs, IOPowerSources, IORegistry)
/// plus the disk-I/O delta state that has no home in the static enum.
final class LiveStatusProvider: StatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var lastDiskIO: (read: Int64, write: Int64, at: Date)?

    func sample() -> StatusSample {
        var sample = StatusSample(
            cpu: SystemStatus.cpu,
            memory: SystemStatus.memory,
            network: SystemStatus.network,
            battery: SystemStatus.battery,
            disk: DiskInfo.snapshot()
        )
        let io = SystemStatus.diskIOBytes()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastDiskIO {
            let dt = now.timeIntervalSince(last.at)
            if dt > 0.2 {
                // Counter reset (sleep/driver reload) → negative delta → 0,
                // same rule as the network rates.
                sample.diskReadRate = max(0, Double(io.read - last.read) / dt)
                sample.diskWriteRate = max(0, Double(io.write - last.write) / dt)
            }
        }
        lastDiskIO = (io.read, io.write, now)
        return sample
    }
}

/// Deterministic mock for SwiftUI Previews and the doc's "Mock 数据模式":
/// smooth sine waveforms on plausible magnitudes, no randomness, so a
/// preview never renders as an empty or pathological board. Durations run
/// off the wall clock so a preview left open keeps drifting like a live one.
final class MockStatusProvider: StatusProviding, @unchecked Sendable {
    private let start = Date()

    func sample() -> StatusSample {
        let t = Date().timeIntervalSince(start)
        let wave = { (period: Double, phase: Double, amp: Double, mid: Double) in
            mid + amp * sin(t / period * 2 * .pi + phase)
        }
        let cpuUsage = max(0.02, min(1, wave(37, 0.3, 0.16, 0.28)))
        var sample = StatusSample(
            cpu: .init(usage: cpuUsage, cores: ProcessInfo.processInfo.activeProcessorCount,
                       userShare: 0.72, systemShare: 0.28),
            memory: .init(totalBytes: 32 * 1_073_741_824,
                          usedBytes: Int64(0.572 * 32 * 1_073_741_824),
                          freeBytes: Int64(0.428 * 32 * 1_073_741_824),
                          pressure: 0.572,
                          compressedBytes: 2_147_483_648),
            network: .init(bytesIn: 1_000_000_000, bytesOut: 100_000_000,
                           rateIn: max(2_000, wave(23, 1.1, 180_000, 260_000)),
                           rateOut: max(1_000, wave(17, 2.4, 40_000, 70_000))),
            battery: .init(percentage: max(0.1, min(1, wave(600, 0, 0.05, 0.78))),
                           plugged: t.truncatingRemainder(dividingBy: 600) < 300,
                           charging: true, full: false, present: true),
            disk: DiskInfo.snapshot(),
            diskReadRate: max(0, wave(29, 0.7, 3_000_000, 4_500_000)),
            diskWriteRate: max(0, wave(41, 2.2, 900_000, 1_400_000))
        )
        // Used memory should breathe a little instead of tracking one sine.
        let breathing = wave(53, 1.9, 0.03, 0.572)
        sample.memory = SystemStatus.Memory(
            totalBytes: sample.memory.totalBytes,
            usedBytes: Int64(min(0.98, max(0.05, breathing))
                * Double(sample.memory.totalBytes)),
            freeBytes: sample.memory.freeBytes,
            pressure: min(0.98, max(0.05, breathing)),
            compressedBytes: sample.memory.compressedBytes
        )
        return sample
    }
}

/// Fixed-capacity ring buffer for the history curves (requirement: 固定容量
/// 环形缓冲区, 避免无限增长). Appends overwrite the oldest slot once full;
/// `snapshot` hands the Canvas an ordered oldest→newest copy.
struct RingBuffer<Value> {
    let capacity: Int
    private var storage: [Value?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = .init(repeating: nil, count: capacity)
    }

    mutating func append(_ value: Value) {
        storage[head] = value
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    var isEmpty: Bool { count == 0 }

    var snapshot: [Value] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).compactMap { storage[(start + $0) % capacity] }
    }
}

/// The dashboard's unified sampler (requirement: 统一采样调度器 — ONE task,
/// no per-view timers): ticks at `interval`, samples the provider off the
/// main actor, then publishes the snapshot and appends the history ring
/// buffers on the main actor. Pausable for backgrounded windows
/// (requirement: 窗口不可见时降低开销) and cancellable via `stop()`.
@MainActor
@Observable
final class StatusEngine {
    private(set) var sample: StatusSample = .initial
    private(set) var processes: [SystemStatus.ProcessEntry] = []

    // 120 s @ 1 s for the quadrant curves; the dial's dual net series keeps
    // 60 s so the 88×34 plot stays readable.
    private(set) var cpuHistory = RingBuffer<Double>(capacity: 120)
    private(set) var memoryHistory = RingBuffer<Double>(capacity: 120)
    private(set) var diskReadHistory = RingBuffer<Double>(capacity: 120)
    private(set) var diskWriteHistory = RingBuffer<Double>(capacity: 120)
    private(set) var batteryHistory = RingBuffer<Double>(capacity: 120)
    private(set) var netDownHistory = RingBuffer<Double>(capacity: 60)
    private(set) var netUpHistory = RingBuffer<Double>(capacity: 60)

    /// Process rows refresh on the slower half-cadence — proc_pidinfo over
    /// every pid costs more than the five µs metric reads.
    static let processCadence = 2

    var paused: Bool = false
    var interval: TimeInterval = 1.0

    private var provider: any StatusProviding
    private var task: Task<Void, Never>?
    private var tick = 0

    init(provider: any StatusProviding = LiveStatusProvider()) {
        self.provider = provider
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.paused else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let provider = self.provider
                let fetched = await Task.detached(priority: .utility) {
                    provider.sample()
                }.value
                guard !Task.isCancelled else { return }
                self.ingest(fetched)
                try? await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Immediate refresh after a foreground event (e.g. killing a process).
    func sampleNow() {
        guard !paused else { return }
        let provider = provider
        Task { [weak self] in
            let fetched = await Task.detached(priority: .utility) { provider.sample() }.value
            self?.ingest(fetched)
        }
        refreshProcesses()
    }

    func refreshProcesses() {
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) {
                SystemStatus.topProcesses(limit: 8)
            }.value
            self?.processes = rows
        }
    }

    private func ingest(_ fetched: StatusSample) {
        sample = fetched
        tick += 1
        // Seed the first sample twice: a single point draws nothing, so a
        // curve band sat empty for the first two seconds and looked broken.
        appendDoubled(&cpuHistory, fetched.cpu.usage * 100)
        appendDoubled(&memoryHistory, fetched.memory.pressure * 100)
        appendDoubled(&batteryHistory, fetched.battery.percentage * 100)
        // Log-ish scale so bursts stay visible next to idle (same mapping as
        // the dial has always used: domain 0…8 over log10(1+B/s)).
        appendDoubled(&diskReadHistory, log10(1 + fetched.diskReadRate))
        appendDoubled(&diskWriteHistory, log10(1 + fetched.diskWriteRate))
        appendDoubled(&netDownHistory, log10(1 + fetched.network.rateIn))
        appendDoubled(&netUpHistory, log10(1 + fetched.network.rateOut))
        if tick % Self.processCadence == 0 { refreshProcesses() }
    }

    private func appendDoubled(_ buffer: inout RingBuffer<Double>, _ value: Double) {
        if buffer.isEmpty { buffer.append(value) }
        buffer.append(value)
    }

    /// Synthetic-but-plausible data for the offscreen probe only
    /// (`--probe-render status`, set `StatusView.debugSeed` before init).
    ///
    /// Round 5: the three series are written out as ~24 angular samples with
    /// flat plateaus and occasional spikes, sampled off the reference's zoomed
    /// crops. The CPU band's wave FLOATS — its trough plateaus ride ~30% of
    /// the band above the baseline (the old 8…27 seed crawled along it, which
    /// is what read as "waveform doesn't match" in the round-5 render); the
    /// dial's two net series genuinely WEAVE, the amber one diving onto/under
    /// the green stroke instead of riding parallel above it. Metric values
    /// freeze at real system reads so the render is deterministic; the live
    /// sampler stays off in probe mode.
    func seedForProbe() {
        sample = StatusSample(
            cpu: SystemStatus.cpu,
            memory: SystemStatus.memory,
            network: SystemStatus.network,
            battery: SystemStatus.battery,
            disk: DiskInfo.snapshot()
        )
        // CPU (domain 0…40 over the floor-anchored 33.2pt plot; 1 unit =
        // 0.83pt = 1% of the 83pt band, so a value IS its band-% height):
        // traced off the close-up — left entry at 23, trough plateaus at
        // 30-31, crest clusters reaching 37 and the 40 ceiling (≤40% band).
        // Typical swing 30↔37 = 7 units ≈ 18% of the plot; the spike
        // cluster 30→40 = 10 ≈ 25%. Plateaus at 37/36/30/31/30.
        for value in [23, 37, 37, 37, 35, 34, 36, 36, 34, 30, 30, 31,
                      34, 37, 32, 31, 31, 37, 40, 38, 30, 31, 30, 32] {
            cpuHistory.append(Double(value))
        }
        // Download (green, filled; domain 0…8, 34pt dial plot): the
        // reference's green line rides LOW and barely moves — small
        // per-sample ripples with sharp mitered corners, swing 4.1…4.9
        // ≈ 10% of the plot, the one slightly taller bump late (i19/i20)
        // as in the close-up.
        for value in [4.3, 4.6, 4.4, 4.7, 4.7, 4.4, 4.6, 4.2, 4.5, 4.1, 4.4, 4.7,
                      4.8, 4.8, 4.5, 4.7, 4.3, 4.6, 4.2, 4.8, 4.9, 4.6, 4.4, 4.5] {
            netDownHistory.append(value)
        }
        // Upload (amber, dashed): the close-up's amber is the moving one —
        // a high left plateau (5.9…6.1), a dive that TOUCHES and shallowly
        // submerges under the green stroke (i8 −0.4 ≈ 1.7pt, within the
        // strokes' combined half-width: the dashes peek out from under the
        // line the way the reference's do), the big mid-chart hump (crest
        // 6.7 ≈ 5.6pt below the canvas top — the band's dominant feature),
        // and a tail that weaves along the green line (dips of −0.2…−0.4
        // at i17/i20/i23, above it between). Amber rides above green 20 of
        // 24 samples. Swing 4.1…6.7 = 2.6 units ≈ 33% of the plot — 3× the
        // green's, per the close-up's amplitude ratio.
        for value in [5.9, 6.1, 5.9, 6.0, 6.1, 5.9, 5.0, 4.4, 4.1, 5.2, 6.0, 6.5,
                      6.7, 6.7, 6.5, 5.6, 4.8, 4.2, 4.6, 5.0, 4.6, 4.9, 4.7, 4.3] {
            netUpHistory.append(value)
        }
        // The new quadrant curves seed flat at their live values — real
        // battery sits level and disk/memory move slowly, which is exactly
        // what the probe should show.
        for _ in 0..<24 {
            memoryHistory.append(sample.memory.pressure * 100)
            batteryHistory.append(sample.battery.percentage * 100)
            diskReadHistory.append(log10(1 + 2_400_000))
            diskWriteHistory.append(log10(1 + 640_000))
        }
        processes = [
            .init(pid: 512, cpu: 12.4, mem: 2.1, command: "WindowServer"),
            .init(pid: 8841, cpu: 6.8, mem: 1.4, command: "Moppet"),
            .init(pid: 733, cpu: 3.2, mem: 0.9, command: "kernel_task"),
            .init(pid: 1290, cpu: 1.1, mem: 0.6, command: "com.apple.WebKit.GPU"),
        ]
    }

    /// Reference-bandwidth mode for the centre dial (requirement 6.3): when
    /// `status.referenceBandwidthMbps` is configured, the dial ring encodes
    /// real activity as `speed / reference`, clamped to 0…1. Unconfigured →
    /// nil: the caller falls back to the brightness hint and must NOT imply
    /// a bandwidth percentage.
    static func referenceBandwidthActivity(_ sample: StatusSample) -> Double? {
        let mbps = UserDefaults.standard.double(forKey: "status.referenceBandwidthMbps")
        guard mbps > 0 else { return nil }
        let referenceBytes = mbps * 1_000_000 / 8
        let total = sample.network.rateIn + sample.network.rateOut
        return min(1, max(0, total / referenceBytes))
    }

    /// No-reference activity hint for the dial's brightness (8.3): a
    /// log-scaled 0…1 that saturates around 10 GB/s — a lamp, never a gauge.
    static func activityBrightness(_ sample: StatusSample) -> Double {
        let total = sample.network.rateIn + sample.network.rateOut
        return min(1, log10(1 + total) / 4)
    }
}
