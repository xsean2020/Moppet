import SwiftUI

/// Large files — the UI for the "where did my disk go?" question. Top N
/// files by size, filterable by minimum size, selected rows go to the TRASH.
/// SafetyGuard-protected paths (Documents, Desktop, iCloud…) are shown but
/// marked protected — the app never deletes user-authored data, the row's
/// "Show in Finder" hands off instead.
struct LargeFilesView: View {
    var onClose: (() -> Void)?

    enum MinSize: String, CaseIterable, Identifiable {
        case mb100 = "100 MB"
        case mb500 = "500 MB"
        case gb1 = "1 GB"
        case gb5 = "5 GB"
        var id: String { rawValue }
        var bytes: Int64 {
            switch self {
            case .mb100: return 100_000_000
            case .mb500: return 500_000_000
            case .gb1: return 1_000_000_000
            case .gb5: return 5_000_000_000
            }
        }
    }

    /// Scope picker binds the ENGINE's scope type (the search roots live
    /// there); titles are UI-only.
    @State private var minSize: MinSize = .mb500
    @State private var scope: LargeFilesEngine.Scope = .userFolders
    @State private var scanning = false
    /// (steps done, steps total) streamed by the engine's progress callback —
    /// one step per mdfind root plus the find fallback when it runs.
    @State private var scanProgress: (done: Int, total: Int)? = nil
    @State private var files: [LargeFilesEngine.LargeFile] = []
    @State private var selected: Set<URL> = []
    @State private var showTrashConfirm = false
    @State private var lastMessage: String?
    @State private var spotlightWarning = false

    private func scopeTitle(_ scope: LargeFilesEngine.Scope) -> String {
        switch scope {
        case .userFolders: return L("User Folders")
        case .wholeHome: return L("Whole Home")
        case .containers: return L("Containers & Caches")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Large Files"),
                       subtitle: L("Biggest files on disk — select and move to the Trash"),
                       onBack: onClose)
            Divider().overlay(Airi.neutral200.opacity(0.5))
            ScrollView {
                VStack(spacing: Airi.space3) {
                    filterCard
                    if let lastMessage {
                        Text(lastMessage)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if spotlightWarning {
                        SettingsCard(padding: Airi.space3) {
                            HStack(spacing: Airi.space2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Airi.warning)
                                Text(L("Spotlight indexing seems off — results may be incomplete. Turn it on in System Settings → Siri & Spotlight."))
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral700)
                            }
                        }
                    }
                    if files.isEmpty && !scanning {
                        EmptyStateCard(icon: "doc.text.magnifyingglass",
                                       title: L("No large files found"),
                                       hint: L("Try a smaller size filter or another scope."),
                                       actionTitle: nil)
                    }
                    ForEach(files) { file in
                        row(file)
                    }
                }
                .padding(Airi.space4)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            bottomBar
        }
        .background(Airi.pageBackground.opacity(0.001))
        .confirmationDialog(
            Text(String(format: L("Move %lld files to the Trash?"), selectedFiles.count)),
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Move to Trash"), role: .destructive) { Task { await trashSelected() } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Files go to the Trash and can be restored from there."))
        }
    }

    private var selectedFiles: [LargeFilesEngine.LargeFile] {
        files.filter { selected.contains($0.url) }
    }

    // MARK: - Filter + scan

    private var filterCard: some View {
        SettingsCard(padding: Airi.space3) {
            HStack(spacing: Airi.space3) {
                Picker(L("Min size"), selection: $minSize) {
                    ForEach(MinSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Picker(L("Scope"), selection: $scope) {
                    ForEach(LargeFilesEngine.Scope.allCases, id: \.self) { scope in
                        Text(scopeTitle(scope)).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)
                Spacer()
                AiriButton(title: L("Scan"), icon: "magnifyingglass",
                           busy: scanning) {
                    Task { await scan() }
                }
            }
            HStack(spacing: Airi.space2) {
                Button(L("Select all deletable")) {
                    selected = Set(files.filter { Self.deletable($0.url) }.map(\.url))
                }
                .buttonStyle(.plain)
                .font(Airi.captionFont.weight(.medium))
                .foregroundStyle(Airi.primary)
                Button(L("Deselect all")) { selected = [] }
                    .buttonStyle(.plain)
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                Spacer()
                if scanning {
                    HStack(spacing: 8) {
                        if let p = scanProgress, p.total > 0 {
                            ProgressRing(progress: Double(p.done) / Double(max(p.total, 1)),
                                         lineWidth: 4, showValue: false)
                                .frame(width: 22, height: 22)
                            TickingNumber(value: p.done)
                            Text("/\(p.total)")
                        } else {
                            // Before the first root reports, the ring sits at
                            // zero — still honest feedback that scanning began.
                            ProgressRing(progress: 0, lineWidth: 4, showValue: false)
                                .frame(width: 22, height: 22)
                        }
                        Text(L("Scanning…"))
                    }
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: scanProgress?.done ?? 0)
                }
                Text(String(format: L("%1$@ selected of %2$@ total"),
                            selectedFiles.reduce(0) { $0 + $1.bytes }.bytesFormatted,
                            files.reduce(0) { $0 + $1.bytes }.bytesFormatted))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral500)
                    .monospacedDigit()
            }
        }
    }

    private func scan() async {
        scanning = true
        lastMessage = nil
        spotlightWarning = false
        scanProgress = nil
        let found = await LargeFilesEngine.find(minBytes: minSize.bytes, scope: scope) { done, total in
            // Sequential engine loop — callbacks arrive in order; hop to the
            // main actor before touching @State (background executor).
            Task { @MainActor in scanProgress = (done, total) }
        }
        scanProgress = nil
        files = found
        // Only deletable rows start selected — a protected row ticked by
        // default would produce a clean run that silently skips it.
        selected = Set(found.filter { Self.deletable($0.url) }.map(\.url))
        if found.isEmpty {
            spotlightWarning = !(await LargeFilesEngine.spotlightWorks(
                in: scope == .wholeHome
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : (scope.roots.first?
                        .replacingOccurrences(of: "~", with: NSHomeDirectory()) ?? NSHomeDirectory())))
        }
        scanning = false
    }

    // MARK: - Rows + trash

    private func row(_ file: LargeFilesEngine.LargeFile) -> some View {
        let deletable = Self.deletable(file.url)
        let modified = (try? FileManager.default.attributesOfItem(
            atPath: file.url.path)[.modificationDate] as? Date) ?? nil
        return SettingsCard(padding: Airi.space2 + 2) {
            HStack(spacing: Airi.space2) {
                if deletable {
                    Toggle("", isOn: Binding(
                        get: { selected.contains(file.url) },
                        set: { on in
                            if on { selected.insert(file.url) }
                            else { selected.remove(file.url) }
                        }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .labelsHidden()
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Airi.neutral400)
                        .help(L("Protected by the safety layer — user data is never deleted"))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Airi.neutral900)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pathDisplay(file.url.path)
                         + (modified.map { " · " + String(format: L("modified %@"), $0.formatted(date: .abbreviated, time: .omitted)) } ?? ""))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.url.path)
                }
                Spacer()
                Text(file.bytes.bytesFormatted)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Airi.neutral900)
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                Button(L("Show in Finder")) {
                    Task { @MainActor in
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                }
                .buttonStyle(.plain)
                .font(Airi.caption2Font.weight(.medium))
                .foregroundStyle(Airi.primary)
            }
        }
    }

    private func trashSelected() async {
        let picked = selectedFiles.filter { Self.deletable($0.url) }
        guard !picked.isEmpty else { return }
        var removed: [(String, Int64)] = []
        var failed: [(String, String)] = []
        for file in picked {
            do {
                try await Task.detached {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                }.value
                removed.append((file.url.path, file.bytes))
            } catch {
                failed.append((file.url.path, error.localizedDescription))
            }
        }
        let freed = removed.reduce(0) { $0 + $1.1 }
        HistoryStore.append(CleanRecord(
            date: Date(), sectionTitles: [L("Large Files")],
            requestedBytes: picked.reduce(0) { $0 + $1.bytes },
            freedBytes: freed, itemCount: picked.count,
            items: picked.map { file in
                CleanRecordItem(path: file.url.path, bytes: file.bytes, mode: .trash,
                                success: removed.contains { $0.0 == file.url.path },
                                error: failed.first { $0.0 == file.url.path }?.1)
            }, source: .largeFiles))
        lastMessage = failed.isEmpty
            ? String(format: L("Moved %lld files (%@) to the Trash"), Int64(removed.count), freed.bytesFormatted)
            : String(format: L("Moved %1$lld files — %2$lld failed"), Int64(removed.count), Int64(failed.count))
        files.removeAll { file in removed.contains { $0.0 == file.url.path } }
        selected = []
        UXFeedback.success()
    }

    private var bottomBar: some View {
        HStack(spacing: Airi.space2) {
            Spacer()
            AiriButton(title: String(format: L("Trash %@"), selectedFiles.reduce(0) { $0 + $1.bytes }.bytesFormatted),
                       icon: "trash", variant: .destructive,
                       disabled: selectedFiles.isEmpty) {
                showTrashConfirm = true
            }
        }
        .padding(Airi.space4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
    }

    private func pathDisplay(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func deletable(_ url: URL) -> Bool {
        SafetyGuard.checkDeletable(url).allowed
    }
}
