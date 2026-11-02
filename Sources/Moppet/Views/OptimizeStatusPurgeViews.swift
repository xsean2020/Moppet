import SwiftUI

/// System maintenance — `mo optimize` catalogue with per-task run buttons.
/// Admin tasks pop the native password dialog (AppleScript privileges).
struct OptimizeView: View {
    var onClose: (() -> Void)?

    /// id per line: String ids collided whenever the same task ran twice.
    struct ResultLine: Identifiable { let id = UUID(); let text: String }
    @State private var results: [ResultLine] = []
    @State private var runningTask: String?
    @State private var confirmTask: OptimizeEngine.OptimizeTask?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Optimize"), subtitle: L("Maintenance tasks — admin tasks prompt for your password"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    summaryLine
                    // One grouped list instead of eight identical slabs: the
                    // category moved out of the subtitle (where it read as
                    // noise after a "·") into a scannable trailing pill.
                    GroupedCard {
                        ForEach(Array(OptimizeEngine.catalog.enumerated()), id: \.element.id) { index, task in
                            if index > 0 { GroupedDivider() }
                            taskRow(task)
                        }
                    }
                    if !results.isEmpty { outputCard }
                }
                .padding(.horizontal, Airi.space4)
                .padding(.top, Airi.space3)
                .padding(.bottom, Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .confirmationDialog(
            Text(confirmTask.map { task in
                String(format: L("Run “%@”?"), task.title)
            } ?? ""),
            isPresented: Binding(get: { confirmTask != nil },
                                 set: { if !$0 { confirmTask = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Run"), role: .destructive) {
                if let task = confirmTask { run(task) }
                confirmTask = nil
            }
            Button(L("Cancel"), role: .cancel) { confirmTask = nil }
        } message: {
            Text(confirmTask.map { task in
                task.requiresAdmin
                    ? L("This maintenance task changes system state and will prompt for your administrator password.")
                    : L("This maintenance task changes system state.")
            } ?? "")
        }
    }

    /// How many tasks there are and how many will ask for a password — the
    /// one thing worth knowing before scrolling, and it replaces the old
    /// per-row lock icon that looked like an error badge.
    private var summaryLine: some View {
        let adminCount = OptimizeEngine.catalog.filter(\.requiresAdmin).count
        return HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10, weight: .medium))
            Text(String(format: L("%1$lld tasks · %2$lld need an admin password"),
                        OptimizeEngine.catalog.count, adminCount))
                .font(Airi.captionFont)
                .monospacedDigit()
            Spacer()
        }
        .foregroundStyle(Airi.neutral500)
        .padding(.leading, 2)
    }

    /// One maintenance task: icon chip · title (+ lock for admin) · detail ·
    /// category pill · Run. Same row anatomy as the Clean page's grouped list.
    private func taskRow(_ task: OptimizeEngine.OptimizeTask) -> some View {
        let tint = task.requiresAdmin ? Airi.warning : Airi.primary
        return HStack(spacing: 10) {
            Image(systemName: task.requiresAdmin ? "lock.shield" : "wand.and.rays")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(task.title)
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                        .lineLimit(1)
                    if task.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Airi.warning)
                            .help(L("Asks for your administrator password"))
                    }
                }
                Text(task.detail)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Airi.space2)
            Text(task.category)
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral500)
                // Fixed-width column: the categories are 5–11 chars wide, and
                // a content-sized pill left a ragged edge right next to the
                // buttons, which read as misalignment.
                .frame(minWidth: 76)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Airi.neutral100.opacity(0.9)))
                .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))
                .fixedSize()
            if runningTask == task.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 64)
            } else {
                AiriButton(title: L("Run"), variant: .secondary) { confirmTask = task }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var outputCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Output")).font(Airi.cardTitleFont)
                ForEach(results) { line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Airi.neutral700)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func run(_ task: OptimizeEngine.OptimizeTask) {
        runningTask = task.id
        let id = task.id
        Task {
            do {
                let output = try await OptimizeEngine.run(taskID: id)
                results.append(ResultLine(text: "✓ \(task.title): \(output)"))
                UXFeedback.success()
                PetBus.shared.say("\(task.title) ✨", state: .celebrating)
            } catch {
                results.append(ResultLine(text: "✗ \(task.title): \(error.localizedDescription)"))
            }
            runningTask = nil
        }
    }
}

/// Live system monitor — four ring sectors around a central network dial.
///
/// The old page was a 2×2 grid of identical cards plus a separate disk card:
/// nothing said "these are one machine", and five blocks competed for
/// attention equally. Here the ring *is* the shape — CPU (top-left), memory
/// (top-right), disk (bottom-left) and battery (bottom-right) each own a
/// quadrant, separated by hairline radial seams at the cardinal points.
/// Round 6 makes the outer arcs the metrics' percentage gauges (lit length =
/// the quadrant's headline percentage over its span, the unlit remainder a
/// faint tint track) — and since the arcs already speak the percentage, the
/// bar-removal round retired the in-quadrant gauge bars entirely and gave
/// every quadrant's interior to a full-bleed history band (sector-wide,
/// clipped by the ring circle, the way the reference board's network sector
/// fills its quarter). The centre dial carries network: the two live rates
/// plus the dual-series trace all live inside the element the eye already
/// rests on. Disk's band is explicitly DISK I/O (labelled), not capacity.
/// Which ring quadrant a hover/click lands on. Order matches the layout:
/// 左上 CPU / 右上 Memory / 左下 Disk / 右下 Battery.
enum StatusQuadrant: CaseIterable, Identifiable {
    case cpu, memory, disk, battery
    var id: Self { self }

    var isTop: Bool { self == .cpu || self == .memory }
    var isLeft: Bool { self == .cpu || self == .disk }

    var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: return Airi.primary
        case .memory: return Airi.chartPurple
        case .disk: return Airi.warning
        case .battery: return Airi.success
        }
    }

    var title: String {
        switch self {
        case .cpu: return L("CPU")
        case .memory: return L("Memory")
        case .disk: return L("Disk")
        case .battery: return L("Battery")
        }
    }
}

struct StatusView: View {
    var onClose: (() -> Void)?

    /// The unified sampler owns ALL metric state (requirement: 数据采集与
    /// UI 解耦 · 统一采样调度器): this view never calls a system API for
    /// the dashboard numbers.
    @State private var engine: StatusEngine
    @State private var hoveredQuadrant: StatusQuadrant?
    @State private var selectedQuadrant: StatusQuadrant?
    @State private var boardScale: CGFloat = 2.0 / 3.0
    @Environment(\.scenePhase) private var scenePhase

    /// Last kill attempt feedback (shown under the process list).
    @State private var killFeedback: String?
    @State private var pendingKill: SystemStatus.ProcessEntry?

    /// Offscreen probe hook (`--probe-render status`): `.task` fires late in
    /// the probe's invisible window, so without a seed the render showed empty
    /// sparklines — i.e. it could not verify the very layout it exists for.
    /// Set BEFORE `StatusView()`; the engine then boots pre-seeded and the
    /// probe skips the live sampler for a deterministic render.
    static var debugSeed = false
    /// Probe hook for the click-through detail card (`--probe-render status
    /// … expanded`): pre-selects a quadrant so the offscreen render can
    /// verify the panel the way a click would.
    static var debugSelectedQuadrant: StatusQuadrant?

    init(onClose: (() -> Void)? = nil,
         provider: any StatusProviding = LiveStatusProvider()) {
        self.onClose = onClose
        let engine = StatusEngine(provider: provider)
        _engine = State(initialValue: engine)
        if Self.debugSeed { engine.seedForProbe() }
        _selectedQuadrant = State(initialValue: Self.debugSelectedQuadrant)
        Self.debugSelectedQuadrant = nil
    }

    // Read-out bridges: the pixel-tuned layout below keeps speaking in the
    // SystemStatus structs it was designed against; the engine supplies them.
    private var cpu: SystemStatus.CPU { engine.sample.cpu }
    private var mem: SystemStatus.Memory { engine.sample.memory }
    private var net: SystemStatus.Network { engine.sample.network }
    private var battery: SystemStatus.Battery { engine.sample.battery }
    private var disk: DiskInfo.Snapshot { engine.sample.disk }
    private var processes: [SystemStatus.ProcessEntry] { engine.processes }

    /// History snapshots for the curves (oldest → newest). The engine's ring
    /// buffers cap growth; these are plain copies for Canvas.
    private var cpuHistory: [Double] { engine.cpuHistory.snapshot }
    private var netDownHistory: [Double] { engine.netDownHistory.snapshot }
    private var netUpHistory: [Double] { engine.netUpHistory.snapshot }
    private var memoryHistory: [Double] { engine.memoryHistory.snapshot }
    private var diskReadHistory: [Double] { engine.diskReadHistory.snapshot }
    private var diskWriteHistory: [Double] { engine.diskWriteHistory.snapshot }
    private var batteryHistory: [Double] { engine.batteryHistory.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Status"),
                       subtitle: String(format: L("Live system health · uptime %@"), SystemStatus.uptimeFormatted),
                       onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    gaugeBoard
                    quadrantDetailCard
                    processCard
                }
                .padding(.horizontal, Airi.space4)
                .padding(.top, Airi.space3)
                .padding(.bottom, Airi.space4)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                // Adaptive sizing (requirement: 自适应窗口大小): the board's
                // whole 440-pt coordinate system scales as ONE unit — every
                // quadrant ratio, arc band and font keeps its designed
                // proportion. The user-set 2/3 display size stays the
                // CEILING; a narrow window only shrinks it further.
                .modifier(BoardScaleReader(scale: $boardScale))
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .task {
            if Self.debugSeed { return }   // probe: pre-seeded in init, stay deterministic
            engine.start()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounded/invisible windows keep paying the sampler's CPU
            // for a user who can't see it — throttle to zero instead.
            engine.paused = phase != .active
        }
        .confirmationDialog(
            Text(String(format: L("Kill process (SIGTERM): %@ (pid %lld)?"),
                        pendingKill?.command ?? "", pendingKill?.pid ?? 0)),
            isPresented: Binding(get: { pendingKill != nil },
                                 set: { if !$0 { pendingKill = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Kill process (SIGTERM)"), role: .destructive) {
                if let entry = pendingKill { killConfirmed(entry) }
                pendingKill = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingKill = nil }
        } message: {
            Text(L("Unsaved work in that process is lost. System daemons refuse the signal (owned by root)."))
        }
    }

    // MARK: - Adaptive board scale

    /// Measures the column's width (the max-width 720 content box) and keeps
    /// the board scaled to it. Runs once at mount plus on every width change;
    /// nothing else re-derives geometry, so this stays cheap.
    private struct BoardScaleReader: ViewModifier {
        @Binding var scale: CGFloat

        func body(content: Content) -> some View {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { update(geo.size.width) }
                            .onChange(of: geo.size.width) { _, width in update(width) }
                    }
                )
        }

        private func update(_ width: CGFloat) {
            guard width > 0 else { return }
            // 460 = the 440 board + breathing room; the 2/3 display size the
            // user asked for is the ceiling, narrow windows only shrink it.
            let proposed = min(2.0 / 3.0, max(0.45, width / 460))
            if abs(proposed - scale) > 0.001 { scale = proposed }
        }
    }

    // MARK: - Rate formatting

    /// `ByteCountFormatter` renders zero as the localized "Zero KB", which
    /// read as a bug in a live rate ("↓ Zero KB/s"). Rates below 1 B/s are
    /// simply 0.
    private func rateText(_ bytesPerSecond: Double) -> String {
        bytesPerSecond < 1 ? "0 KB" : Int64(bytesPerSecond).bytesFormatted
    }

    // MARK: - Ring dashboard

    /// One 440pt board centred on (220, 220) — displayed at 2/3 since round 7
    /// (see the `.scaleEffect` below), so every internal coordinate, literal
    /// and comment stays in the 440 system — back to front: the three
    /// full-bleed layers (CPU chart, memory bar, disk bar — each clipped by
    /// the ring circle), the four quadrant arcs (band 202…214) whose tubes
    /// cover the layers' clipped ends, the hairline sector seams, the
    /// read-out stacks, the disk sector, and the network dial. The dial is
    /// opaque and painted last, so the layers may run under it — it backs
    /// them instead of fighting them.
    ///
    /// The board is deliberately 20pt bigger on every side than the 400pt box
    /// the read-out stacks are laid out in. A circle pulls away from its
    /// corners: with the ring drawn on the content's own box, the block's
    /// outer corner sat at radius √(124² + 148²) = 193 while the ring's band
    /// ran 182…194, so the CPU icon was drawn *through* the arc. Padding the
    /// ring out to a 202…214 band moves it off every painted corner (worst
    /// corner now: the stacks' top edge at y 69 → √(124² + 151²) = 195.4)
    /// without reflowing a single label.
    private var gaugeBoard: some View {
        ZStack {
            cpuBand
            memoryBand
            diskIOBand
            batteryBand
            ringArcs
            sectorDividers
            quadrantGrid
                .frame(width: 400, height: 400)
            diskSector
            networkDial
            quadrantHitAreas
        }
        .frame(width: 440, height: 440)
        // Round 7: the whole board displays at 2/3 (user ask "整体大小变为
        // 原来的2/3"). scaleEffect shrinks the RENDER while the layout frame
        // below re-anchors to the scaled box, so the process card moves up
        // with it; every internal coordinate stays 440-based and vector text
        // re-rasterises at the scaled size (crisp on Retina). `boardScale`
        // (read by `BoardScaleReader`) shrinks further on narrow windows —
        // 2/3 remains the ceiling, so the ask holds at every normal width.
        .scaleEffect(boardScale)
        .frame(width: 440 * boardScale, height: 440 * boardScale)
        .frame(maxWidth: .infinity)
        // The ring's top gap sits at the frame edge — without this the arcs
        // start right under the header divider.
        .padding(.top, Airi.space2)
        .animation(Airi.controlAnimation, value: boardScale)
    }

    /// Quadrants are separated by gaps at the four cardinal points, so the
    /// ring reads as four sectors rather than one circle. Round 6 turns the
    /// arcs into the metrics' percentage gauges ("外层弧线表示百分比"): each
    /// lit length is the quadrant's headline percentage scaled over the
    /// quadrant's 0.225-turn span — CPU usage, memory pressure (which IS the
    /// used/total ratio, see `SystemStatus.memory`), disk usedFraction,
    /// battery percentage — and the unlit remainder stays visible as the
    /// `GaugeArc` track (tint at 0.20), so full-vs-part reads at a glance.
    /// Every gauge anchors at the vertical-axis gap nearest it (12 o'clock
    /// for the top pair, 6 for the bottom) and grows toward the arc's far
    /// end — memory's arc then sweeps the same direction its bar fills
    /// below. Disk's gauge reads warning amber, the same ink as its bar and
    /// icon (review round 1: the chartGreen first cut collided with the
    /// battery arc and cut the disk quadrant's colours apart). The battery
    /// still speaks through its TINT: green charged, amber/red low; with no
    /// battery the gauge reads empty (neutral track = "no data").
    private var ringArcs: some View {
        ZStack {
            GaugeArc(start: 0.5125, end: 0.7375, progress: cpu.usage,
                     tint: Airi.primary, reversed: true,
                     emphasized: hoveredQuadrant == .cpu)
            GaugeArc(start: 0.7625, end: 0.9875, progress: mem.pressure,
                     tint: Airi.chartPurple,
                     emphasized: hoveredQuadrant == .memory)
            GaugeArc(start: 0.2625, end: 0.4875, progress: disk.usedFraction,
                     tint: Airi.warning,
                     emphasized: hoveredQuadrant == .disk)
            // Desktops have no battery: the gauge stays empty (a neutral
            // track, reading as "no data") rather than dropping out.
            GaugeArc(start: 0.0125, end: 0.2375,
                     progress: battery.present ? battery.percentage : 0,
                     tint: battery.present ? batteryTint : Airi.neutral400,
                     reversed: true,
                     emphasized: hoveredQuadrant == .battery)
        }
        .padding(6)
    }

    /// Hover/click hit areas (requirement 十): one invisible 220×220 square
    /// per quadrant. They sit last in the ZStack so they win hit-testing,
    /// but the dial underneath has no interaction of its own — a click on
    /// the centre simply selects the enclosing quadrant. Hover brightens
    /// that quadrant's arc (`GaugeArc.emphasized`), click toggles the detail
    /// card; neither changes the layout.
    private var quadrantHitAreas: some View {
        ForEach(StatusQuadrant.allCases) { quadrant in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 220, height: 220)
                .position(x: quadrant.isLeft ? 110 : 330,
                          y: quadrant.isTop ? 110 : 330)
                .onHover { hovering in
                    if hovering { hoveredQuadrant = quadrant }
                    else if hoveredQuadrant == quadrant { hoveredQuadrant = nil }
                }
                .onTapGesture {
                    selectedQuadrant = selectedQuadrant == quadrant ? nil : quadrant
                }
                .accessibilityLabel(Text(quadrant.title))
                .accessibilityAddTraits(.isButton)
        }
    }

    /// Memory's history as a full-bleed 208×84 band — usage % over the last
    /// 2 minutes (fixed 0…100 domain, pinned so steady load reads as a level
    /// line, never a full-height slab). The bar-removal round (the outer arc
    /// already speaks the percentage, so the in-quadrant bar was redundant)
    /// handed the quadrant's whole interior to the curve: rows 136…220,
    /// x 220…428, rising from the seam, the exact mirror of `cpuBand` across
    /// the vertical seam. Clipped by `RingBandClip` (r 208) so the fill runs
    /// into the arc tubes; the dial covers the band's left end (x 220…279
    /// at these rows).
    private var memoryBand: some View {
        ZStack {
            bandGrid
            Sparkline(values: memoryHistory, domain: 0...100, color: Airi.chartPurple,
                      plotHeight: 50, plotAnchoredToBottom: true,
                      fillFade: 0, fillEnd: 0.85)
        }
        .frame(width: 208, height: 84)
        .clipShape(RingBandClip(origin: CGPoint(x: 220, y: 136)))
        .position(x: 324, y: 178)
        .allowsHitTesting(false)
    }

    /// Disk's curve is REAL disk I/O (read solid + write dashed, log scale,
    /// the dial's 0…8 domain) — labelled "Disk I/O" so it can't be mistaken
    /// for a capacity gauge (requirement 五: 磁盘 I/O 明确标注).
    ///
    /// Full-bleed 208×84 band, the exact mirror of `cpuBand` about the
    /// y 220 seam — same frame, same `bandGrid` furniture, same plot
    /// mapping, x 12…220 from the ring arc to the vertical seam, rows
    /// 220…304. The top bands rise FROM the seam; this one HANGS from it
    /// (`scaleEffect(y: -1)` flips the rendered layer in place — vertical
    /// only, so the data still reads oldest→newest left→right, and the
    /// fill's crest-anchored fade mirrors exactly). The dial covers the
    /// band's right end (x 161…220 behind the disc), same tuck as `cpuBand`'s.
    private var diskIOBand: some View {
        ZStack {
            ZStack {
                bandGrid
                Sparkline(values: diskReadHistory, domain: 0...8,
                          color: Airi.warning,
                          plotHeight: 50, plotAnchoredToBottom: true,
                          fillFade: 0, fillEnd: 0.85)
                // The write series shares the read series' EXACT mapping
                // (plotHeight 50 + seam anchor): with the full-height
                // default its 0…8 ratio mapped over 84pt and hung far
                // deeper than the read line, breaking the mirror.
                Sparkline(values: diskWriteHistory, domain: 0...8,
                          color: Airi.warning.opacity(0.55), filled: false,
                          plotHeight: 50, plotAnchoredToBottom: true,
                          lineWidth: 1.3)
            }
            .scaleEffect(y: -1)
            // The I/O label rides the band's lower-left corner (the hanging
            // wave occupies the seam side), un-flipped. The 20pt leading
            // inset keeps the full "磁盘 I/O" inside the ring: at this depth
            // (y ≈ 293–301) the r 208 clip's inner edge is at x ≈ 28.
            Text(L("Disk I/O"))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Airi.neutral500)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomLeading)
                .padding(.leading, 20)
                .padding(.bottom, 3)
        }
        .frame(width: 208, height: 84)
        .clipShape(RingBandClip(origin: CGPoint(x: 12, y: 220)))
        .position(x: 116, y: 262)
        .allowsHitTesting(false)
    }

    /// Battery's level history (0…100) as the exact mirror of `memoryBand`:
    /// same frame, same `bandGrid`, same plot mapping (domain 0…100,
    /// plotHeight 50, seam anchor) with the battery tint — so at any given
    /// level the battery line hangs exactly as far below the seam as an
    /// equal memory level rises above it. The fill is the same
    /// crest-anchored glow (it fades out below the line, so a flat level
    /// never renders as a solid slab). Before two samples land it shows the
    /// waiting-for-samples state instead of a fake line (offset right of
    /// the dial's lower crescent).
    private var batteryBand: some View {
        ZStack {
            ZStack {
                bandGrid
                if batteryHistory.count >= 2 {
                    Sparkline(values: batteryHistory, domain: 0...100,
                              color: batteryTint,
                              plotHeight: 50, plotAnchoredToBottom: true,
                              fillFade: 0, fillEnd: 0.85)
                }
            }
            .scaleEffect(y: -1)
            if batteryHistory.count < 2 {
                Text(L("Waiting for samples…"))
                    .font(.system(size: 8))
                    .foregroundStyle(Airi.neutral400)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 100)
                    .offset(x: 16)
            }
        }
        .frame(width: 208, height: 84)
        .clipShape(RingBandClip(origin: CGPoint(x: 220, y: 220)))
        .position(x: 324, y: 262)
        .allowsHitTesting(false)
    }

    /// The sector seams: 1pt radial hairlines at 12/3/6/9 o'clock, from the
    /// centre dial's edge (the opaque face covers the first point or two) to
    /// just inside the arc band (r 200). Half opacity — the round-2 0.35
    /// vanished against the board; this reads at a glance yet stays a
    /// hairline, not a bar.
    private var sectorDividers: some View {
        Path { path in
            for quarter in 0..<4 {
                let angle = Double(quarter) * .pi / 2
                let dx = sin(angle)
                let dy = -cos(angle)          // quarter 0 points at 12 o'clock
                path.move(to: CGPoint(x: 220 + 58 * dx, y: 220 + 58 * dy))
                path.addLine(to: CGPoint(x: 220 + 200 * dx, y: 220 + 200 * dy))
            }
        }
        .stroke(Airi.neutral400.opacity(0.5),
                style: StrokeStyle(lineWidth: 1))
        .allowsHitTesting(false)
    }

    /// The CPU time-series chart as a full-bleed 208×84 band — x 12…220
    /// from the ring arc to the vertical seam, rows 136…220 from just under
    /// the read-out stack (bottom ≈133) to the horizontal seam. The
    /// bar-removal round (the outer arc already speaks the percentage, so
    /// the in-quadrant bar was redundant) handed the quadrant's whole
    /// interior back to the curve: the band retook the 42pt strip the bar
    /// had taken in the unification round. The layer clips itself with
    /// `RingBandClip` (r 208), so the grid and the area fill run all the
    /// way into the arc and the quadrant tubes painted above (`ringArcs`)
    /// cover the trimmed edge. The mapping: the domain floor maps to the
    /// canvas BOTTOM edge (`plotAnchoredToBottom`) — the baseline rides the
    /// y 220 separator — and `plotHeight` 50 is ~60% of the 84pt band, so
    /// the trend uses most of the freed height while the fill's fade still
    /// dies out between the line and the baseline (`fillEnd` 0.85). The
    /// read-out stack paints ABOVE this layer (later in `gaugeBoard`'s
    /// ZStack), and the opaque centre dial is painted last over the layer's
    /// right end.
    private var cpuBand: some View {
        ZStack {
            bandGrid
            Sparkline(values: cpuHistory, domain: 0...40, color: Airi.primary,
                      plotHeight: 50, plotAnchoredToBottom: true,
                      fillFade: 0, fillEnd: 0.85)
        }
        .frame(width: 208, height: 84)
        .clipShape(RingBandClip(origin: CGPoint(x: 12, y: 136)))
        .position(x: 116, y: 178)
        .allowsHitTesting(false)
    }

    /// The bands' chart furniture, drawn UNDER the polylines: a 1pt
    /// baseline riding the layer's seam-side edge plus two even fainter
    /// horizontal grid lines at the thirds of the band — evenly spaced,
    /// spanning the full clipped width. Ink token (`neutral950`), not a
    /// surface token: `neutral100` sits only ~1/255 over the page
    /// background in BOTH appearances (dark #171717 on #121212, light
    /// #F5F5F5 on white) — the round-5 render's row scan found no line at
    /// all. `neutral950` is the flipped ink colour, so 0.10 lands ≈#292929
    /// over the dark board and ≈#E7E7E7 over the light page — one clear
    /// notch either way. The grid lines are the band's QUIETEST ink:
    /// sampled off the close-up, the baseline runs ~23-26/255 over its
    /// board while the faintest upper rule reads ~5/255 — a fifth of the
    /// baseline's contrast. `neutral950` is #FAFAFA in dark (`AiriTheme`),
    /// so alpha × 232 is the delta over the board: 0.09 lands at Δ≈21 —
    /// the reference's contrast, still clearly the fainter furniture. The
    /// 208/84 literals are this layer's frame. (Shared by all four bands;
    /// the two bottom bands flip this whole grid with their layer, which
    /// lands the baseline on the seam from below — the exact mirror.)
    private var bandGrid: some View {
        ZStack {
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let y = 84 * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: 208, y: y))
                }
            }
            .stroke(Airi.neutral950.opacity(0.09),
                    style: StrokeStyle(lineWidth: 1))
            // Bottom-anchored rect, not a stroke on y = h: a centred stroke
            // would paint its lower half a hair outside the frame.
            Rectangle()
                .fill(Airi.neutral950.opacity(0.10))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(width: 208, height: 84)
        .allowsHitTesting(false)
    }

    private var quadrantGrid: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                cpuBlock
                Spacer(minLength: 0)
                memoryBlock
            }
            Spacer(minLength: 0)
            // The bottom-left sector belongs to disk: its stack is positioned
            // against the board centre in `diskSector`, so this row keeps
            // only the battery. The stack mirrors the top stacks about the
            // diameter (rows 307…371, padding bottom 49 = padding top 49)
            // and needs NO x-offset: at this depth the dial (bottom edge
            // 279) is far above, so it sits at x 232…344, column-aligned
            // with the memory stack above.
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                if battery.present { batteryBlock } else { noBatteryBlock }
            }
        }
        // 76/49/49 is the mirror of itself: the top stacks' outer corners
        // sit at √(124² + 151²) = 195.4 (top edge, y 69) and the battery
        // stack's bottom edge at y 371 lands on the same 195.4 radius —
        // the ring band's inner edge is 202 (see `gaugeBoard`), so every
        // painted corner clears it. Stacks paint ABOVE the full-bleed
        // layers in `gaugeBoard`'s ZStack — text is never painted over.
        .padding(.top, 49)
        .padding(.bottom, 49)
        .padding(.horizontal, 76)
    }

    /// Text-only: the chart lives in `cpuSectorChart` — a full-bleed layer
    /// starting just below this stack, painted beneath it (the reference
    /// board's CPU chart carries no 50% guide).
    private var cpuBlock: some View {
        quadrant(L("CPU"), icon: "cpu", tint: Airi.primary,
                 value: cpu.usage.percentFormatted,
                 sub: L("Last 2 minutes"))
    }

    private var memoryBlock: some View {
        quadrant(L("Memory"), icon: "memorychip", tint: Airi.chartPurple,
                 value: mem.pressure.percentFormatted,
                 sub: "\(mem.usedBytes.bytesFormatted) / \(mem.totalBytes.bytesFormatted)")
    }

    /// Icon + big percentage + status text only — the reference battery card
    /// carries no gauge (unlike memory, whose bar IS in the reference). The
    /// sub-caption speaks the three battery states honestly (requirement 七):
    /// charge flowing → 充电中, pack full → 已充满, on the plug otherwise →
    /// 电源适配器, and only a true unplugged read is 使用电池.
    private var batteryBlock: some View {
        quadrant(L("Battery"),
                 icon: battery.charging ? "battery.100.bolt" : "battery.100",
                 tint: batteryTint,
                 value: battery.percentage.percentFormatted,
                 sub: batterySubCaption)
    }

    private var batterySubCaption: String {
        if battery.charging { return L("Charging") }
        if battery.full { return L("Fully charged") }
        if battery.plugged { return L("AC power") }
        return L("On battery")
    }

    private var noBatteryBlock: some View {
        quadrant(L("Battery"), icon: "battery.0", tint: Airi.neutral400,
                 value: "—", sub: L("No battery"))
    }

    /// One quadrant read-out — icon chip, big percentage, caption — fixed
    /// 112pt wide so the blocks keep one internal rhythm. All gauges and
    /// curves are full-bleed board layers (`cpuBand`/`memoryBand`/
    /// `diskIOBand`/`batteryBand`) positioned against the board; this stack
    /// carries only the text.
    private func quadrant(
        _ title: String, icon: String, tint: Color,
        value: String, sub: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                // Near-solid tint chip with a dark glyph, as in the reference
                // board — the washed-out 0.14 wash read as a disabled icon
                // next to its saturated counterpart.
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Airi.onTintGlyph)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint))
                Text(title)
                    .font(Airi.caption2Font.weight(.medium))
                    .foregroundStyle(Airi.neutral500)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Airi.neutral950)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 1)
                // Numbers roll instead of snapping on each 1 s tick
                // (requirement 8.1: 数值变化平滑过渡).
                .contentTransition(.numericText())
                .animation(Airi.controlAnimation, value: value)
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
                .animation(Airi.controlAnimation, value: sub)
        }
        .frame(width: 112, alignment: .leading)
    }

    /// Disk owns the bottom-left sector — title, big percentage and
    /// used/total (the capacity detail lives in the arc + detail card; the
    /// quadrant's band is I/O, not capacity). Anchored as the exact mirror
    /// of the CPU stack about the y 220 seam: rows 307…371 (centre y 339,
    /// mirror of the top stacks' 69…133), clear of the dial (bottom edge
    /// 279) and of the hanging I/O band (220…304).
    private var diskSector: some View {
        quadrant(L("Disk"), icon: "internaldrive", tint: Airi.warning,
                 value: disk.usedFraction.percentFormatted,
                 sub: "\(disk.usedBytes.bytesFormatted) / \(disk.totalBytes.bytesFormatted)")
        .position(x: 152, y: 339)
        .animation(Airi.controlAnimation, value: disk.usedFraction)
    }

    /// Network IS the centre dial (round 3: disk went back to the bottom-left
    /// sector, so the dial returns to what it carried in the first ring
    /// round): the big white download rate over the small gray upload rate,
    /// with the dual-series trace — solid green download with its
    /// crest-anchored gradient fill, amber dashed upload without one — under
    /// them. There is no 0…1 fraction to encode, so the ring is a static,
    /// restrained green hub rather than a gauge. 118pt gives the chart room
    /// to breathe: the 88×34 chart (round 4, up from 84×26) keeps its PAINTED
    /// extent inside the ring — the download fade completes at 80% of the
    /// frame (`fillEnd`), so the lowest painted corners are the fill's at
    /// √(44² + 26.7²) ≈ 51.5 from the centre, clearing the ring's inner edge
    /// (r 53); the frame's own bottom corners (r ≈ 55) hold no paint.
    private var networkDial: some View {
        ZStack {
            // Opaque page base under the glass: keeps the face solid over
            // whatever the board puts behind it (since round 6 the CPU
            // sector chart and the memory bar's corner run under it again —
            // this opaque face is what lets the sector layers stay
            // full-bleed).
            Circle()
                .fill(Airi.pageBackground)
                .overlay(Circle().fill(Airi.cardBackground))
                .overlay(Circle().fill(Airi.chartGreen.opacity(0.04)))
            // The reference's centre ring is a LIT green tube of the outer
            // arcs' family — measured (86,242,137) on the close-up, i.e.
            // chartGreen at full strength plus bloom. The round-6 review's
            // 0.35 wash rendered (53,92,59), reading as a muted grey-green
            // hoop (finding ⑥); full opacity lands ≈(74,222,128) and the
            // glow below bridges the rest. The restraint the earlier rounds
            // wanted lives in the ring's 6pt weight and static value, not
            // in a washed stroke.
            //
            // Activity feedback (requirement 8.3): with a reference
            // bandwidth configured (`status.referenceBandwidthMbps` > 0) the
            // ring carries a REAL activity arc — speed ÷ reference, clamped,
            // so it is a honest fraction. Without one there is no 100% to
            // encode, so the ring only breathes: brightness lifts with a
            // log-scaled lamp (saturates ≈10 GB/s) and never implies a
            // percentage. Idle restores the base look.
            Circle()
                .stroke(Airi.chartGreen.opacity(0.82 + 0.18 * activityHint),
                        lineWidth: 6)
                .frame(width: 112, height: 112)
                .shadow(color: Airi.chartGreen
                    .opacity((0.25 + 0.30 * activityHint) * glow),
                        radius: 4 + 3 * activityHint)
                .animation(Airi.controlAnimation, value: activityHint)
            if let activity = StatusEngine.referenceBandwidthActivity(engine.sample) {
                Circle()
                    .trim(from: 0, to: max(0.004, activity))
                    .stroke(Airi.chartGreen,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 112, height: 112)
                    .rotationEffect(.degrees(-90))
                    .animation(Airi.controlAnimation, value: activity)
            }
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(rateText(net.rateIn))/s")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: 80)
                .foregroundStyle(Airi.neutral950)
                HStack(spacing: 3) {
                    // Gray, matching the rate it annotates — the amber arrow
                    // read as a warning rather than as part of the label.
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(rateText(net.rateOut))/s")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: 80)
                .foregroundStyle(Airi.neutral500)
                ZStack {
                    // Round 4: the download fill completes INSIDE the frame —
                    // fillEnd 0.8 kills the gradient four-fifths of the way
                    // down, so the frame's bottom edge stays clean over the
                    // exposed dial face (fillFade 0 still pins the tail at
                    // zero — no surviving tint anywhere).
                    Sparkline(values: netDownHistory, domain: 0...8,
                              color: Airi.chartGreen, filled: true, fillFade: 0,
                              fillEnd: 0.8)
                    // Upload: the chart-palette amber (round 4 retired the
                    // lime here, consuming the orphan `chartAmber` token).
                    Sparkline(values: netUpHistory, domain: 0...8,
                              color: Airi.chartAmber, filled: false)
                }
                .frame(width: 88, height: 34)
            }
            // Review round 1: the ink block sat high in the dial — gaps
            // ≈18pt above / 27pt below (measured off the render at 1x; my
            // row scan: 18.6 / 33.7, direction agreeing). The text's ink-top
            // gap and the chart's fade-out tail hold no paint, so the visual
            // block rides high of the centred layout: shift +4.5pt from the
            // old −2 to centre the read content.
            .offset(y: 2.5)
        }
        .frame(width: 118, height: 118)
        // The green wash and hairline shadow let the disc read against the
        // page in either appearance (cardBackground alone is invisible on the
        // light page — both are white).
        .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    }

    /// Same light rule as `GaugeArc`: a halo on white is a smudge, so the
    /// centre ring throws half the light in light mode.
    @Environment(\.colorScheme) private var colorScheme
    private var glow: Double { colorScheme == .dark ? 1 : 0.5 }

    /// Log-scaled activity lamp for the dial ring (0…1, saturates ≈10 GB/s):
    /// brightness only — never shown as a percentage.
    private var activityHint: Double {
        StatusEngine.activityBrightness(engine.sample)
    }

    private var batteryTint: Color {
        if battery.charging { return Airi.success }
        if battery.percentage < 0.15 { return Airi.danger }
        if battery.percentage < 0.30 { return Airi.warning }
        return Airi.success
    }


    /// deepened the fade to the close-up's melt-to-black foot and de-white'd

    // MARK: - Quadrant detail card

    /// Click-through detail panel (requirement 十): one card whose rows swap
    /// by the selected quadrant. Field lists follow the doc verbatim — CPU
    /// 用户态/系统态/核心数, Memory 已用/可用/压缩/压力, Disk 总量/已用/
    /// 剩余/磁盘 I/O, Battery 电量/充电/电源. The history row reads the
    /// engine's ring buffers; an empty window reads "—", never a guess.
    @ViewBuilder private var quadrantDetailCard: some View {
        if let selected = selectedQuadrant {
            GroupedCard {
                HStack(spacing: 10) {
                    Image(systemName: selected.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected.tint)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected.tint.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selected.title)
                            .font(Airi.cardTitleFont)
                            .foregroundStyle(Airi.neutral950)
                        Text(L("Click the quadrant again to collapse"))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral400)
                    }
                    Spacer(minLength: Airi.space2)
                    Button {
                        selectedQuadrant = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Airi.neutral500)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                GroupedDivider()
                detailRows(for: selected)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder private func detailRows(for quadrant: StatusQuadrant) -> some View {
        switch quadrant {
        case .cpu:
            detailRow(L("Current usage"), String(format: "%.1f%%", cpu.usage * 100))
            detailRow(L("User share"), String(format: "%.0f%%", cpu.userShare * 100))
            detailRow(L("System share"), String(format: "%.0f%%", cpu.systemShare * 100))
            detailRow(L("Cores"), "\(cpu.cores)")
            detailRow(L("Last 2 minutes"), windowStats(cpuHistory))
        case .memory:
            detailRow(L("Used memory"),
                      "\(mem.usedBytes.bytesFormatted) / \(mem.totalBytes.bytesFormatted)")
            detailRow(L("Available memory"), mem.freeBytes.bytesFormatted)
            detailRow(L("Compressed memory"), mem.compressedBytes.bytesFormatted)
            detailRow(L("Memory pressure"), String(format: "%.1f%%", mem.pressure * 100))
            detailRow(L("Last 2 minutes"), windowStats(memoryHistory))
            // 口径 in plain sight (requirement 七): what "used" counts.
            detailRow(L("Basis"),
                      L("Used = active + wired + compressed − purgeable"))
        case .disk:
            detailRow(L("Volume"), disk.volumeName)
            detailRow(L("Total capacity"), disk.totalBytes.bytesFormatted)
            detailRow(L("Used capacity"), disk.usedBytes.bytesFormatted)
            detailRow(L("Available capacity"), disk.freeBytes.bytesFormatted)
            detailRow(L("Disk I/O"),
                      String(format: "%@/s %@ · %@/s %@",
                             rateText(engine.sample.diskReadRate), L("read"),
                             rateText(engine.sample.diskWriteRate), L("write")))
        case .battery:
            if battery.present {
                detailRow(L("Current charge"), String(format: "%.0f%%", battery.percentage * 100))
                detailRow(L("Charge state"),
                          battery.charging ? L("Charging")
                              : battery.full ? L("Fully charged") : L("Discharging"))
                detailRow(L("Power source"),
                          battery.plugged ? L("AC power") : L("Battery power"))
                detailRow(L("Last 2 minutes"), windowStats(batteryHistory))
            } else {
                detailRow(L("No battery"), L("This Mac has no battery"))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            Spacer(minLength: Airi.space2)
            Text(value)
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral950)
                .monospacedDigit()
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// min–max–avg over one history window (oldest→newest Doubles), or "—"
    /// while fewer than two samples exist.
    private func windowStats(_ values: [Double], unit: String = "%") -> String {
        guard values.count >= 2 else { return "—" }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let avg = values.reduce(0, +) / Double(values.count)
        return String(format: "%.1f–%.1f%@ · %@ %.1f%@",
                      minV, maxV, unit, L("avg"), avg, unit)
    }

    // MARK: - Processes

    private var processCard: some View {
        GroupedCard {
            processHeader
            GroupedDivider()
            if processes.isEmpty {
                // Never a silent blank card — a ps failure/permission hiccup
                // shows an explicit hint instead of "unfinished".
                Text(L("Process data unavailable"))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral400)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                processLegend
                processList
            }
            if let killFeedback {
                Text(killFeedback)
                    .font(Airi.caption2Font)
                    .foregroundStyle(killFeedback.hasPrefix("✗") ? Airi.danger : Airi.neutral500)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }

    private var processHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Airi.neutral500)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Airi.neutral500.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Top processes"))
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                Text(L("Sorted by CPU · refreshed every 2 seconds"))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer(minLength: Airi.space2)
            if !processes.isEmpty {
                Text("\(processes.count)")
                    .font(Airi.caption2Font.weight(.medium))
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Airi.neutral100.opacity(0.9)))
                    .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Column legend: two bare percentages with no labels were unreadable
    /// without knowing the column order.
    private var processLegend: some View {
        HStack(spacing: Airi.space2) {
            Text("PID").frame(width: 44, alignment: .leading)
            Text(L("Process"))
            Spacer()
            Text("CPU").frame(width: 52, alignment: .trailing)
            Text(L("Memory")).frame(width: 52, alignment: .trailing)
            Color.clear.frame(width: 18, height: 1)
        }
        .font(Airi.caption2Font)
        .foregroundStyle(Airi.neutral400)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var processList: some View {
        VStack(spacing: 0) {
            ForEach(Array(processes.enumerated()), id: \.element.id) { index, proc in
                if index > 0 { GroupedDivider(inset: 52) }
                ProcessRow(entry: proc) { entry in
                    killProcess(entry)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    /// Terminate a top process directly from the list (SIGTERM). Root-owned
    /// processes refuse the signal (EPERM) — surfaced as feedback instead of
    /// silently doing nothing.
    private func killProcess(_ entry: SystemStatus.ProcessEntry) {
        // Confirm first: the raw list includes loginwindow/cfprefsd — one
        // stray click logs the user out.
        pendingKill = entry
    }

    private func killConfirmed(_ entry: SystemStatus.ProcessEntry) {
        let result = kill(Int32(entry.pid), SIGTERM)
        if result == 0 {
            killFeedback = String(format: L("Sent TERM to %@ (pid %lld)"), entry.command, entry.pid)
        } else {
            killFeedback = "✗ " + String(format: L("Could not kill pid %lld — owned by root?"), entry.pid)
        }
        engine.sampleNow()   // refresh immediately; the process list is 2s-cadence
    }
}

/// One row of the Top-processes list: metrics plus a hover-revealed kill
/// button (the whole row is the hover target, keeping the action out of
/// sight until wanted — same pattern as the startup-items rows).
private struct ProcessRow: View {
    let entry: SystemStatus.ProcessEntry
    var onKill: (SystemStatus.ProcessEntry) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Airi.space2) {
            Text(String(entry.pid))
                .font(Airi.monoCaption2Font)
                .foregroundStyle(Airi.neutral400)
                .frame(width: 44, alignment: .leading)
            Text(entry.command)
                .font(Airi.footnoteFont)
                .foregroundStyle(Airi.neutral900)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(String(format: "%.1f%%", entry.cpu))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(entry.cpu > 50 ? Airi.danger : Airi.neutral700)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Text(String(format: "%.1f%%", entry.mem))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Group {
                if hovering {
                    Button { onKill(entry) } label: {
                        Image(systemName: "xmark.octagon")
                            .font(.system(size: 11))
                            .foregroundStyle(Airi.danger)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Kill process (SIGTERM)"))
                } else {
                    Color.clear.frame(width: 18, height: 18)
                }
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Doc requirement: every dashboard component previews with the Mock
/// provider — no system API, deterministic waveforms.
#Preview("Status · mock data") {
    StatusView(provider: MockStatusProvider())
        .frame(width: 900, height: 700)
}

/// Project artifact purger — `mo purge` with root selection.
struct PurgeView: View {
    var onClose: (() -> Void)?

    @State private var roots: [URL] = []
    @State private var rootError: String?
    @State private var artifacts: [PurgeEngine.Artifact] = []
    @State private var selected: Set<UUID> = []
    @State private var scanning = false
    @State private var purging = false
    @State private var purgeProgress: BatchProgress?
    @State private var resultText: String?
    @State private var confirmingPurge = false

    var selectedBytes: Int64 {
        artifacts.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Purge"), subtitle: L("Regenerable build artifacts in your project folders"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    rootsCard
                    if scanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Scanning project folders…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                        }
                        .padding(.top, 20)
                    }
                    ForEach(Array(artifacts.enumerated()), id: \.element.id) { _, artifact in
                        artifactRow(artifact)
                    }
                    if !artifacts.isEmpty {
                        HStack {
                            Text("\(selected.count) selected · \(selectedBytes.bytesFormatted)")
                                .font(Airi.captionFont).foregroundStyle(Airi.neutral500).monospacedDigit()
                            Spacer()
                            AiriButton(title: L("Select all"), variant: .secondary) {
                                selected = Set(artifacts.map(\.id))
                            }
                            AiriButton(title: purging ? L("Purging…") : L("Purge"), icon: "trash.fill", variant: .destructive,
                                       disabled: selected.isEmpty || purging,
                                       busy: purging) { confirmingPurge = true }
                        }
                    }
                    if let resultText {
                        SettingsCard {
                            Text(resultText).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Airi.neutral700).textSelection(.enabled)
                        }
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .overlay {
            if let purgeProgress { BatchProgressOverlay(progress: purgeProgress) }
        }
        .animation(Airi.controlAnimation, value: purgeProgress == nil)
        .confirmationDialog(
            Text(String(format: L("Purge %lld directories (%@)?"), selected.count, selectedBytes.bytesFormatted)),
            isPresented: $confirmingPurge,
            titleVisibility: .visible
        ) {
            Button(L("Purge"), role: .destructive) { purge() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Build artifacts are regenerated on the next build — but deletion here is immediate and NOT routed through the Trash."))
        }
        .onAppear {
            if roots.isEmpty {
                roots = PurgeEngine.RootsStore.load() ?? PurgeEngine.defaultRoots()
            }
        }
    }

    private var rootsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Text(L("Search roots")).font(Airi.cardTitleFont)
                ForEach(roots, id: \.path) { root in
                    HStack(spacing: Airi.space2) {
                        Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Airi.primary)
                        Text(displayPath(root)).font(Airi.footnoteFont).foregroundStyle(Airi.neutral700)
                            .lineLimit(1).truncationMode(.middle).help(root.path)
                        Spacer()
                        Button {
                            removeRoot(root)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Airi.neutral400)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if roots.isEmpty {
                    Text(L("Pick at least one folder to scan."))
                        .font(Airi.caption2Font).foregroundStyle(Airi.neutral500)
                }
                HStack(spacing: Airi.space2) {
                    // Panel, not a text field: the folder has to exist, so
                    // typing a path only ever produced "not found" errors.
                    AiriButton(title: L("Add Folder…"), icon: "folder.badge.plus",
                               variant: .secondary) { pickRoots() }
                    if roots.isEmpty {
                        Button(L("Restore default folders")) {
                            setRoots(PurgeEngine.defaultRoots())
                        }
                        .buttonStyle(.plain)
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.primary)
                    }
                    Spacer()
                    AiriButton(title: scanning ? L("Scanning…") : L("Scan"), icon: "magnifyingglass",
                               disabled: scanning || roots.isEmpty) {
                        Task { await scan() }
                    }
                }
                if let rootError {
                    Text(rootError)
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.danger)
                }
            }
        }
    }

    /// `~/…` instead of the full home prefix keeps long project paths readable.
    private func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Multi-select panel, starting in the last root so repeat picks are one
    /// click. "/" and the home folder are rejected for the same reason the old
    /// text field rejected them: walking them is not a project scan.
    private func pickRoots() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = L("Choose folders to scan")
        panel.prompt = L("Add")
        panel.directoryURL = roots.last ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return }

        var next = roots
        var rejected = false
        for url in panel.urls.map(\.standardizedFileURL) {
            guard url.path != "/", url.path != NSHomeDirectory() else {
                rejected = true
                continue
            }
            if !next.contains(url) { next.append(url) }
        }
        rootError = rejected ? L("Refusing to walk the whole disk / home folder") : nil
        setRoots(next)
    }

    private func removeRoot(_ root: URL) {
        rootError = nil
        setRoots(roots.filter { $0 != root })
    }

    /// Roots decide which rows are on screen, so changing the set clears them —
    /// a folder that was removed must not leave artifacts ticked for deletion.
    private func setRoots(_ next: [URL]) {
        guard next != roots else { return }
        roots = next
        PurgeEngine.RootsStore.save(next)
        artifacts = []
        selected = []
        resultText = nil
    }

    private func artifactRow(_ artifact: PurgeEngine.Artifact) -> some View {
        HStack(spacing: Airi.space2) {
            Toggle("", isOn: Binding(
                get: { selected.contains(artifact.id) },
                set: { on in
                    if on { selected.insert(artifact.id) } else { selected.remove(artifact.id) }
                }
            ))
            .toggleStyle(.checkbox).controlSize(.small).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.kind).font(.system(size: 12, weight: .medium)).foregroundStyle(Airi.neutral900)
                Text(artifact.projectPath).font(Airi.caption2Font).foregroundStyle(Airi.neutral500)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(artifact.bytes.bytesFormatted)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Airi.neutral700).monospacedDigit()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Airi.radiusCard).fill(Airi.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: Airi.radiusCard).strokeBorder(Airi.neutral200.opacity(0.6)).allowsHitTesting(false))
    }

    private func scan() async {
        scanning = true
        artifacts = []
        selected = []
        let rootsCopy = roots
        PetBus.shared.say(L("Scanning project folders…"), state: .scanning)
        let found = await PurgeEngine.scan(roots: rootsCopy)
        withAnimation(Airi.entranceCurve) {
            artifacts = found
            selected = Set(found.map(\.id))
        }
        scanning = false
        let total = found.reduce(0) { $0 + $1.bytes }
        PetBus.shared.say(found.isEmpty ? L("No artifacts found ✨")
                          : String(format: L("Found %lld artifact dirs (%@)"), found.count, total.bytesFormatted),
                          state: .celebrating)
    }

    private func purge() {
        purging = true
        let chosen = artifacts.filter { selected.contains($0.id) }
        purgeProgress = BatchProgress(title: L("Purging…"), done: 0, total: chosen.count)
        let startedAt = Date()
        Task {
            var ok: [(PurgeEngine.Artifact, String?)] = []
            var failed: [(PurgeEngine.Artifact, String)] = []
            for (index, artifact) in chosen.enumerated() {
                purgeProgress?.detail = artifact.projectPath
                let result = await Task.detached { PurgeEngine.purge([artifact]) }.value.first
                if let result {
                    if let err = result.1 {
                        failed.append((result.0, err))
                    } else {
                        ok.append(result)
                    }
                }
                purgeProgress?.done = index + 1
            }
            let freed = ok.reduce(0) { $0 + $1.0.bytes }
            var text = String(format: L("Removed %lld directories · %@ freed"), ok.count, freed.bytesFormatted)
            if !failed.isEmpty {
                text += "\n" + String(format: L("%lld failed"), failed.count) + ": " +
                    failed.prefix(3).map { "\($0.0.kind): \($0.1)" }.joined(separator: "; ")
            }
            let record = CleanRecord(
                date: Date(), sectionTitles: Array(Set(chosen.map(\.kind))).sorted(),
                requestedBytes: freed, freedBytes: freed, itemCount: chosen.count,
                items: ok.map {
                    CleanRecordItem(path: $0.0.url.path, bytes: $0.0.bytes, mode: .permanent,
                                    success: true, error: nil)
                } + failed.map {
                    CleanRecordItem(path: $0.0.url.path, bytes: $0.0.bytes, mode: .permanent,
                                    success: false, error: $0.1)
                }, source: .purge)
            HistoryStore.append(record)
            UXFeedback.success()
            PetBus.shared.say(String(format: L("Purged %@"), freed.bytesFormatted) + " 🧹", state: .celebrating)
            artifacts.removeAll { a in chosen.contains(where: { $0.id == a.id }) }
            selected = Set(artifacts.map(\.id))
            resultText = text
            await BatchProgressHold.until(startedAt)
            purgeProgress = nil
            purging = false
        }
    }
}

// MARK: - Sparkline (Canvas, not Swift Charts)

/// Clips a full-bleed sector layer to a circle centred on the board. `origin`
/// is the clipped frame's top-left corner in `gaugeBoard` coordinates
/// (440×440, centre (220, 220)); the radius defaults to the arc band's
/// CENTRELINE (r 208) — the band's trimmed edge sits under the lit,
/// near-opaque tube half, so the tube painted above covers the trim
/// completely. (The retired gauge bars passed 214, the tubes' outer edge;
/// the bands went back to the centreline when the bars left.) Apply it
/// BEFORE `.position`, so the shape travels with the frame it clips.
private struct RingBandClip: Shape {
    let origin: CGPoint
    var radius: CGFloat = 208

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: 220 - origin.x, y: 220 - origin.y)
        var path = Path()
        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                   width: radius * 2, height: radius * 2))
        return path
    }
}

/// One quadrant gauge of the status ring: a dim tint track spanning the
/// quadrant plus a lit stroke trimmed to `progress` × the quadrant's span.
/// Round 6 turns the four full-quadrant tubes into the metrics' percentage
/// gauges: the 0.20 tint track keeps the unlit remainder visible without
/// stealing the show, the lit stroke's round caps and the cardinal gaps are
/// untouched, and full-vs-part reads at a glance.
///
/// `start`/`end` are `Circle().trim` fractions (0 = 3 o'clock, increasing
/// clockwise), so callers pass 0.5125…0.7375 for "top-left" and the 9° gaps
/// at the cardinal points fall out of the numbers instead of being fudged
/// with rotations.
///
/// The quadrant is **backlit**, not just outlined. In the reference board the
/// arc's hue spills a short way into the quarter and dies out, so the panel
/// reads as a lit pane with a tube of light along its edge; a bare stroke on
/// black reads as a wire lying on top. Sampled off the reference: the stroke
/// is ~2 % of the board diameter, the glow reaches roughly half a stroke
/// width on each face plus a faint long tail, the *empty* track barely glows
/// at all, and the panel interior stays neutral (≈#131313 a third of the way
/// in). Those four numbers are the whole recipe — see the shadows below.
/// (Internal, not private: the smoke test drives `GaugeArc.span` — the
/// percentage rule — through the doc's 0/1/25/50/75/99/100% ladder.)
struct GaugeArc: View {
    var start: Double
    var end: Double
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 12
    /// Anchors the fill at `end` and grows it back toward `start` (`false`
    /// anchors at `start`). Round 6 puts it to work: every gauge anchors at
    /// the vertical-axis gap nearest it — 12 o'clock for the top pair, 6 for
    /// the bottom — and grows toward the arc's far end, so the four read as
    /// independent gauges sweeping away from the seams rather than one
    /// clockwise spiral. Top-left and bottom-right pass `true` (their `end`
    /// is the gap edge); top-right and bottom-left pass `false`.
    var reversed: Bool = false
    /// Hover state (requirement 十: 悬停边框略微变亮): the dim track lifts
    /// and the lit tube throws a touch more light. No layout change.
    var emphasized: Bool = false

    /// A glow on white is a smudge: the same shadow alphas that read as neon
    /// on the dark board turn into a brown stain around the light-mode ring,
    /// so the halo is halved there. The arcs keep their colour and weight; only
    /// the light they throw changes.
    @Environment(\.colorScheme) private var colorScheme
    private var glow: Double { colorScheme == .dark ? 1 : 0.5 }

    /// The gauge's lit span as `Circle().trim` fractions — the whole
    /// percentage rule in one testable pure function: `progress` (clamped to
    /// 0…1) scales the quadrant's `start…end` span; `reversed` anchors the
    /// fill at `end` and grows it back toward `start`. 0 progress returns a
    /// zero-length span (no visible arc), 1 the full quadrant.
    static func span(start: Double, end: Double,
                     progress: Double, reversed: Bool) -> (lower: Double, upper: Double) {
        let clamped = min(max(progress, 0), 1)
        if reversed {
            let lower = end - (end - start) * clamped
            return (lower, end)
        }
        return (start, start + (end - start) * clamped)
    }

    private var clamped: Double { min(max(progress, 0), 1) }
    private var litSpan: (lower: Double, upper: Double) {
        Self.span(start: start, end: end, progress: clamped, reversed: reversed)
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: start, to: end)
                .stroke(tint.opacity(emphasized ? 0.32 : 0.20),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(Airi.controlAnimation, value: emphasized)
            // A round cap on a 0-length stroke still paints a dot — at 0% the
            // quadrant must read as empty, not as "a little bit on".
            if clamped > 0.004 {
                Circle()
                    .trim(from: litSpan.lower, to: litSpan.upper)
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.72), tint],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // The interior light: three stacked Gaussian shadows, tight
                    // and bright to wide and faint. Two other shapes were tried
                    // against the reference and both lost: one wide shadow (the
                    // old radius-10 one) washed the quarter grey, and a tinted
                    // sector wedge — even blurred — showed its two straight
                    // edges at the quadrant gaps, reading as a panel pasted
                    // behind the arc. Shadows have no core and no edges, so the
                    // light falls off smoothly on both faces of the tube.
                    .shadow(color: tint.opacity((0.50 + (emphasized ? 0.10 : 0)) * glow),
                            radius: lineWidth * 0.22)
                    .shadow(color: tint.opacity(0.30 * glow), radius: lineWidth * 0.80)
                    .shadow(color: tint.opacity(0.14 * glow), radius: lineWidth * 1.80)
            }
        }
        // Keep the stroke inside the frame so the ring's outer edge is exactly
        // the board inset (otherwise the glow clips against the ZStack bounds).
        .padding(lineWidth / 2)
        .animation(Airi.controlAnimation, value: clamped)
    }
}

/// Hand-drawn sparkline for the status metric cards.
///
/// Swift Charts was the obvious tool, but it only rasterises with a real
/// display attached: through `--probe-render` (offscreen `cacheDisplay`) it
/// draws NOTHING, so every chart-layout regression was invisible to the probe
/// while looking fine on screen. A Canvas path renders identically in both
/// paths, costs less for four 40pt cards, and lets the y-domain be pinned —
/// Charts auto-scaled to the data range, which turned a flat 25% CPU line
/// into a full-height filled block.
private struct Sparkline: View {
    let values: [Double]
    let domain: ClosedRange<Double>
    let color: Color
    /// Download-style series get an area fill; secondary series (upload) stay
    /// a thin dashed line so two series can share one band without mud.
    var filled: Bool = true
    /// Height the polyline is mapped into, from the anchored edge. nil = the
    /// full canvas. The area PATH still closes at the canvas floor (harmless
    /// — the fade's depth is `fillEnd`'s job), so a chart that maps its line
    /// into a sub-band (the CPU sector: 33.2 of 83, anchored to the floor)
    /// still lets the gradient spend the remaining depth dying out.
    var plotHeight: CGFloat? = nil
    /// Anchor the plot to the canvas FLOOR instead of the top (the CPU
    /// sector): the domain's LOWER bound then maps to the bottom edge —
    /// the layer's baseline — and the series climbs from it, `plotHeight`
    /// capping how far peaks may rise (40% of the band at the CPU call
    /// site). Default false keeps the top-anchored mapping the centre dial's
    /// charts use.
    var plotAnchoredToBottom: Bool = false
    /// Stroke width override for the small quadrant minis (the 2.2pt default
    /// is tuned for the big bands; a 22pt-tall curve reads chunky with it).
    /// 0 keeps the per-`filled` defaults. Declared BEFORE `fillFade` so the
    /// mini call sites read value-then-furniture.
    var lineWidth: CGFloat = 0
    /// Alpha the area fill decays to at the fade's end (the canvas floor, or
    /// `fillEnd`). 0 wherever the floor is exposed, because any surviving
    /// tail draws a hard, still-tinted edge across it (the CPU fill's step
    /// sampled at (27,32,40) over the (18,18,18) board; the centre dial's
    /// chart floor sits on the disc face). 0.06 only made sense where an arc
    /// masked the floor — no current call site has that.
    var fillFade: Double = 0.06
    /// Fraction of the canvas height where the fade COMPLETES (alpha reaches
    /// `fillFade`); nil = the canvas floor. Round 4 pinned the centre dial's
    /// filled chart to 0.8 — a gradient that only reaches zero at the floor
    /// reads as "filled to the bottom" on the small dial, whose face is
    /// exposed below. The CPU sector passes 0.85: on its full-bleed 83pt
    /// layer (floor = the y 220 separator) the gradient dies out between
    /// the line and the baseline, so no surviving tint butts against the
    /// separator. Values beyond 1 clamp to the floor.
    var fillEnd: CGFloat? = nil

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2, size.width > 2, size.height > 2 else { return }
            let lo = domain.lowerBound
            let hi = max(domain.upperBound, lo + 0.000_1)
            let stepX = size.width / CGFloat(values.count - 1)
            let plot = min(plotHeight ?? size.height, size.height)

            func y(_ value: Double) -> CGFloat {
                let clamped = Swift.min(Swift.max(value, lo), hi)
                let ratio = (clamped - lo) / (hi - lo)
                return plotAnchoredToBottom
                    ? size.height - plot * CGFloat(ratio)
                    : plot * (1 - CGFloat(ratio))
            }

            func point(_ index: Int) -> CGPoint {
                CGPoint(x: CGFloat(index) * stepX, y: y(values[index]))
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count {
                line.addLine(to: point(index))
            }

            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                // Anchor the fade at the line's crest, not the band top: a
                // pinned domain parks the series away from the band top, and
                // a top-anchored gradient had already decayed to its tail by
                // the time it reached the line — the fill sampled as bare
                // background in the offscreen render. From the crest the fill
                // is strong right at the line and decays toward `fillEnd`
                // (to `fillFade`): the reference's hug-the-line glow. Canvas
                // clamps the gradient past its end, so everything under that
                // line stays at `fillFade` — with fillFade 0 the frame's
                // bottom band holds no paint at all.
                let crest = values.map { y($0) }.min() ?? 0
                let fadeEnd = max(crest + 1,
                                  min(fillEnd.map { $0 * size.height } ?? size.height,
                                      size.height))
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.55), color.opacity(fillFade)]),
                    startPoint: CGPoint(x: 0, y: crest),
                    endPoint: CGPoint(x: 0, y: fadeEnd)))
            }

            // Miter joins: the reference's per-sample polyline has sharp
            // corners, and a round join blunted every crest by the stroke's
            // half-width. (The path itself was already sample-to-sample
            // straight — the smooth look came from the old sine seeds plus
            // this rounding.)
            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth > 0 ? lineWidth
                                              : (filled ? 2.2 : 1.3),
                                              lineCap: .round,
                                              lineJoin: .miter,
                                              dash: filled ? [] : [3, 3]))
        }
    }
}
