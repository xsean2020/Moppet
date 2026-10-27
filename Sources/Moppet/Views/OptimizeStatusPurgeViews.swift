import SwiftUI
import Charts

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
                    ForEach(Array(OptimizeEngine.catalog.enumerated()), id: \.element.id) { _, task in
                        taskCard(task)
                    }
                    if !results.isEmpty {
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
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
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

    private func taskCard(_ task: OptimizeEngine.OptimizeTask) -> some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                Image(systemName: task.requiresAdmin ? "lock.shield" : "wand.and.rays")
                    .font(.system(size: 15))
                    .foregroundStyle(task.requiresAdmin ? Airi.warning : Airi.primary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(Airi.cardTitleFont).foregroundStyle(Airi.neutral950)
                    Text("\(task.detail) · \(task.category)")
                        .font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                }
                Spacer()
                if runningTask == task.id {
                    ProgressView().controlSize(.small)
                } else {
                    AiriButton(title: L("Run"), variant: .secondary) { confirmTask = task }
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

/// Live system monitor — `mo status` dashboard with sparkline history.
struct StatusView: View {
    var onClose: (() -> Void)?

    @State private var cpu = SystemStatus.cpu
    @State private var mem = SystemStatus.memory
    @State private var net = SystemStatus.network
    @State private var battery = SystemStatus.battery
    @State private var processes: [SystemStatus.ProcessEntry] = []

    // Rolling history for the Charts sparklines (Swift Charts, macOS 13+).
    @State private var cpuHistory: [Double] = []
    @State private var memHistory: [Double] = []
    @State private var netDownHistory: [Double] = []
    @State private var netUpHistory: [Double] = []
    /// Last kill attempt feedback (shown under the process list).
    @State private var killFeedback: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Status"), subtitle: String(format: L("Live system health · uptime %@"), SystemStatus.uptimeFormatted), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Airi.space3),
                                        GridItem(.flexible(), spacing: Airi.space3)],
                              spacing: Airi.space3) {
                        metricCard("cpu", "CPU", "\(cpu.usage.percentFormatted)", cpu.usage, icon: "cpu") {
                            sparkline(cpuHistory, color: Airi.primary)
                        }
                        metricCard("mem", "Memory",
                                   "\(mem.usedBytes.bytesFormatted) / \(mem.totalBytes.bytesFormatted)",
                                   mem.pressure, icon: "memorychip") {
                            sparkline(memHistory, color: Airi.chartPurple)
                        }
                        metricCard("net", "Network",
                                   "↓\(Int64(net.rateIn).bytesFormatted)/s ↑\(Int64(net.rateOut).bytesFormatted)/s",
                                   nil, icon: "network") {
                            ZStack {
                                sparkline(netUpHistory, color: Airi.chartAmber)
                                sparkline(netDownHistory, color: Airi.chartGreen)
                            }
                        }
                        if battery.present {
                            metricCard("bat", "Battery",
                                       "\(Int(battery.percentage * 100))%\(battery.charging ? " ⚡️" : "")",
                                       battery.percentage, icon: "battery.100")
                        }
                    }
                    diskCard
                    processCard
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
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

    private func sample() {
        // ps spawn + wait is a blocking call — run it OFF the main actor
        // (this used to stall the UI every 2 seconds).
        Task.detached {
            let net = SystemStatus.network
            let cpu = SystemStatus.cpu
            let mem = SystemStatus.memory
            let procs = SystemStatus.topProcesses()
            let battery = SystemStatus.battery
            await MainActor.run {
                self.net = net
                self.cpu = cpu
                self.mem = mem
                self.processes = procs
                self.battery = battery
                append(&cpuHistory, cpu.usage * 100)
                append(&memHistory, mem.pressure * 100)
                // Log-ish scale so bursts stay visible next to idle.
                append(&netDownHistory, log10(1 + net.rateIn))
                append(&netUpHistory, log10(1 + net.rateOut))
            }
        }
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    @ViewBuilder
    private func sparkline(_ history: [Double], color: Color) -> some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("t", index),
                    y: .value("v", value)
                )
                .foregroundStyle(
                    LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                LineMark(
                    x: .value("t", index),
                    y: .value("v", value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 34)
    }

    private func metricCard<Spark: View>(_ id: String, _ title: String, _ value: String,
                                        _ fraction: Double?, icon: String,
                                        @ViewBuilder spark: () -> Spark = { EmptyView() }) -> some View {
        SettingsCard(padding: Airi.space3) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).font(Airi.captionFont).foregroundStyle(Airi.primary)
                    Text(title).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Airi.neutral950)
                    .monospacedDigit()
                spark()
                if let fraction {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Airi.neutral200)
                            Capsule()
                                .fill(fraction > 0.85 ? Airi.danger : Airi.primary)
                                .frame(width: max(6, proxy.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private var diskCard: some View {
        let disk = DiskInfo.snapshot()
        return SettingsCard(padding: Airi.space3) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive").font(Airi.captionFont).foregroundStyle(Airi.primary)
                    Text(String(format: L("Disk · %@"), disk.volumeName)).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                    Spacer()
                    Text(String(format: L("%@ free"), disk.freeBytes.bytesFormatted)).font(Airi.captionFont)
                        .foregroundStyle(Airi.success).monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Airi.neutral200)
                        Capsule()
                            .fill(LinearGradient(colors: [Airi.primary400, Airi.primary600],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, proxy.size.width * disk.usedFraction))
                    }
                }
                .frame(height: 8)
            }
        }
    }

    private var processCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Text(L("Top processes")).font(Airi.cardTitleFont)
                if processes.isEmpty {
                    // Never a silent blank card — a ps failure/permission
                    // hiccup shows an explicit hint instead of "unfinished".
                    Text(L("Process data unavailable"))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral400)
                        .padding(.vertical, 6)
                }
                ForEach(processes) { proc in
                    ProcessRow(entry: proc) { entry in
                        killProcess(entry)
                    }
                }
                if let killFeedback {
                    Text(killFeedback)
                        .font(Airi.caption2Font)
                        .foregroundStyle(killFeedback.hasPrefix("✗") ? Airi.danger : Airi.neutral500)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Terminate a top process directly from the list (SIGTERM). Root-owned
    /// processes refuse the signal (EPERM) — surfaced as feedback instead of
    /// silently doing nothing.
    @State private var pendingKill: SystemStatus.ProcessEntry?

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
        sample()   // refresh immediately; the process list is 2s-cadence
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

/// Project artifact purger — `mo purge` with root selection.
struct PurgeView: View {
    var onClose: (() -> Void)?

    @State private var roots: [URL] = []
    @State private var newRoot = ""
    @State private var newRootError: String?
    @State private var artifacts: [PurgeEngine.Artifact] = []
    @State private var selected: Set<UUID> = []
    @State private var scanning = false
    @State private var purging = false
    @State private var resultText: String?
    @State private var confirmingPurge = false
    /// Explicit focus plumbing for the root field (terminal-launched apps
    /// can lack a working click-to-first-responder chain — see HANDOFF §6.24).
    @FocusState private var newRootFocused: Bool

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
                            AiriButton(title: L("Purge"), icon: "trash.fill", variant: .destructive,
                                       disabled: selected.isEmpty || purging) { confirmingPurge = true }
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
            if roots.isEmpty { roots = PurgeEngine.defaultRoots() }
        }
    }

    private var rootsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Airi.space2) {
                Text(L("Search roots")).font(Airi.cardTitleFont)
                ForEach(roots, id: \.path) { root in
                    HStack {
                        Image(systemName: "folder").font(Airi.footnoteFont).foregroundStyle(Airi.neutral400)
                        Text(root.path).font(Airi.footnoteFont).foregroundStyle(Airi.neutral700)
                        Spacer()
                        Button {
                            roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Airi.neutral400)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: Airi.space2) {
                    TextField("~/another/projects/dir", text: $newRoot)
                        .textFieldStyle(.plain)
                        .font(Airi.footnoteFont)
                        .foregroundStyle(Airi.neutral900)
                        .focused($newRootFocused)
                        .onTapGesture { newRootFocused = true }
                        .onSubmit { addRoot() }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Airi.neutral50))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                            newRootError == nil ? Airi.neutral200 : Airi.danger.opacity(0.6),
                            lineWidth: 1))
                    AiriButton(title: L("Add"), variant: .secondary) { addRoot() }
                    AiriButton(title: scanning ? L("Scanning…") : L("Scan"), icon: "magnifyingglass",
                               disabled: scanning || roots.isEmpty) {
                        Task { await scan() }
                    }
                }
                if let newRootError {
                    Text(newRootError)
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.danger)
                }
            }
        }
    }

    /// Add the typed folder to the search roots. A silent no-op on a bad
    /// path reads as "the button is broken" — surface the failure instead.
    private func addRoot() {
        let raw = newRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let expanded = raw.hasPrefix("~")
            ? NSHomeDirectory() + raw.dropFirst() : raw
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard url.path != "/", url.path != NSHomeDirectory() else {
            newRootError = L("Refusing to walk the whole disk / home folder")
            return
        }
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if !roots.contains(url) { roots.append(url) }
            newRootError = nil
            newRoot = ""
        } else {
            newRootError = String(format: L("Folder not found: %@"), url.path)
        }
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
        Task {
            let results = await Task.detached { PurgeEngine.purge(chosen) }.value
            let ok = results.filter { $0.1 == nil }
            let freed = ok.reduce(0) { $0 + $1.0.bytes }
            var text = String(format: L("Removed %lld directories · %@ freed"), ok.count, freed.bytesFormatted)
            let failures = results.filter { $0.1 != nil }
            if !failures.isEmpty {
                text += "\n" + String(format: L("%lld failed"), failures.count) + ": " +
                    failures.prefix(3).map { "\($0.0.kind): \($0.1!)" }.joined(separator: "; ")
            }
            let record = CleanRecord(
                date: Date(), sectionTitles: ["Purge"],
                requestedBytes: freed, freedBytes: freed, itemCount: results.count,
                items: results.map {
                    CleanRecordItem(path: $0.0.url.path, bytes: $0.0.bytes, mode: .permanent,
                                    success: $0.1 == nil, error: $0.1)
                })
            HistoryStore.append(record)
            UXFeedback.success()
            PetBus.shared.say(String(format: L("Purged %@"), freed.bytesFormatted) + " 🧹", state: .celebrating)
            artifacts.removeAll { a in chosen.contains(where: { $0.id == a.id }) }
            selected = Set(artifacts.map(\.id))
            resultText = text
            purging = false
        }
    }
}
