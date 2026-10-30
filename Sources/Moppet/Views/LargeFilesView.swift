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
    @State private var warningMessage: String?
    /// Progress of the running trash batch — drives the center overlay.
    @State private var batch: BatchProgress?
    /// Folders the user added for the custom scope. Persisted through
    /// `LargeFilesEngine.CustomRoots` so the selection survives relaunch.
    @State private var customRoots: [String] = LargeFilesEngine.CustomRoots.paths

    private func scopeTitle(_ scope: LargeFilesEngine.Scope) -> String {
        switch scope {
        case .userFolders: return L("User Folders")
        case .wholeHome: return L("Whole Home")
        case .containers: return L("Containers & Caches")
        case .custom: return L("Custom Folder")
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
                    if files.contains(where: { !Self.deletable($0.url) }) {
                        protectionNote
                    }
                    if let lastMessage {
                        Text(lastMessage)
                            .font(Airi.captionFont)
                            .foregroundStyle(Airi.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let warningMessage {
                        SettingsCard(padding: Airi.space3) {
                            HStack(spacing: Airi.space2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Airi.warning)
                                Text(warningMessage)
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral700)
                                    .fixedSize(horizontal: false, vertical: true)
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
        .overlay {
            if let batch { BatchProgressOverlay(progress: batch) }
        }
        .animation(Airi.controlAnimation, value: batch == nil)
        // Picking "自定义目录" for the first time jumps straight into the
        // folder chooser — otherwise the scope menu would select an empty
        // list and the Scan button would just be disabled with no next step.
        .onChange(of: scope) { _, newScope in
            if newScope == .custom && customRoots.isEmpty {
                pickCustomRoots()
            }
        }
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

    /// Explains the lock rule once, so "why can't I tick this?" is answered
    /// without hovering every row.
    private var protectionNote: some View {
        SettingsCard(padding: Airi.space3) {
            HStack(spacing: Airi.space2) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Airi.warning)
                Text(L("Locked rows live inside protected user-data folders (Documents, Desktop, Pictures, Music, Movies) — Moppet never deletes those. Use Show in Finder to manage them."))
                    .font(Airi.captionFont)
                    .foregroundStyle(Airi.neutral700)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filterCard: some View {
        SettingsCard(padding: Airi.space3) {
            VStack(alignment: .leading, spacing: Airi.space2) {
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
                               disabled: scope == .custom && customRoots.isEmpty,
                               busy: scanning) {
                        Task { await scan() }
                    }
                }
                // Custom scope: the folder chips + picker live right under the
                // scope menu, so "where will it scan?" is answered in place.
                if scope == .custom {
                    customRootsRow
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
    }

    // MARK: - Custom scope

    /// One removable chip per saved folder. A chip whose folder vanished is
    /// flagged red and skipped by the scan (it is not silently rolled into
    /// the count).
    private var customRootsRow: some View {
        VStack(alignment: .leading, spacing: Airi.space2) {
            ForEach(customRoots, id: \.self) { path in
                customRootChip(path)
            }
            HStack(spacing: Airi.space2) {
                AiriButton(title: L("Add Folder…"), icon: "folder.badge.plus",
                           variant: .secondary) {
                    pickCustomRoots()
                }
                if customRoots.isEmpty {
                    Text(L("Pick at least one folder to scan."))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                }
                Spacer()
            }
            .padding(.top, customRoots.isEmpty ? 0 : 2)
        }
    }

    private func customRootChip(_ path: String) -> some View {
        let exists = Self.isDirectory(path)
        return HStack(spacing: Airi.space2) {
            Image(systemName: exists ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 11))
                .foregroundStyle(exists ? Airi.primary : Airi.warning)
            Text(pathDisplay(path))
                .font(Airi.captionFont)
                .foregroundStyle(exists ? Airi.neutral800 : Airi.warning)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if !exists {
                Text(L("Folder not found"))
                    .font(Airi.caption2Font)
                    .foregroundStyle(Airi.warning)
            }
            Spacer()
            Button {
                removeCustomRoot(path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Airi.neutral400)
            }
            .buttonStyle(.plain)
            .help(L("Remove folder"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
                .fill(Airi.neutral100.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: Airi.radiusControl, style: .continuous)
                        .strokeBorder(exists ? Airi.neutral200.opacity(0.6)
                                      : Airi.warning.opacity(0.45), lineWidth: 1)
                )
        )
    }

    /// NSOpenPanel rather than a text field: the folder must exist, and the
    /// picker starts at the last saved folder so repeat scans are one click.
    private func pickCustomRoots() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = L("Choose folders to scan")
        panel.prompt = L("Add")
        if let last = customRoots.last {
            panel.directoryURL = URL(fileURLWithPath: last)
        }
        guard panel.runModal() == .OK else { return }
        var roots = customRoots
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !roots.contains(path) { roots.append(path) }
        }
        updateCustomRoots(roots)
    }

    private func removeCustomRoot(_ path: String) {
        updateCustomRoots(customRoots.filter { $0 != path })
    }

    /// Rows came from the previous folder set, so changing the set clears
    /// them — otherwise files from a removed folder linger on screen and can
    /// still be ticked into the Trash.
    private func updateCustomRoots(_ roots: [String]) {
        guard roots != customRoots else { return }
        customRoots = roots
        LargeFilesEngine.CustomRoots.save(roots)
        files = []
        selected = []
        lastMessage = nil
        warningMessage = nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private func scan() async {
        scanning = true
        lastMessage = nil
        warningMessage = nil
        scanProgress = nil

        // Custom scope: drop folders deleted since they were saved, so the
        // chips and the scan agree on what is actually searched.
        if scope == .custom {
            let alive = customRoots.filter(Self.isDirectory)
            if alive.count != customRoots.count {
                customRoots = alive
                LargeFilesEngine.CustomRoots.save(alive)
            }
            guard !alive.isEmpty else {
                files = []
                selected = []
                warningMessage = L("None of the chosen folders exist anymore — add a folder and scan again.")
                scanning = false
                return
            }
        }

        let found = await LargeFilesEngine.find(minBytes: minSize.bytes, scope: scope,
                                                customRoots: customRoots) { done, total in
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
            let root: String
            switch scope {
            case .wholeHome:
                root = NSHomeDirectory()
            case .custom:
                root = customRoots.first ?? NSHomeDirectory()
            case .userFolders, .containers:
                root = scope.roots.first?
                    .replacingOccurrences(of: "~", with: NSHomeDirectory()) ?? NSHomeDirectory()
            }
            if !(await LargeFilesEngine.spotlightWorks(in: root)) {
                warningMessage = L("Spotlight indexing seems off — results may be incomplete. Turn it on in System Settings → Siri & Spotlight.")
            }
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
                        .help(Self.lockReason(file.url))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.url.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Airi.neutral900)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(pathDisplay(file.url.path)
                         + (modified.map { " · " + String(format: L("modified %@"), L10n.date($0, timeStyle: .none)) } ?? ""))
                        .font(Airi.caption2Font)
                        // Path/date data, not chrome: 10pt at neutral400 sat
                        // around 2.4:1 on a white card.
                        .foregroundStyle(Airi.neutral500)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.url.path)
                    if !deletable {
                        Text(Self.lockReason(file.url))
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.warning)
                            .lineLimit(1)
                    }
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
        // Multi-GB files take real time to move to the Trash; without a
        // counter the page just sat there and read as frozen.
        batch = BatchProgress(title: L("Moving to the Trash…"), done: 0, total: picked.count)
        let startedAt = Date()
        var removed: [(String, Int64)] = []
        var failed: [(String, String)] = []
        for (index, file) in picked.enumerated() {
            batch?.detail = file.url.lastPathComponent
            do {
                try await Task.detached {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                }.value
                removed.append((file.url.path, file.bytes))
            } catch {
                failed.append((file.url.path, error.localizedDescription))
            }
            batch?.done = index + 1
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
        await BatchProgressHold.until(startedAt)
        batch = nil
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

    // Deletions here are user-initiated (rows are hand-picked, then a
    // confirmation dialog runs), so the relaxed policy applies: protected
    // home categories are deletable on explicit request, while system
    // locations, the home root and the whitelist stay locked.
    private static func deletable(_ url: URL) -> Bool {
        SafetyGuard.checkDeletable(url, policy: .userConfirmed).allowed
    }

    /// Human reason a row is locked, straight from the safety layer.
    private static func lockReason(_ url: URL) -> String {
        guard let reason = SafetyGuard.checkDeletable(url, policy: .userConfirmed).reason else {
            return L("Locked")
        }
        if reason.hasPrefix("protected category: ") {
            let category = String(reason.dropFirst("protected category: ".count))
            return String(format: L("Locked: inside ~/%@ (protected user data)"), category)
        }
        if reason.hasPrefix("whitelisted by user") {
            return L("Locked: on your whitelist")
        }
        if reason.hasPrefix("protected system location") {
            return L("Locked: protected system location")
        }
        if reason == "outside user home directory" {
            return L("Locked: outside your home folder")
        }
        return String(format: L("Locked: %@"), reason)
    }
}
