import SwiftUI

/// Orphan residue — Library folders and preference plists whose owning app
/// is no longer installed. Everything found here goes to the TRASH
/// (recoverable): the classification is heuristic, so the user can undo a
/// false positive from the Trash.
struct OrphansView: View {
    var onClose: (() -> Void)?

    @State private var scanning = false
    @State private var cleaned = false
    @State private var hasScanned = false
    @State private var candidates: [OrphanResidueEngine.Candidate] = []
    @State private var selected: Set<String> = []
    @State private var showTrashConfirm = false
    @State private var lastMessage: String?
    /// Progress of the running trash batch — drives the center overlay.
    @State private var batch: BatchProgress?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Orphan Residue"),
                       subtitle: L("Leftovers of apps that are no longer installed — moved to the Trash, recoverable"),
                       onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    if let lastMessage {
                        Text(lastMessage)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if candidates.isEmpty {
                        EmptyStateCard(
                            icon: cleaned ? "checkmark.seal" : "tray.full",
                            title: cleaned
                                ? L("No orphans left")
                                : hasScanned
                                    ? L("No orphan residue found")
                                    : L("Find leftover residue"),
                            hint: cleaned
                                ? L("Everything previously found has been cleared. Rescan after uninstalling more apps.")
                                : hasScanned
                                    ? L("Nothing in the Library belongs to an app that's gone.")
                                    : L("Library folders, preference plists and containers of apps you already removed will show up here."),
                            actionTitle: cleaned ? nil : L("Scan"))
                        {
                            if !cleaned { Task { await scan() } }
                        }
                    } else {
                        totalBanner
                        ForEach(candidates) { candidate in
                            row(candidate)
                        }
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            bottomBar
        }
        .background(Airi.pageBackground.opacity(0.001))
        .overlay {
            if let batch { BatchProgressOverlay(progress: batch) }
        }
        .animation(Airi.controlAnimation, value: batch == nil)
        .confirmationDialog(
            Text(String(format: L("Move %lld orphan items to the Trash?"),
                        selectedItems.count)),
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Move to Trash"), role: .destructive) { Task { await trashSelected() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Items go to the Trash and can be restored from there. Only paths that pass the safety layer are removed."))
        }
    }

    private var selectedItems: [OrphanResidueEngine.Candidate] {
        candidates.filter { selected.contains($0.id) }
    }

    // MARK: - Scan / trash

    private func scan() async {
        scanning = true
        cleaned = false
        lastMessage = nil
        let found = await OrphanResidueEngine.scan { name in
            // progress reports the root — not surfaced per-row, kept cheap
            _ = name
        }
        candidates = found
        selected = Set(found.map(\.id))
        hasScanned = true
        scanning = false
    }

    private func trashSelected() async {
        let picked = selectedItems
        guard !picked.isEmpty else { return }
        // Each residue item is an independent Trash move; a Library folder can
        // take a second or two, so the batch needs a visible counter.
        batch = BatchProgress(title: L("Moving to the Trash…"), done: 0, total: picked.count)
        let startedAt = Date()
        let outcomes = await OrphanResidueEngine.trash(picked) { done, total, name in
            Task { @MainActor in
                batch?.done = done
                batch?.total = total
                batch?.detail = name
            }
        }
        let ok = outcomes.filter(\.success)
        let failed = outcomes.filter { !$0.success }
        let freed = picked.filter { candidate in
            ok.contains { $0.path == candidate.url.path }
        }.reduce(0) { $0 + $1.bytes }
        HistoryStore.append(CleanRecord(
            date: Date(), sectionTitles: [L("Orphan Residue")],
            requestedBytes: picked.reduce(0) { $0 + $1.bytes },
            freedBytes: freed, itemCount: picked.count,
            items: picked.map { candidate in
                let outcome = outcomes.first { $0.path == candidate.url.path }
                return CleanRecordItem(path: candidate.url.path, bytes: candidate.bytes,
                                       mode: .trash, success: outcome?.success == true,
                                       error: outcome?.error)
            }, source: .orphans))
        lastMessage = failed.isEmpty
            ? String(format: L("Moved %1$@ of residue to the Trash (%2$@)"),
                     "\(ok.count)", freed.bytesFormatted)
            : String(format: L("Moved %1$@ items — %2$@ failed"), "\(ok.count)", "\(failed.count)")
        cleaned = true
        candidates = []
        selected = []
        await BatchProgressHold.until(startedAt)
        batch = nil
        UXFeedback.success()
    }

    // MARK: - Pieces

    private var totalBanner: some View {
        SettingsCard(padding: Airi.space3) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("%1$@ of orphan residue in %2$lld items"),
                                totalBytes.bytesFormatted, Int64(candidates.count)))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Airi.neutral950)
                    Text(L("Dirs untouched for 30+ days whose owning app is gone. Vendor helpers of installed apps are never listed."))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
                Image(systemName: "tray.full")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Airi.danger.opacity(0.7))
            }
        }
    }

    private var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }

    private func row(_ candidate: OrphanResidueEngine.Candidate) -> some View {
        SettingsCard(padding: Airi.space3) {
            HStack(spacing: Airi.space2) {
                Toggle("", isOn: Binding(
                    get: { selected.contains(candidate.id) },
                    set: { on in
                        if on { selected.insert(candidate.id) }
                        else { selected.remove(candidate.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(candidate.bundleID)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Airi.neutral900)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(candidate.kind)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Airi.neutral500)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Airi.neutral100))
                    }
                    Text(pathDisplay(candidate.url.path)
                         + (candidate.lastModified.map {
                            " · " + String(format: L("untouched since %@"), L10n.date($0, timeStyle: .none))
                         } ?? ""))
                        .font(Airi.caption2Font)
                        // Path/date data, not chrome — neutral400 was too
                        // faint at 10pt on the card surface.
                        .foregroundStyle(Airi.neutral500)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(candidate.url.path)
                }
                Spacer()
                Text(candidate.bytes.bytesFormatted)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Airi.neutral900)
                    .monospacedDigit()
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: Airi.space2) {
            if scanning {
                ProgressView().controlSize(.small)
                Text(L("Scanning Library — comparing bundle ids against installed apps…"))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
            }
            Spacer()
            if !candidates.isEmpty {
                Text(String(format: L("%lld of %lld selected"),
                            selected.count, candidates.count))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
            }
            AiriButton(title: L("Rescan"), icon: "arrow.clockwise",
                       variant: .secondary, busy: scanning) {
                Task { await scan() }
            }
            AiriButton(title: String(format: L("Trash %@"), selectedItems.reduce(0) { $0 + $1.bytes }.bytesFormatted),
                       icon: "trash", variant: .destructive,
                       disabled: selectedItems.isEmpty) {
                showTrashConfirm = true
            }
        }
        .padding(Airi.space4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }
}
