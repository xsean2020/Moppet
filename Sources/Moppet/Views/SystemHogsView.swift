import SwiftUI

/// System space hogs — the surfaces a file-level cleaner could never reach:
/// APFS/Time Machine local snapshots, Docker's VM disk, Homebrew's old
/// Cellar versions, plus READ-ONLY reports for iOS backups and Mail
/// (real user data — never deleted here, the size report hands off to
/// Finder / the owning app instead).
///
/// Layout: one headline (what can be freed now, and who makes it up) →
/// one grouped list of the three reclaimers (Docker / Homebrew / snapshots)
/// → one grouped list of the read-only reports. Previously every engine was
/// its own `SettingsCard` with its own private table, so five slabs of equal
/// weight left the eye nowhere to start, and the three "size" columns landed
/// at three different x-positions.
struct SystemHogsView: View {
    var onClose: (() -> Void)?

    @State private var scanning = false
    @State private var snapshots: [SnapshotEngine.Snapshot] = []
    @State private var purgeable: Int64 = 0
    @State private var selectedSnapshots: Set<String> = []
    @State private var docker: DockerEngine.Usage?
    @State private var dockerAvailable = false
    @State private var brewPreview: HomebrewEngine.Preview?
    @State private var brewAvailable = false
    @State private var reports: [SystemHogs.HogReport] = []
    @State private var busyAction: String?
    @State private var lastMessage: String?
    /// Errors used to render in the success colour — a failed prune looked
    /// exactly like a finished one.
    @State private var lastMessageIsError = false
    @State private var confirmAction: ConfirmationAction?

    /// Offscreen probe hook (`--probe-render spacehogs`). `.task` never fires
    /// in the probe's invisible window, so without a seed the render showed
    /// three "Checking…" rows and an empty snapshot list — i.e. it could not
    /// verify the very layout it exists for.
    static var debugSeed = false

    enum ConfirmationAction: Identifiable {
        case deleteSnapshots([String])
        case dockerPrune
        case brewCleanup
        var id: String {
            switch self {
            case .deleteSnapshots(let ids): return "snapshots-\(ids.count)"
            case .dockerPrune: return "docker"
            case .brewCleanup: return "brew"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Space Hogs"),
                       subtitle: L("Snapshot, Docker and Homebrew disk usage — with warnings where it hurts"),
                       onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    if !Permissions.hasFullDiskAccess { fdaBanner }
                    if let lastMessage { messageBanner(lastMessage) }
                    summaryCard
                    enginesCard
                    snapshotsCard
                    readOnlyCard
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
            Text(confirmTitle),
            isPresented: Binding(get: { confirmAction != nil },
                                 set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Confirm"), role: .destructive) { runConfirmed() }
            Button(L("Cancel"), role: .cancel) { confirmAction = nil }
        } message: {
            Text(confirmMessage)
        }
        .task {
            if Self.debugSeed { seedForProbe(); return }
            await scan()
        }
    }

    // MARK: - Scan

    private func scan() async {
        scanning = true
        async let snaps = SnapshotEngine.list()
        async let dockerTask = DockerEngine.usage()
        async let brew = HomebrewEngine.preview()
        let measured = SystemHogs.reports()
        snapshots = await snaps
        purgeable = SnapshotEngine.purgeableBytes()
        docker = await dockerTask
        dockerAvailable = DockerEngine.installed
        brewPreview = await brew
        brewAvailable = HomebrewEngine.installed
        reports = measured
        selectedSnapshots = []
        scanning = false
    }

    /// Synthetic-but-plausible data for the offscreen probe only.
    private func seedForProbe() {
        scanning = false
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        snapshots = (0..<7).map { (i: Int) -> SnapshotEngine.Snapshot in
            // Step by 6h, not 1h: the row prints the DATE only, so hourly
            // samples rendered as seven identical-looking rows.
            let stamp = base.addingTimeInterval(Double(-i) * 6 * 3600)
            return SnapshotEngine.Snapshot(id: "2026-10-\(28 - i)-120000", date: stamp)
        }
        purgeable = 18_400_000_000

        var usage = DockerEngine.Usage()
        usage.imagesCount = 6
        usage.imagesBytes = 1_400_000_000
        usage.imagesReclaimable = 700_000_000
        usage.containersCount = 2
        usage.containersBytes = 820_000_000
        usage.containersReclaimable = 820_000_000
        usage.volumesCount = 4
        usage.volumesBytes = 1_600_000_000
        usage.cacheCount = 1
        usage.cacheBytes = 420_000_000
        usage.cacheReclaimable = 420_000_000
        docker = usage
        dockerAvailable = true

        brewPreview = HomebrewEngine.Preview(
            lines: [
                "/opt/homebrew/Cellar/node/18.0.0 (2,140 files, 75.5MB)",
                "/opt/homebrew/Cellar/python@3.11/3.11.4 (1,880 files, 62.1MB)",
                "/opt/homebrew/Cellar/go/1.21.0 (1,204 files, 48.7MB)",
                "/opt/homebrew/Cellar/openssl@3/3.1.2 (612 files, 22.4MB)",
                "/opt/homebrew/Cellar/ffmpeg/6.0 (204 files, 18.9MB)",
                "/opt/homebrew/Cellar/ca-certificates/2023-08-22 (3 files, 0.2MB)"
            ],
            totalBytes: 227_800_000)
        brewAvailable = true

        reports = [
            SystemHogs.HogReport(kind: .iosBackups, path: SystemHogs.iosBackupPath,
                                 bytes: 6_200_000_000, measurable: true),
            SystemHogs.HogReport(kind: .mail, path: SystemHogs.mailPath,
                                 bytes: 1_100_000_000, measurable: true),
            SystemHogs.HogReport(kind: .messages, path: SystemHogs.messagesPath,
                                 bytes: 0, measurable: false)
        ]
        lastMessage = nil
    }

    // MARK: - Banners

    private var fdaBanner: some View {
        SettingsCard(padding: 14) {
            HStack(spacing: Airi.space2) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Airi.warning)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Airi.warning.opacity(0.12)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Full Disk Access is off"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(L("Mail, Messages and backup sizes can't be measured without it — grant access in System Settings."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Airi.space2)
                AiriButton(title: L("Open Settings"), icon: "arrow.up.right.square",
                           variant: .secondary) {
                    Task { @MainActor in Permissions.openFullDiskAccessSettings() }
                }
            }
        }
    }

    /// Action feedback as a tinted strip instead of a bare green sentence
    /// floating between two cards.
    private func messageBanner(_ text: String) -> some View {
        let tint = lastMessageIsError ? Airi.danger : Airi.success
        return HStack(spacing: 6) {
            Image(systemName: lastMessageIsError
                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(Airi.captionFont)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(lastMessageIsError ? Airi.danger : Airi.successStrong)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
            .fill(tint.opacity(0.12)))
    }

    // MARK: - Headline

    /// The page's single focal point: what the two actionable engines can
    /// free, split into a legend and a composition bar so the number has a
    /// source. Snapshots are excluded — macOS does not expose their size.
    private var summaryCard: some View {
        let dockerFree = docker?.totalReclaimable ?? 0
        let brewFree = brewPreview?.totalBytes ?? 0
        let total = dockerFree + brewFree
        return SettingsCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: Airi.space3) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Reclaimable now"))
                            .font(Airi.caption2Font.weight(.medium))
                            .foregroundStyle(Airi.neutral500)
                        Text(total.bytesFormatted)
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(total == 0 ? Airi.neutral500 : Airi.neutral950)
                        Text(L("Docker prune + Homebrew cleanup — snapshots are managed by macOS"))
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.neutral500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Airi.space2)
                    VStack(alignment: .trailing, spacing: 5) {
                        legendRow(L("Docker"), dockerFree, tint: .blue)
                        legendRow(L("Homebrew"), brewFree, tint: .orange)
                    }
                }
                compositionBar(dockerFree: dockerFree, brewFree: brewFree)
            }
        }
    }

    private func legendRow(_ title: String, _ bytes: Int64, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint.opacity(0.7))
                .frame(width: 6, height: 6)
            Text(title)
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            Text(bytes.bytesFormatted)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Airi.neutral900)
                .frame(minWidth: 58, alignment: .trailing)
        }
    }

    /// Proportional bar: the headline number alone could not say whether
    /// Docker or Homebrew was the reason to open this page.
    private func compositionBar(dockerFree: Int64, brewFree: Int64) -> some View {
        let total = dockerFree + brewFree
        let share = total > 0 ? CGFloat(dockerFree) / CGFloat(total) : 0
        return GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule()
                    .fill(Color.blue.opacity(0.55))
                    .frame(width: max(3, (geo.size.width - 2) * share))
                Capsule()
                    .fill(Color.orange.opacity(0.55))
            }
        }
        .frame(height: 6)
        .opacity(total > 0 ? 1 : 0)
    }

    // MARK: - Engines (Docker + Homebrew)

    /// Both engines in ONE grouped list: they are the two halves of the
    /// headline number, and two separate slabs made them look unrelated.
    private var enginesCard: some View {
        GroupedCard {
            dockerGroup
            GroupedDivider()
            brewGroup
        }
    }

    private var dockerGroup: some View {
        VStack(spacing: 0) {
            engineHeader(symbol: "cube", tint: .blue,
                         title: L("Docker"), subtitle: dockerSubtitle) {
                AiriButton(title: L("Prune"), icon: "wind",
                           disabled: docker == nil,
                           busy: busyAction == "docker") {
                    confirmAction = .dockerPrune
                }
                // Fixed action column: the row's own size lives in the
                // subtitle, so the buttons only name the verb — but the
                // column still has to fit the widest localized label
                // ("清理旧版本" + icon wrapped to three lines at 92pt).
                .frame(width: 124, alignment: .trailing)
            }
            if let docker {
                dockerDetail(docker)
            } else if !dockerAvailable {
                noteRow(L("Docker is not installed."))
            } else if !scanning {
                noteRow(L("Docker is installed but not running."))
            }
        }
    }

    /// Per-type table inside an inset panel — the same "sub-list belongs to
    /// this row" treatment the Clean page uses for expanded sections.
    private func dockerDetail(_ usage: DockerEngine.Usage) -> some View {
        let rows: [(String, Int, Int64)] = [
            (L("Images"), usage.imagesCount, usage.imagesBytes),
            (L("Containers"), usage.containersCount, usage.containersBytes),
            (L("Volumes"), usage.volumesCount, usage.volumesBytes),
            (L("Build cache"), usage.cacheCount, usage.cacheBytes)
        ]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(L("Type")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Count")).frame(width: 44, alignment: .trailing)
                Text(L("Size")).frame(width: 76, alignment: .trailing)
            }
            .font(Airi.caption2Font.weight(.medium))
            .foregroundStyle(Airi.neutral400)
            .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Airi.hairline)
                        .frame(height: 1)
                }
                usageRow(row.0, row.1, row.2)
            }
            Text(L("Prune removes STOPPED containers, unused networks, dangling images and build cache. Running containers and volume data are never touched."))
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.neutral500)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Airi.neutral50.opacity(0.35)))
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private var brewGroup: some View {
        VStack(spacing: 0) {
            engineHeader(symbol: "shippingbox.fill", tint: .orange,
                         title: L("Homebrew Old Versions"), subtitle: brewSubtitle) {
                AiriButton(title: L("Clean up"), icon: "sparkles",
                           disabled: !(brewPreview.map { !$0.isEmpty } ?? false),
                           busy: busyAction == "brew") {
                    confirmAction = .brewCleanup
                }
                .frame(width: 124, alignment: .trailing)
            }
            if let brewPreview, !brewPreview.isEmpty {
                brewDetail(brewPreview)
            }
        }
    }

    private func brewDetail(_ preview: HomebrewEngine.Preview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(preview.lines.prefix(5).enumerated()), id: \.offset) { index, line in
                if index > 0 {
                    Rectangle()
                        .fill(Airi.hairline)
                        .frame(height: 1)
                }
                HStack(spacing: Airi.space2) {
                    Text(HomebrewEngine.displayName(for: line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Airi.neutral700)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Airi.space2)
                    Text(HomebrewEngine.sizeText(for: line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .help(line)
            }
            if preview.lines.count > 5 {
                Text(String(format: L("…and %lld more"), preview.lines.count - 5))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .padding(.top, 4)
            }
            Text(L("Removes old Cellar versions and expired downloads — rollback means reinstalling."))
                .font(Airi.caption2Font)
                .foregroundStyle(Airi.warningStrong)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Airi.neutral50.opacity(0.35)))
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    // MARK: - Snapshots

    private var snapshotsCard: some View {
        GroupedCard {
            engineHeader(symbol: "camera.on.rectangle", tint: Airi.primary,
                         title: L("APFS Local Snapshots"), subtitle: snapshotsSubtitle) {
                AiriButton(title: String(format: L("Delete %lld Selected"),
                                         selectedSnapshots.count),
                           icon: "trash", variant: .destructive,
                           disabled: selectedSnapshots.isEmpty || busyAction == "snapshots",
                           busy: busyAction == "snapshots") {
                    confirmAction = .deleteSnapshots(Array(selectedSnapshots).sorted())
                }
                .frame(width: 172, alignment: .trailing)
            }
            if snapshots.isEmpty {
                noteRow(scanning ? L("Checking…")
                                 : L("No local snapshots — nothing to reclaim here."))
            } else {
                snapshotList
            }
        }
    }

    private var snapshotList: some View {
        // macOS exposes snapshot dates but not per-snapshot sizes (they share
        // blocks); the header's purgeable figure is the group's honest size.
        let newest = Array(snapshots.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Airi.space2) {
                Text(L("Snapshots share data blocks, so macOS can't size them individually — the figure above is the whole group's purgeable space."))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Airi.space2)
                // 7 checkboxes to reach "reclaim it all" was pure friction.
                // Sits with the list, not in the footer: it acts on the rows.
                Button(allSnapshotsSelected ? L("Deselect all") : L("Select all")) {
                    toggleAllSnapshots()
                }
                .buttonStyle(.plain)
                .font(Airi.caption2Font.weight(.medium))
                .foregroundStyle(Airi.primary)
                .fixedSize()
            }
            .padding(.bottom, 6)
            ForEach(newest) { snapshot in
                HStack(spacing: Airi.space2) {
                    Toggle("", isOn: Binding(
                        get: { selectedSnapshots.contains(snapshot.id) },
                        set: { on in
                            if on { selectedSnapshots.insert(snapshot.id) }
                            else { selectedSnapshots.remove(snapshot.id) }
                        }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                    Text(snapshot.date.map { L10n.date($0) } ?? snapshot.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Airi.neutral700)
                    Spacer(minLength: Airi.space2)
                }
                .padding(.vertical, 4)
            }
            if snapshots.count > newest.count {
                Text(String(format: L("…and %lld older"), snapshots.count - newest.count))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral400)
                    .padding(.top, 4)
            }
            HStack(spacing: Airi.space2) {
                Text(L("Deleting a snapshot is permanent and removes that restore point."))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.warningStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Airi.neutral50.opacity(0.35)))
        .padding(.leading, 52)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private var allSnapshotsSelected: Bool {
        !snapshots.isEmpty && selectedSnapshots.count >= snapshots.count
    }

    private func toggleAllSnapshots() {
        if allSnapshotsSelected {
            selectedSnapshots.removeAll()
        } else {
            selectedSnapshots = Set(snapshots.map(\.id))
        }
    }

    // MARK: - Read-only reports

    private var readOnlyCard: some View {
        GroupedCard {
            engineHeader(symbol: "internaldrive", tint: Airi.neutral500,
                         title: L("Protected Data (read-only)"),
                         subtitle: L("Real user data — Moppet reports the size and hands you to the tool that manages it.")) {
                EmptyView()
            }
            ForEach(Array(reports.enumerated()), id: \.element.id) { index, report in
                GroupedDivider()
                reportRow(report)
            }
        }
    }

    private func reportRow(_ report: SystemHogs.HogReport) -> some View {
        HStack(spacing: Airi.space2) {
            Image(systemName: Self.reportIcon(report.kind))
                .font(.system(size: 12))
                .foregroundStyle(Airi.neutral400)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.reportTitle(report.kind))
                    .font(Airi.bodyFont)
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                Text(report.needsFullDiskAccess
                     ? L("Needs Full Disk Access to measure")
                     : report.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Airi.caption2Font)
                    .foregroundStyle(report.needsFullDiskAccess ? Airi.warningStrong : Airi.neutral400)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Airi.space2)
            Text(report.needsFullDiskAccess ? L("Unknown") : report.bytes.bytesFormatted)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(report.needsFullDiskAccess ? Airi.neutral400 : Airi.neutral900)
                .frame(width: 76, alignment: .trailing)
            Button(report.kind == .iosBackups && report.measurable
                   ? L("Manage in Finder") : L("Show in Finder")) {
                Task { @MainActor in
                    Permissions.revealInFinder(report.kind == .iosBackups && report.measurable
                                               ? SystemHogs.iosBackupPath : report.path)
                }
            }
            .buttonStyle(.plain)
            .font(Airi.caption2Font.weight(.medium))
            .foregroundStyle(Airi.primary)
            // Fixed column: "Manage in Finder" and "Show in Finder" are
            // different widths, which left the size column ragged.
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Row primitives

    /// Shared header for every group: icon chip · title/subtitle · one
    /// trailing control. Same anatomy as the Optimize page's task rows.
    private func engineHeader<Accessory: View>(
        symbol: String, tint: Color, title: String, subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            hogIcon(symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Airi.cardTitleFont)
                    .foregroundStyle(Airi.neutral950)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Airi.space2)
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func usageRow(_ label: String, _ count: Int, _ bytes: Int64) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(Airi.bodyFont)
                .foregroundStyle(Airi.neutral700)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Text(bytes.bytesFormatted)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Airi.neutral900)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func noteRow(_ text: String) -> some View {
        Text(text)
            .font(Airi.captionFont)
            .foregroundStyle(Airi.neutral400)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 52)
            .padding(.trailing, 14)
            .padding(.bottom, 12)
    }

    private func hogIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12)))
    }

    // MARK: - Copy

    private var dockerSubtitle: String {
        if !dockerAvailable { return L("Not installed") }
        guard let docker else { return scanning ? L("Checking…") : L("Daemon not running") }
        if docker.totalBytes == 0 && docker.imagesCount == 0 { return L("Nothing stored") }
        return String(format: L("%1$@ used · %2$@ reclaimable"),
                      docker.totalBytes.bytesFormatted,
                      docker.totalReclaimable.bytesFormatted)
    }

    private var brewSubtitle: String {
        guard brewAvailable else { return L("Not installed") }
        guard let brewPreview else {
            return scanning ? L("Checking…")
                            : L("Homebrew is installed — no old versions to clean")
        }
        if brewPreview.isEmpty { return L("Homebrew is installed — no old versions to clean") }
        return String(format: L("%1$@ in %2$lld items would be removed"),
                      brewPreview.totalBytes.bytesFormatted, Int64(brewPreview.lines.count))
    }

    private var snapshotsSubtitle: String {
        if snapshots.isEmpty {
            return scanning ? L("Checking…")
                            : L("Time Machine hourly backups holding purgeable disk space")
        }
        return String(format: L("%1$lld snapshots · about %2$@ purgeable"),
                      snapshots.count, purgeable.bytesFormatted)
    }

    private var confirmTitle: String {
        switch confirmAction {
        case .deleteSnapshots(let ids): return String(format: L("Delete %lld local snapshots?"), Int64(ids.count))
        case .dockerPrune: return L("Run docker system prune?")
        case .brewCleanup: return L("Run brew cleanup?")
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        switch confirmAction {
        case .deleteSnapshots: return L("Local snapshots are Time Machine restore points on this disk. Deleted ones cannot be recovered.")
        case .dockerPrune: return L("Stopped containers, unused networks, dangling images and build cache will be removed permanently.")
        case .brewCleanup: return L("Old Cellar versions and expired downloads are removed. Rolling back means reinstalling the formula.")
        case nil: return ""
        }
    }

    // MARK: - Actions

    private func runConfirmed() {
        let action = confirmAction
        confirmAction = nil
        Task {
            switch action {
            case .deleteSnapshots(let ids):
                busyAction = "snapshots"
                var failures = 0
                for id in ids {
                    do { _ = try await SnapshotEngine.delete(id) } catch { failures += 1 }
                }
                lastMessage = failures == 0
                    ? String(format: L("Deleted %lld snapshots"), Int64(ids.count))
                    : String(format: L("Deleted with %lld failures"), failures)
                lastMessageIsError = failures > 0
                busyAction = nil
                await scan()
            case .dockerPrune:
                busyAction = "docker"
                do {
                    let output = try await DockerEngine.prune()
                    lastMessage = output.isEmpty
                        ? L("Docker prune finished — nothing to remove")
                        : L("Docker prune finished")
                    lastMessageIsError = false
                    recordHog(path: "docker system prune", bytes: 0, success: true)
                } catch {
                    lastMessage = error.localizedDescription
                    lastMessageIsError = true
                    recordHog(path: "docker system prune", bytes: 0, success: false, error: error.localizedDescription)
                }
                busyAction = nil
                await scan()
            case .brewCleanup:
                busyAction = "brew"
                let freed = brewPreview?.totalBytes ?? 0
                do {
                    _ = try await HomebrewEngine.run()
                    lastMessage = String(format: L("brew cleanup finished — about %@ reclaimed"), freed.bytesFormatted)
                    lastMessageIsError = false
                    recordHog(path: "brew cleanup", bytes: freed, success: true)
                } catch {
                    lastMessage = error.localizedDescription
                    lastMessageIsError = true
                    recordHog(path: "brew cleanup", bytes: 0, success: false, error: error.localizedDescription)
                }
                busyAction = nil
                await scan()
            case nil:
                break
            }
        }
    }

    /// Snapshot/Docker/brew operations join the audit trail like every
    /// other removal, so History answers "what freed that space".
    private func recordHog(path: String, bytes: Int64, success: Bool, error: String? = nil) {
        HistoryStore.append(CleanRecord(
            date: Date(), sectionTitles: [L("Space Hogs")],
            requestedBytes: bytes, freedBytes: success ? bytes : 0,
            itemCount: 1,
            items: [CleanRecordItem(path: path, bytes: bytes, mode: .permanent,
                                    success: success, error: error)],
            source: .hogs))
    }

    private static func reportTitle(_ kind: SystemHogs.HogReport.Kind) -> String {
        switch kind {
        case .iosBackups: return L("iPhone / iPad Backups")
        case .mail: return L("Mail Attachments & Data")
        case .messages: return L("Messages Attachments & Data")
        }
    }

    private static func reportIcon(_ kind: SystemHogs.HogReport.Kind) -> String {
        switch kind {
        case .iosBackups: return "iphone"
        case .mail: return "envelope"
        case .messages: return "message"
        }
    }
}
