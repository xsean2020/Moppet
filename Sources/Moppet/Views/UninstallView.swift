import SwiftUI
import AppKit

/// App uninstaller — `mo uninstall` as a native review-then-trash flow.
struct UninstallView: View {
    var onClose: (() -> Void)?

    @State private var apps: [UninstallEngine.AppEntry] = []
    @State private var sizes: [String: Int64] = [:]
    /// Deletable user-data bytes per app id — what "uninstall + data" sweeps
    /// beyond the bundle. Streams in behind the app-sizing round.
    @State private var dataSizes: [String: Int64] = [:]
    @State private var sizingProgress: (done: Int, total: Int)? = nil
    @State private var loadingPulse = false
    @State private var selectedApps: Set<String> = []
    @State private var loading = true
    @State private var batchRunning = false
    /// Progress of whatever destructive batch is running (batch uninstall,
    /// single uninstall, or the admin leftover sweep) — one source of truth
    /// for both the inline pill and the center overlay.
    @State private var batch: BatchProgress?
    @State private var batchResult: UninstallEngine.BatchOutcome?
    @State private var searchText = ""
    @State private var selection: UninstallEngine.AppEntry?
    @State private var related: [UninstallEngine.RelatedFile] = []
    @State private var selectedRelated: Set<UUID> = []
    @State private var loadingRelated = false
    @State private var resultText: String?
    @State private var busy = false
    @State private var adminResultText: String?
    /// Shown when a delete was refused with the App Management TCC error —
    /// FDA does not cover app-bundle deletion on macOS 15+.
    @State private var showAppManagementHint = false
    /// App Management recovery: the bundle to re-probe and the work to redo
    /// once the permission appears. The TCC prompt (if it ever comes) is
    /// raised by the failed delete itself; a recorded deny never re-prompts,
    /// so recovery = jump to Settings, then resume on return to the app.
    @State private var pendingAppManagementURL: URL?
    @State private var pendingAppManagementWork: (() -> Void)?
    @State private var openedAppManagementSettings = false
    /// Batch-uninstall confirmation (deletion is permanent now, so it must ask).
    @State private var confirmingBatch = false
    /// Single-app confirmation — permanent deletion needs an explicit confirm.
    @State private var confirmingSingle = false
    @State private var singleRemoveData = false
    /// Explicit focus plumbing for the search box (terminal-launched apps
    /// can lack a working click-to-first-responder chain — see HANDOFF §6.24).
    @FocusState private var searchFocused: Bool

    var filteredApps: [UninstallEngine.AppEntry] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Uninstall"), subtitle: L("Delete apps and sweep their leftovers"), onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            HStack(spacing: 0) {
                // app list
                VStack(spacing: Airi.space2) {
                    batchBar
                    searchField
                    if loading {
                        Spacer()
                        ProgressRing(progress: 0.5, lineWidth: 8, showValue: false)
                            .frame(width: 56, height: 56)
                            // Indeterminate phase: pulse instead of fake progress.
                            .opacity(loadingPulse ? 0.45 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                       value: loadingPulse)
                        Spacer()
                    } else if filteredApps.isEmpty {
                        // Search miss used to be a blank list.
                        EmptyStateCard(
                            icon: searchText.isEmpty ? "app.badge" : "magnifyingglass",
                            title: searchText.isEmpty ? L("No apps installed") : L("No apps match your search"),
                            hint: searchText.isEmpty ? "" : L("Try a shorter or different name."),
                            actionTitle: searchText.isEmpty ? nil : L("Clear search")
                        ) { searchText = "" }
                            .padding(Airi.space2)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(filteredApps) { app in
                                    appRow(app)
                                }
                            }
                            .padding(.horizontal, Airi.space2)
                            .padding(.vertical, Airi.space2)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Divider()
                // detail
                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Airi.pageBackground.opacity(0.001))
        .overlay {
            if let batch { BatchProgressOverlay(progress: batch) }
        }
        .animation(Airi.controlAnimation, value: batch == nil)
        .confirmationDialog(
            Text(String(format: L("Uninstall %lld apps + data (%@)?"), pickedApps.count, pickedBytes.bytesFormatted)),
            isPresented: $confirmingBatch,
            titleVisibility: .visible
        ) {
            Button(String(format: L("Uninstall %lld apps + data"), pickedApps.count), role: .destructive) {
                runBatch()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The apps and their user data (preferences, caches, containers, saved state, logs…) are deleted permanently. This cannot be undone."))
        }
        .confirmationDialog(
            Text(singleRemoveData
                 ? String(format: L("Delete %@ and its data permanently?"), selection?.name ?? "")
                 : String(format: L("Delete %@ permanently?"), selection?.name ?? "")),
            isPresented: $confirmingSingle,
            titleVisibility: .visible
        ) {
            Button(L("Delete permanently"), role: .destructive) { uninstall(removeData: singleRemoveData) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(singleRemoveData
                 ? L("The app and its selected related files are deleted permanently. This cannot be undone.")
                 : L("The app is deleted permanently. This cannot be undone."))
        }
        .onAppear { loadingPulse = true }
        // App Management recovery step 3: the user toggled the permission in
        // System Settings and came back — re-probe and resume the pending
        // uninstall/batch without making them press anything again.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let url = pendingAppManagementURL,
                  pendingAppManagementWork != nil,
                  Permissions.probeAppManagement(bundleURL: url) else { return }
            resumePendingAppManagementWork()
        }
        .task {
            guard apps.isEmpty else { return }
            // Fast metadata first (sub-second), sizes stream in after.
            let loaded = await Task.detached { UninstallEngine.listApps() }.value
            withAnimation(Airi.entranceCurve) {
                apps = loaded
                loading = false
            }
            let sized = await UninstallEngine.sizeApps(loaded) { done, total in
                // Progress callback fires on a background executor; @State
                // must be touched on the main actor. Monotonic guard: tasks
                // complete out of order, so raw callbacks ran backwards.
                Task { @MainActor in
                    if done >= (sizingProgress?.0 ?? 0) {
                        sizingProgress = (done, total)
                    }
                }
            }
            sizes = sized
            apps.sort { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
            sizingProgress = nil
            // Batch uninstall ALWAYS sweeps user data, so its byte count must
            // include it — an app-only total made the destructive button read
            // 11 MB while the run actually removed 56 MB.
            dataSizes = await Self.relatedDataBytes(for: loaded)
        }
    }

    /// Deletable user-data bytes per app (preferences, caches, containers…).
    /// Only `isDeletableRelated` files count — group containers and admin-
    /// scope paths stay behind and must not inflate the number. relatedFiles
    /// sizes through SizeCache (NSLock-guarded, throttled writes), so the
    /// parallel fan-out is safe.
    static func relatedDataBytes(for apps: [UninstallEngine.AppEntry]) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64).self) { group in
            for app in apps {
                group.addTask {
                    let files = UninstallEngine.relatedFiles(appName: app.name, bundleID: app.bundleID)
                    let bytes = files
                        .filter { UninstallEngine.isDeletableRelated($0, bundleID: app.bundleID) }
                        .reduce(0) { $0 + $1.bytes }
                    return (app.id, bytes)
                }
            }
            var out: [String: Int64] = [:]
            for await (id, bytes) in group { out[id] = bytes }
            return out
        }
    }

    private var pickedApps: [UninstallEngine.AppEntry] {
        apps.filter { selectedApps.contains($0.id) }
    }

    /// What the batch actually removes: bundles + deletable user data.
    private var pickedBytes: Int64 {
        pickedApps.reduce(0) { $0 + (sizes[$1.id] ?? 0) + (dataSizes[$1.id] ?? 0) }
    }

    private var batchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: Airi.space2) {
                Button {
                    if selectedApps.count == apps.count {
                        selectedApps.removeAll()
                    } else {
                        selectedApps = Set(apps.map(\.id))
                    }
                } label: {
                    // Same condition the action uses — a partial selection
                    // used to read "Deselect all" while the click SELECTED all.
                    Text(selectedApps.count == apps.count ? L("Deselect all") : L("Select all"))
                        .font(Airi.caption2Font.weight(.medium))
                        .foregroundStyle(Airi.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                if let progress = sizingProgress {
                    HStack(spacing: 8) {
                        ProgressRing(
                            progress: Double(progress.done) / Double(max(progress.total, 1)),
                            lineWidth: 4,
                            showValue: false
                        )
                        .frame(width: 22, height: 22)
                        Text(L("sizing"))
                        TickingNumber(value: progress.done)
                        Text("/\(progress.total)")
                    }
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: progress.done)
                }
                if batchRunning, let progress = batch, let count = progress.countText {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text(count)
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                            .monospacedDigit()
                    }
                }
                AiriButton(
                    title: batchRunning
                        ? L("Uninstalling…")
                        : String(format: L("Uninstall %lld apps + data (%@)"), pickedApps.count, pickedBytes.bytesFormatted),
                    icon: "trash.fill",
                    variant: .destructive,
                    disabled: pickedApps.isEmpty || batchRunning
                ) {
                    confirmingBatch = true
                }
            }
            if let outcome = batchResult {
                SettingsCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("✓ \(L("Deleted")): \(outcome.trashed.map(\.name).joined(separator: ", "))")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.success)
            if !outcome.failed.isEmpty {
                Text("✗ \(outcome.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "; "))")
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.danger)
            }
            if outcome.failed.contains(where: { UninstallEngine.isAppManagementHint($0.reason) }) {
                appManagementCard
            }
                        Text(String(format: L("%1$@ apps · %2$@ data"),
                                    outcome.freedBytes.bytesFormatted,
                                    outcome.relatedBytes.bytesFormatted)
                             + (outcome.relatedFiles > 0
                                ? String(format: L(" · %lld leftover files"), outcome.relatedFiles)
                                : ""))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                    }
                }
            }
        }
        .padding(.horizontal, Airi.space2)
    }

    private func runBatch() {
        let picked = pickedApps
        let currentSizes = sizes
        batchRunning = true
        batch = BatchProgress(title: L("Uninstalling…"), done: 0, total: picked.count)
        let startedAt = Date()
        Task {
            // Make sure every app has a real size BEFORE trashing so the one
            // aggregated record carries correct per-path bytes.
            var effectiveSizes = currentSizes
            for app in picked where (effectiveSizes[app.id] ?? 0) <= 0 {
                effectiveSizes[app.id] = await ScanEngine.parallelSize(of: app.url).bytes
            }
            // Sequential so the per-app progress counter means something; each
            // call is told NOT to append its own record.
            var outcome = UninstallEngine.BatchOutcome()
            var dataItems: [CleanRecordItem] = []
            for (index, app) in picked.enumerated() {
                // Batch uninstall ALWAYS sweeps app data. Leaving
                // Preferences/Caches/Containers behind made "uninstalled" apps
                // keep their footprint (and reappear with old state on
                // reinstall) — the behaviour users reported as a bug.
                let single = await UninstallEngine.batchUninstall(
                    apps: [app], sizes: effectiveSizes, withData: true,
                    appendRecord: false, fallback: true)
                outcome.trashed += single.trashed
                outcome.freedBytes += single.freedBytes
                outcome.failed += single.failed
                outcome.relatedFiles += single.relatedFiles
                outcome.relatedBytes += single.relatedBytes
                if single.relatedFiles > 0 {
                    // The engine only reports counts; list the actual paths it
                    // was allowed to remove for the per-path audit trail.
                    let touched = UninstallEngine.relatedFiles(
                        appName: app.name, bundleID: app.bundleID)
                        .filter { UninstallEngine.isDeletableRelated($0, bundleID: app.bundleID) }
                        .filter { !FileManager.default.fileExists(atPath: $0.url.path) }
                    dataItems += touched.map {
                        CleanRecordItem(path: $0.url.path, bytes: $0.bytes,
                                        mode: .permanent, success: true, error: nil)
                    }
                }
                batch?.done = index + 1
                batch?.total = picked.count
            }            // ONE audit record for the whole batch — previously every app
            // produced its own row, so a 5-app uninstall spammed History with
            // five 1-path entries at the same timestamp.
            if !outcome.trashed.isEmpty {
                // Section titles = the app names, so the History row answers
                // "what did this run remove?" instead of only "Uninstall".
                let appNames = outcome.trashed.map(\.name)
                let titles = appNames.count <= 3
                    ? appNames
                    : Array(appNames.prefix(3)) + [String(format: L("+%lld more"), appNames.count - 3)]
                let items = outcome.trashed.map {
                    CleanRecordItem(path: $0.id, bytes: effectiveSizes[$0.id] ?? 0,
                                    mode: .permanent, success: true, error: nil)
                } + dataItems
                HistoryStore.append(CleanRecord(
                    date: Date(), sectionTitles: titles,
                    requestedBytes: outcome.freedBytes + outcome.relatedBytes,
                    freedBytes: outcome.freedBytes + outcome.relatedBytes,
                    itemCount: items.count, items: items, source: .uninstallBatch))
            }
            // Ghost rows: only apps that actually trashed leave the list —
            // a failed recycle used to make a still-installed app vanish.
            let trashedIDs = Set(outcome.trashed.map(\.id))
            apps.removeAll { trashedIDs.contains($0.id) }
            selectedApps.subtract(trashedIDs)
            withAnimation { batchResult = outcome }
            batchRunning = false
            // Hold the ring long enough to register (small batches finish
            // inside one frame, which reads as a glitch without this).
            await BatchProgressHold.until(startedAt)
            batch = nil
            UXFeedback.success()
            PetBus.shared.say(
                String(format: L("Uninstalled %lld apps 🗑"), outcome.trashed.count),
                state: .celebrating)
            // Batch rows refused by App Management: same recovery pipeline —
            // probe with the first picked bundle (the TCC decision is
            // process-wide) and redo the whole batch once granted.
            if outcome.failed.contains(where: { UninstallEngine.isAppManagementHint($0.reason) }),
               let first = picked.first {
                handleAppManagementDenial(bundleURL: first.url) {
                    runBatch()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Airi.neutral400)
            TextField(L("Search apps"), text: $searchText)
                .textFieldStyle(.plain)
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral900)
                .focused($searchFocused)
                .onTapGesture { searchFocused = true }
                // ⌘F jumps to search — previously the field was click-only.
                .background(
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .labelsHidden()
                        .frame(width: 0, height: 0)
                        .opacity(0)
                )
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Airi.radiusControl).fill(Airi.neutral50))
        .overlay(RoundedRectangle(cornerRadius: Airi.radiusControl).strokeBorder(Airi.neutral200, lineWidth: 1).allowsHitTesting(false))
        .padding(Airi.space2)
    }

    private func appRow(_ app: UninstallEngine.AppEntry) -> some View {
        let isSelected = selection?.id == app.id
        let isPicked = selectedApps.contains(app.id)
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { isPicked },
                set: { on in
                    if on { selectedApps.insert(app.id) } else { selectedApps.remove(app.id) }
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .labelsHidden()
            Button {
                select(app)
            } label: {
                HStack(spacing: Airi.space2) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Airi.neutral900)
                            .lineLimit(1)
                        Text(sizeLabel(app) + " · \(app.bundleID ?? "no bundle id")")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusControl)
                        .fill(isSelected ? Airi.primary.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sizeLabel(_ app: UninstallEngine.AppEntry) -> String {
        if let bytes = sizes[app.id], bytes > 0 { return bytes.bytesFormatted }
        return "sizing…"
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Airi.space3) {
                if let app = selection {
                    HStack(spacing: Airi.space3) {
                        Image(nsImage: app.icon).resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.system(size: 16, weight: .medium))
                            // Prefer the measured size once the background
                            // walk finishes; `app.bytes` is only the fast
                            // pre-sizing estimate.
                            Text("\((sizes[app.id] ?? app.bytes).bytesFormatted) · \(app.url.path)")
                                .font(Airi.caption2Font).foregroundStyle(Airi.neutral500)
                        }
                        Spacer()
                    }

                    if loadingRelated {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(L("Finding related files…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                        }
                    } else if related.isEmpty {
                        Text(L("No user leftovers found."))
                            .font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                    } else {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: Airi.space2) {
                                Text(L("Related user files"))
                                    .font(Airi.cardTitleFont)
                                ForEach(related) { file in
                                    relatedRow(file)
                                }
                            }
                        }
                    }

                    let systemLeftovers = related.filter { !$0.deletable && $0.kind.contains("(admin") }
                    if !systemLeftovers.isEmpty {
                        SettingsCard {
                            VStack(alignment: .leading, spacing: Airi.space2) {
                                Text(L("System leftovers"))
                                    .font(Airi.cardTitleFont)
                                ForEach(systemLeftovers) { file in
                                    HStack(spacing: 6) {
                                        Image(systemName: "lock.shield")
                                            .font(Airi.caption2Font)
                                            .foregroundStyle(Airi.warning)
                                        Text("\(file.kind) · \(file.url.path)")
                                            .font(Airi.caption2Font)
                                            .foregroundStyle(Airi.neutral700)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                AiriButton(title: L("Remove system leftovers…"),
                                           icon: "lock.open", variant: .secondary) {
                                    removeSystemLeftovers(systemLeftovers)
                                }
                                if let adminResultText {
                                    Text(adminResultText)
                                        .font(Airi.monoCaption2Font)
                                        .foregroundStyle(Airi.neutral700)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if let resultText {
                        SettingsCard {
                            Text(resultText).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Airi.neutral700).textSelection(.enabled)
                        }
                    }

                    if showAppManagementHint { appManagementCard }

                    HStack {
                        AiriButton(title: L("Uninstall (app only)"), icon: "trash",
                                   variant: .secondary, disabled: busy) {
                            singleRemoveData = false; confirmingSingle = true
                        }
                        AiriButton(title: String(format: L("Uninstall + data (%@)"),
                                                relatedSelectedBytes.bytesFormatted),
                                   icon: "trash.fill", disabled: busy || selectedRelated.isEmpty) {
                            singleRemoveData = true; confirmingSingle = true
                        }
                    }
                } else {
                    Text(L("Select an app to see its leftovers."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                        .padding(.top, 40)
                }
            }
            .padding(Airi.space3)
        }
    }

    /// App Management recovery pipeline, run whenever a delete is refused
    /// with the App Management hint:
    /// 1. The refused attempt itself raises the TCC prompt IF the decision
    ///    was never made — give that ~20 s: the moment the probe succeeds
    ///    the original uninstall resumes on its own.
    /// 2. No prompt came (a recorded deny never re-prompts) → jump straight
    ///    to System Settings → App Management, once.
    /// 3. Either way, returning to the app re-probes and resumes the
    ///    pending work automatically (see the didBecomeActive handler).
    private func handleAppManagementDenial(bundleURL: URL, retry: @escaping () -> Void) {
        showAppManagementHint = true
        pendingAppManagementURL = bundleURL
        pendingAppManagementWork = retry
        Task {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if Permissions.probeAppManagement(bundleURL: bundleURL) {
                    await MainActor.run { resumePendingAppManagementWork() }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                guard !openedAppManagementSettings else { return }
                openedAppManagementSettings = true
                Permissions.openAppManagementSettings()
            }
        }
    }

    private func resumePendingAppManagementWork() {
        let work = pendingAppManagementWork
        pendingAppManagementWork = nil
        pendingAppManagementURL = nil
        work?()
    }

    /// Explains the macOS 15+ split: FDA is read-only, deleting other apps'
    /// bundles is gated by a separate TCC permission, and deep-links to it.
    private var appManagementCard: some View {
        SettingsCard(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("App Management permission required"),
                      systemImage: "lock.shield")
                    .font(Airi.captionFont.weight(.medium))
                    .foregroundStyle(Airi.warning)
                Text(L("On macOS 15+, deleting other apps requires the App Management permission. Full Disk Access only grants read access and is not enough."))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral700)
                Text(L("If you previously clicked Don't Allow, macOS will not show the prompt again — turn it on in System Settings."))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                AiriButton(title: L("Grant App Management…"),
                           icon: "lock.open", variant: .secondary) {
                    Task { @MainActor in Permissions.openAppManagementSettings() }
                }
            }
        }
    }

    private func relatedRow(_ file: UninstallEngine.RelatedFile) -> some View {
        HStack(spacing: Airi.space2) {
            if file.deletable {
                Toggle("", isOn: Binding(
                    get: { selectedRelated.contains(file.id) },
                    set: { on in
                        if on { selectedRelated.insert(file.id) } else { selectedRelated.remove(file.id) }
                    }
                ))
                .toggleStyle(.checkbox).controlSize(.small).labelsHidden()
            } else {
                Image(systemName: "lock.fill").font(Airi.caption2Font).foregroundStyle(Airi.neutral400)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.path).font(Airi.footnoteFont).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(Airi.neutral900)
                Text("\(file.kind) · \(file.bytes.bytesFormatted)")
                    .font(Airi.caption2Font).foregroundStyle(Airi.neutral500)
            }
            Spacer()
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Airi.neutral50.opacity(0.6)))
    }

    private var relatedSelectedBytes: Int64 {
        related.filter { selectedRelated.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    @State private var selectGeneration = 0

    private func select(_ app: UninstallEngine.AppEntry) {
        selectGeneration += 1
        let generation = selectGeneration
        selection = app
        related = []
        selectedRelated = []
        resultText = nil
        showAppManagementHint = false
        loadingRelated = true
        let name = app.name
        let bundleID = app.bundleID
        let appID = app.id
        Task {
            let files = await Task.detached {
                UninstallEngine.relatedFiles(appName: name, bundleID: bundleID)
            }.value
            // The user may have clicked another app while this scan ran —
            // only the latest REQUEST owns the detail pane (id alone can't
            // disambiguate a click A→B→back-to-A; both A-scans would pass).
            guard selection?.id == appID, generation == selectGeneration else { return }
            withAnimation(Airi.controlAnimation) {
                related = files
                selectedRelated = Set(files.filter(\.deletable).map(\.id))
                loadingRelated = false
            }
        }
    }

    private func removeSystemLeftovers(_ files: [UninstallEngine.RelatedFile]) {
        Task {
            let results = await UninstallEngine.removeSystemLeftovers(files)
            let ok = results.filter { $0.1 == nil }.count
            let failed = results.filter { $0.1 != nil }
            var text = "✓ \(String(format: L("removed %lld system items"), ok))"
            if !failed.isEmpty {
                text += "\n✗ " + failed.prefix(3).map { "\(($0.0 as NSString).lastPathComponent): \($0.1!)" }
                    .joined(separator: "; ")
            }
            withAnimation { adminResultText = text }
            related.removeAll { file in
                files.contains(where: { $0.id == file.id }) &&
                !results.contains(where: { $0.0 == file.url.path && $0.1 != nil })
            }
        }
    }

    private func uninstall(removeData: Bool) {
        guard let app = selection else { return }
        busy = true
        let files = related.filter { selectedRelated.contains($0.id) }
        let appCopy = app
        Task {
            // Capture the real size BEFORE trashing: AppEntry.bytes is always
            // 0 (sizes live in the `sizes` dict) and that dict can still be
            // empty mid-sizing — either way the history row recorded 0.
            let measured = sizes[appCopy.id] ?? 0
            let appBytes: Int64
            if measured > 0 { appBytes = measured }
            else { appBytes = await ScanEngine.parallelSize(of: appCopy.url).bytes }
            var sizeByPath: [String: Int64] = [appCopy.url.path: appBytes]
            for file in files { sizeByPath[file.url.path] = file.bytes }

            let result = await UninstallEngine.uninstall(
                app: appCopy, files: files, removeData: removeData, fallback: true)
            if result.failed.contains(where: { UninstallEngine.isAppManagementHint($0.1) }) {
                // The failed removeItem itself is what raises the TCC prompt
                // (undecided state) — the recovery pipeline waits for that
                // grant, or jumps to Settings when it never comes.
                handleAppManagementDenial(bundleURL: appCopy.url) {
                    uninstall(removeData: removeData)
                }
            }
            // Only what actually left the disk counts; per-item bytes are real
            // now so the History detail shows sizes instead of "—".
            let freed = result.removedFiles.reduce(0) { $0 + (sizeByPath[$1] ?? 0) }
            var text = result.appTrashed
                ? "✓ \(String(format: L("%@ deleted"), appCopy.name))"
                : "✗ \(L("app removal failed"))"
            let relatedCount = result.removedFiles.count - (result.appTrashed ? 1 : 0)
            if relatedCount > 0 {
                text += "\n✓ \(String(format: L("%lld related files deleted"), relatedCount))"
            }
            if !result.failed.isEmpty {
                text += "\n✗ \(result.failed.count) failures: " +
                    result.failed.prefix(3).map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            }
            // removedFiles/failed carry full paths (see UninstallEngine.uninstall).
            let record = CleanRecord(
                date: Date(), sectionTitles: [appCopy.name],
                requestedBytes: freed, freedBytes: freed,
                itemCount: result.removedFiles.count + result.failed.count,
                items: result.removedFiles.map {
                    CleanRecordItem(path: $0, bytes: sizeByPath[$0] ?? 0, mode: .permanent, success: true, error: nil)
                } + result.failed.map {
                    CleanRecordItem(path: $0.0, bytes: sizeByPath[$0.0] ?? 0, mode: .permanent, success: false, error: $0.1)
                }, source: .uninstall)
            HistoryStore.append(record)
            if result.appTrashed {
                UXFeedback.success()
                PetBus.shared.say(String(format: L("Uninstalled %@"), appCopy.name) + " 🗑", state: .celebrating)
            }
            withAnimation { resultText = text }
            busy = false
            // Only a trashed app leaves the list; a failed one stays (with
            // its buttons live) instead of turning into a ghost row.
            if result.appTrashed {
                apps.removeAll { $0.id == appCopy.id }
                selection = nil
            }
        }
    }
}
