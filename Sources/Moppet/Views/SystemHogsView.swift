import SwiftUI

/// System space hogs — the surfaces a file-level cleaner could never reach:
/// APFS/Time Machine local snapshots, Docker's VM disk, Homebrew's old
/// Cellar versions, plus READ-ONLY reports for iOS backups and Mail
/// (real user data — never deleted here, the size report hands off to
/// Finder / the owning app instead).
struct SystemHogsView: View {
    var onClose: (() -> Void)?

    @State private var scanning = false
    @State private var snapshots: [SnapshotEngine.Snapshot] = []
    @State private var selectedSnapshots: Set<String> = []
    @State private var docker: DockerEngine.Usage?
    @State private var dockerAvailable = false
    @State private var brewPreview: HomebrewEngine.Preview?
    @State private var brewAvailable = false
    @State private var reports: [SystemHogs.HogReport] = []
    @State private var busyAction: String?
    @State private var lastMessage: String?
    @State private var confirmAction: ConfirmationAction?

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
                    if !Permissions.hasFullDiskAccess {
                        fdaBanner
                    }
                    if let lastMessage {
                        Text(lastMessage)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    snapshotsCard
                    dockerCard
                    brewCard
                    readOnlyCard
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
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
        .task { await scan() }
    }

    // MARK: - Scan

    private func scan() async {
        scanning = true
        async let snaps = SnapshotEngine.list()
        async let dockerTask = DockerEngine.usage()
        async let brew = HomebrewEngine.preview()
        let measured = SystemHogs.reports()
        snapshots = await snaps
        docker = await dockerTask
        dockerAvailable = DockerEngine.installed
        brewPreview = await brew
        brewAvailable = HomebrewEngine.installed
        reports = measured
        selectedSnapshots = []
        scanning = false
    }

    // MARK: - FDA banner

    private var fdaBanner: some View {
        SettingsCard(padding: Airi.space3) {
            HStack(spacing: Airi.space3) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(Airi.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Full Disk Access is off"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(L("Mail, Messages and backup sizes can't be measured without it — grant access in System Settings."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
                AiriButton(title: L("Open Settings"), icon: "arrow.up.right.square") {
                    Task { @MainActor in Permissions.openFullDiskAccessSettings() }
                }
            }
        }
    }

    // MARK: - Snapshots

    private var snapshotsCard: some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                hogIcon("camera.on.rectangle", tint: Airi.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("APFS Local Snapshots"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(String(format: L("%lld snapshots — Time Machine hourly backups holding purgeable disk space"),
                                snapshots.count))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
            }
            if snapshots.isEmpty {
                Text(scanning ? L("Checking…") : L("No local snapshots — nothing to reclaim here."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
            } else {
                let newest = snapshots.prefix(6)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(newest)) { snapshot in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { selectedSnapshots.contains(snapshot.id) },
                                set: { on in
                                    if on { selectedSnapshots.insert(snapshot.id) }
                                    else { selectedSnapshots.remove(snapshot.id) }
                                }))
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .labelsHidden()
                            Text(snapshot.date?
                                .formatted(date: .abbreviated, time: .shortened) ?? snapshot.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Airi.neutral700)
                            Spacer()
                        }
                    }
                    if snapshots.count > newest.count {
                        Text(String(format: L("…and %lld older"), snapshots.count - newest.count))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral400)
                    }
                }
                HStack {
                    Text(L("Deleting a snapshot is permanent and removes that restore point."))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.warning)
                    Spacer()
                    AiriButton(title: String(format: L("Delete %lld Selected"),
                                            selectedSnapshots.count),
                               icon: "trash", variant: .destructive,
                               disabled: selectedSnapshots.isEmpty) {
                        confirmAction = .deleteSnapshots(Array(selectedSnapshots).sorted())
                    }
                }
            }
        }
    }

    // MARK: - Docker

    private var dockerCard: some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                hogIcon("hardware.macbook", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Docker"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(dockerSubtitle)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
            }
            if let docker {
                VStack(alignment: .leading, spacing: 4) {
                    usageRow(L("Images"), docker.imagesCount, docker.imagesBytes)
                    usageRow(L("Containers"), docker.containersCount, docker.containersBytes)
                    usageRow(L("Volumes"), docker.volumesCount, docker.volumesBytes)
                    usageRow(L("Build cache"), docker.cacheCount, docker.cacheBytes)
                }
                HStack {
                    Text(L("Prune removes STOPPED containers, unused networks, dangling images and build cache. Running containers and volume data are never touched."))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                    Spacer()
                    AiriButton(title: L("Prune Unused"), icon: "wind",
                               busy: busyAction == "docker") {
                        confirmAction = .dockerPrune
                    }
                }
            } else if !dockerAvailable {
                Text(L("Docker is not installed."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral400)
            } else if !scanning {
                Text(L("Docker is installed but not running."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral400)
            }
        }
    }

    private func usageRow(_ label: String, _ count: Int, _ bytes: Int64) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Airi.neutral700)
            Spacer()
            Text("\(count)").font(.system(size: 12, design: .rounded))
                .foregroundStyle(Airi.neutral500).monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
            Text(bytes.bytesFormatted)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Airi.neutral900)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
        }
    }

    // MARK: - Homebrew

    private var brewCard: some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                hogIcon("shippingbox.fill", tint: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Homebrew Old Versions"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(brewSubtitle)
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
            }
            if let brewPreview, !brewPreview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(brewPreview.lines.prefix(5).enumerated()), id: \.offset) { _, line in
                        Text((line as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Airi.neutral700)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(line)
                    }
                    if brewPreview.lines.count > 5 {
                        Text(String(format: L("…and %lld more"), brewPreview.lines.count - 5))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral400)
                    }
                }
                HStack {
                    Text(L("Removes old Cellar versions and expired downloads — rollback means reinstalling."))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.warning)
                    Spacer()
                    AiriButton(title: L("Run brew cleanup"), icon: "sparkles",
                               busy: busyAction == "brew") {
                        confirmAction = .brewCleanup
                    }
                }
            }
        }
    }

    // MARK: - Read-only reports

    private var readOnlyCard: some View {
        SettingsCard {
            HStack(spacing: Airi.space3) {
                hogIcon("internaldrive", tint: Airi.neutral500)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Protected Data (read-only)"))
                        .font(Airi.cardTitleFont)
                        .foregroundStyle(Airi.neutral950)
                    Text(L("Real user data — Moppet reports the size and hands you to the tool that manages it."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
            }
            ForEach(reports) { report in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.reportTitle(report.kind))
                            .font(.system(size: 13))
                            .foregroundStyle(Airi.neutral900)
                        Text(report.needsFullDiskAccess
                             ? L("Needs Full Disk Access to measure")
                             : report.path)
                            .font(Airi.caption2Font)
                            .foregroundStyle(report.needsFullDiskAccess
                                             ? Airi.warning : Airi.neutral400)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(report.needsFullDiskAccess
                         ? L("Unknown") : report.bytes.bytesFormatted)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Airi.neutral900)
                        .monospacedDigit()
                    if report.kind == .iosBackups, report.measurable {
                        Button(L("Manage in Finder")) {
                            Task { @MainActor in
                                Permissions.revealInFinder(SystemHogs.iosBackupPath)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Airi.caption2Font.weight(.medium))
                        .foregroundStyle(Airi.primary)
                    } else {
                        Button(L("Show in Finder")) {
                            Task { @MainActor in
                                Permissions.revealInFinder(report.path)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(Airi.caption2Font.weight(.medium))
                        .foregroundStyle(Airi.primary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Helpers

    private func hogIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral100))
    }

    private var dockerSubtitle: String {
        if !dockerAvailable { return L("Not installed") }
        guard let docker else { return scanning ? L("Checking…") : L("Daemon not running") }
        return String(format: L("%@ across images, containers, volumes and build cache"),
                      docker.totalBytes.bytesFormatted)
    }

    private var brewSubtitle: String {
        guard brewAvailable else { return L("Not installed") }
        guard let brewPreview else { return scanning ? L("Checking…") : L("No old versions to clean") }
        if brewPreview.isEmpty { return L("No old versions to clean") }
        return String(format: L("%1$@ in %2$lld items would be removed"),
                      brewPreview.totalBytes.bytesFormatted, Int64(brewPreview.lines.count))
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
                busyAction = nil
                await scan()
            case .dockerPrune:
                busyAction = "docker"
                do {
                    let output = try await DockerEngine.prune()
                    lastMessage = output.isEmpty
                        ? L("Docker prune finished — nothing to remove")
                        : L("Docker prune finished")
                    recordHog(path: "docker system prune", bytes: 0, success: true)
                } catch {
                    lastMessage = error.localizedDescription
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
                    recordHog(path: "brew cleanup", bytes: freed, success: true)
                } catch {
                    lastMessage = error.localizedDescription
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
}
