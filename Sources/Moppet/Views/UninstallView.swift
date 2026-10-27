import SwiftUI
import AppKit

/// App uninstaller — `mo uninstall` as a native review-then-trash flow.
struct UninstallView: View {
    var onClose: (() -> Void)?

    @State private var apps: [UninstallEngine.AppEntry] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var sizingProgress: (done: Int, total: Int)? = nil
    @State private var loadingPulse = false
    @State private var selectedApps: Set<String> = []
    @State private var loading = true
    @State private var batchRunning = false
    @State private var batchProgress: (done: Int, total: Int)? = nil
    @State private var batchResult: UninstallEngine.BatchOutcome?
    @State private var searchText = ""
    @State private var selection: UninstallEngine.AppEntry?
    @State private var related: [UninstallEngine.RelatedFile] = []
    @State private var selectedRelated: Set<UUID> = []
    @State private var loadingRelated = false
    @State private var resultText: String?
    @State private var busy = false
    @State private var adminResultText: String?
    /// Batch-uninstall confirmation (the flow moved apps straight to the
    /// Trash on one click — the only page in the app without a confirm).
    @State private var confirmingBatch = false
    /// Explicit focus plumbing for the search box (terminal-launched apps
    /// can lack a working click-to-first-responder chain — see HANDOFF §6.24).
    @FocusState private var searchFocused: Bool

    var filteredApps: [UninstallEngine.AppEntry] {
        searchText.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Uninstall"), subtitle: L("Move apps to the Trash and sweep their leftovers"), onBack: onClose)
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
        .confirmationDialog(
            Text(String(format: L("Uninstall %lld apps (%@)?"), pickedApps.count, pickedBytes.bytesFormatted)),
            isPresented: $confirmingBatch,
            titleVisibility: .visible
        ) {
            Button(String(format: L("Uninstall %lld apps"), pickedApps.count), role: .destructive) {
                runBatch()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Apps move to the Trash (recoverable). Related files listed in the detail pane are NOT touched by batch uninstall."))
        }
        .onAppear { loadingPulse = true }
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
        }
    }

    private var pickedApps: [UninstallEngine.AppEntry] {
        apps.filter { selectedApps.contains($0.id) }
    }

    private var pickedBytes: Int64 {
        pickedApps.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
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
                if batchRunning, let progress = batchProgress {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("\(progress.done)/\(progress.total)")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.neutral500)
                            .monospacedDigit()
                    }
                }
                AiriButton(
                    title: batchRunning
                        ? L("Uninstalling…")
                        : String(format: L("Uninstall %lld apps (%@)"), pickedApps.count, pickedBytes.bytesFormatted),
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
                        Text("✓ \(L("Moved to Trash")): \(outcome.trashed.map(\.name).joined(separator: ", "))")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.success)
                        if !outcome.failed.isEmpty {
                            Text("✗ \(outcome.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "; "))")
                                .font(Airi.caption2Font)
                                .foregroundStyle(Airi.danger)
                        }
                        Text(String(format: L("Freed %@"), outcome.freedBytes.bytesFormatted))
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
        batchProgress = (0, picked.count)
        Task {
            // Sequential so the per-app progress counter means something
            // (the engine's parallel batch is fast but unordered).
            var outcome = UninstallEngine.BatchOutcome()
            for (index, app) in picked.enumerated() {
                let single = await UninstallEngine.batchUninstall(apps: [app], sizes: currentSizes, withData: false)
                outcome.trashed += single.trashed
                outcome.freedBytes += single.freedBytes
                outcome.failed += single.failed
                batchProgress = (index + 1, picked.count)
            }
            // Ghost rows: only apps that actually trashed leave the list —
            // a failed recycle used to make a still-installed app vanish.
            let trashedIDs = Set(outcome.trashed.map(\.id))
            apps.removeAll { trashedIDs.contains($0.id) }
            selectedApps.subtract(trashedIDs)
            withAnimation { batchResult = outcome }
            batchRunning = false
            batchProgress = nil
            UXFeedback.success()
            PetBus.shared.say(
                String(format: L("Uninstalled %lld apps 🗑"), outcome.trashed.count),
                state: .celebrating)
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
        .overlay(RoundedRectangle(cornerRadius: Airi.radiusControl).strokeBorder(Airi.neutral200, lineWidth: 1))
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

                    HStack {
                        AiriButton(title: L("Uninstall (app only)"), icon: "trash",
                                   variant: .secondary, disabled: busy) { uninstall(removeData: false) }
                        AiriButton(title: String(format: L("Uninstall + data (%@)"),
                                                relatedSelectedBytes.bytesFormatted),
                                   icon: "trash.fill", disabled: busy || selectedRelated.isEmpty) {
                            uninstall(removeData: true)
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
            let result = await UninstallEngine.uninstall(app: appCopy, files: files, removeData: removeData)
            let freed = (sizes[appCopy.id] ?? appCopy.bytes) + (removeData ? files.reduce(0) { $0 + $1.bytes } : 0)
            var text = result.appTrashed
                ? "✓ \(String(format: L("%@ moved to Trash"), appCopy.name))"
                : "✗ \(L("app removal failed"))"
            let relatedCount = result.removedFiles.count - (result.appTrashed ? 1 : 0)
            if relatedCount > 0 {
                text += "\n✓ \(String(format: L("%lld related files trashed"), relatedCount))"
            }
            if !result.failed.isEmpty {
                text += "\n✗ \(result.failed.count) failures: " +
                    result.failed.prefix(3).map { "\($0.0): \($0.1)" }.joined(separator: "; ")
            }
            // removedFiles/failed carry full paths (see UninstallEngine.uninstall).
            let record = CleanRecord(
                date: Date(), sectionTitles: ["Uninstall"],
                requestedBytes: freed, freedBytes: freed,
                itemCount: result.removedFiles.count + result.failed.count,
                items: result.removedFiles.map {
                    CleanRecordItem(path: $0, bytes: 0, mode: .trash, success: true, error: nil)
                } + result.failed.map {
                    CleanRecordItem(path: $0.0, bytes: 0, mode: .trash, success: false, error: $0.1)
                })
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
