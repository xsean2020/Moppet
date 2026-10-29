import SwiftUI
import AppKit

/// Disk usage explorer — `mo analyze` as the two-pane reference layout:
/// LEFT a per-level list (select circle · icon · name · item count · size ·
/// open chevron), RIGHT a bubble map where each bubble's area matches its
/// share of the layer's bytes. Breadcrumb at the top drills down one level
/// per click; clicking a list row or a bubble opens that folder's layer.
/// Tick paths (any level) and move them to the Trash, guarded by the
/// safety layer.
struct AnalyzeView: View {
    var onClose: (() -> Void)?

    // MARK: One-shot scan sources
    //
    // The page is a SINGLE scan over exactly the locations where macOS keeps
    // big files (mo analyze alignment): the user library's heavyweight
    // subdirectories (caches, logs, app support + iOS backups, containers,
    // mail…), the developer toolchains (Xcode DerivedData / CoreSimulator,
    // npm), the regular home folders (Downloads, Documents…), and the
    // system-global caches plus the Trash. The top layer lists each source
    // itself with its real path (e.g. "~/Library/Caches" vs
    // "/Library/Caches"); clicking one drills into its real directory.
    // Navigation is read-only — deletion still routes through SafetyGuard,
    // which refuses protected system paths.

    static let scanSources: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let appSupport = library.appendingPathComponent("Application Support", isDirectory: true)
        return [
            // 一、用户资源库
            library.appendingPathComponent("Caches", isDirectory: true),
            library.appendingPathComponent("Logs", isDirectory: true),
            appSupport,
            appSupport.appendingPathComponent("MobileSync/Backup", isDirectory: true),
            library.appendingPathComponent("Containers", isDirectory: true),
            library.appendingPathComponent("Group Containers", isDirectory: true),
            library.appendingPathComponent("Saved Application State", isDirectory: true),
            library.appendingPathComponent("WebKit", isDirectory: true),
            library.appendingPathComponent("Mail", isDirectory: true),
            library.appendingPathComponent("Messages", isDirectory: true),
            // 二、开发者与工具
            library.appendingPathComponent("Developer", isDirectory: true),
            home.appendingPathComponent(".npm/_cacache", isDirectory: true),
            // 三、常规用户文件夹
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true),
            home.appendingPathComponent("Music", isDirectory: true),
            // 四、系统全局
            URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
            home.appendingPathComponent(".Trash", isDirectory: true),
        ]
    }()

    /// "~/Library/Caches" / "/Library/Caches" — top-level rows carry the
    /// shortened real path because several sources share a lastPathComponent.
    static func displayName(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home), path != home else { return path }
        return "~" + path.dropFirst(home.count)
    }

    @State private var rootChildren: [FileNode] = []
    @State private var scanning = false
    /// Ticked ids → the node they came from. A dictionary, not a `Set` of
    /// ids: the old shape resolved the ticked ids by walking the ENTIRE
    /// loaded tree on every body evaluation (`rootChildrenRecursive`), so a
    /// selection toggle or a streamed size update cost a full traversal of
    /// every expanded layer. Selection only ever grows by user clicks, so
    /// remembering the node at tick time keeps the footer at O(selected).
    @State private var selected: [String: FileNode] = [:]
    @State private var confirmingTrash = false
    /// Task handle so a running scan can be cancelled from the UI.
    @State private var scanTask: Task<Void, Never>?
    /// (completed, total) entries measured — drives the progress bar.
    @State private var progress: (done: Int, total: Int)? = nil
    /// Progress of the running delete batch — drives the center overlay ring.
    /// Seeded at init by the debug probe so an offscreen render can capture the
    /// ring without deleting anything or waiting for `.task`.
    @State private var deleteProgress: BatchProgress? = AnalyzeView.debugSeed.map {
        BatchProgress(title: L("Deleting…"), done: $0.done, total: $0.total)
    }
    /// Drill-down path; empty = the home root. The visible layer is the
    /// last node's loaded children (or the root list).
    @State private var path: [FileNode] = []

    /// Loading state for the layer the user is drilling INTO (before the
    /// node is pushed onto the path). Without this the UI showed no feedback
    /// during a slow load — the user clicked a big folder and nothing happened.
    @State private var pendingDrillDown: FileNode?

    var currentChildren: [FileNode] { path.last?.children ?? rootChildren }
    var currentLayerLoading: Bool { path.last?.loadingChildren ?? false }

    /// Ticked nodes, sorted by path so the audit record the deletion writes
    /// is stable across runs (dictionary order is not).
    var selectedNodes: [FileNode] {
        selected.values.sorted { $0.url.path < $1.url.path }
    }
    var selectedBytes: Int64 { selected.values.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("Analyze"),
                       subtitle: L("Expand folders to size them — tick paths to delete"),
                       onBack: onClose.map { close in { close() } })
            Divider().overlay(Airi.neutral200.opacity(0.5))
            // Never stack two rings: the first-scan ring and the delete ring
            // would sit on top of each other.
            if scanning && rootChildren.isEmpty && deleteProgress == nil {
                initialScanPane
            } else {
                explorerPane
            }
            bottomBar
        }
        .background(Airi.pageBackground.opacity(0.001))
        .overlay {
            if let deleteProgress {
                BatchProgressOverlay(progress: deleteProgress)
            }
        }
        .animation(Airi.controlAnimation, value: deleteProgress == nil)
        .task { startScan() }
    }

    /// Debug hook (`--probe-analyze`): a synthetic in-flight batch so the
    /// delete ring can be rendered and inspected without touching real files.
    nonisolated(unsafe) static var debugSeed: (done: Int, total: Int)? =
        CommandLine.arguments.contains("--probe-analyze") ? (7, 12) : nil

    // MARK: - Explorer (breadcrumb + list + bubble map)

    private var explorerPane: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider().overlay(Airi.neutral200.opacity(0.5))
            HStack(spacing: 0) {
                entryList
                    .frame(width: 380)
                Divider().overlay(Airi.neutral200.opacity(0.5))
                ZStack {
                    if currentLayerLoading || pendingDrillDown != nil {
                        VStack(spacing: Airi.space2) {
                            ProgressView().controlSize(.large)
                            if let pending = pendingDrillDown {
                                Text(String(format: L("Opening %@…"), pending.url.lastPathComponent))
                                    .font(Airi.captionFont)
                                    .foregroundStyle(Airi.neutral500)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        BubbleChart(nodes: currentChildren) { node in
                            drillDown(node)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Airi.neutral50.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Root chip + `Library › Caches` — the chip jumps back to the top
    /// source layer; any segment click jumps back to it.
    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            CircleIconButton(icon: "chevron.left") { goUp() }
                .disabled(path.isEmpty)
                .opacity(path.isEmpty ? 0.35 : 1)
            Button {
                withAnimation(Airi.controlAnimation) { path = [] }
            } label: {
                Label(L("Analyze"), systemImage: "scope")
                    .font(Airi.footnoteFont.weight(.medium))
                    .foregroundStyle(path.isEmpty ? Airi.primary : Airi.neutral700)
            }
            .buttonStyle(.plain)
            ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Airi.neutral400)
                Button {
                    withAnimation(Airi.controlAnimation) { path = Array(path[...index]) }
                } label: {
                    Text(node.url.lastPathComponent)
                        .font(Airi.footnoteFont.weight(.medium))
                        .foregroundStyle(index == path.count - 1 ? Airi.primary : Airi.neutral700)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(String(format: L("%@ total"), currentChildren.reduce(0) { $0 + $1.bytes }.bytesFormatted))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
        }
        .padding(.horizontal, Airi.space2)
        .padding(.vertical, 8)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(currentChildren) { node in
                    EntryRow(node: node,
                             isSelected: selected[node.id] != nil,
                             onToggle: {
                                 if selected[node.id] != nil {
                                     selected[node.id] = nil
                                 } else {
                                     selected[node.id] = node
                                 }
                             },
                             onOpen: { drillDown(node) })
                }
            }
            .padding(Airi.space2)
        }
    }

    /// First-scan progress — a large ring replaces the explorer until the
    /// root layer lands. (Was a thin linear bar: technically fine but easy
    /// to miss; the ring makes the measuring stage a visible centerpiece.)
    private var initialScanPane: some View {
        VStack(spacing: Airi.space3) {
            Spacer()
            let done = progress?.done ?? 0
            let total = max(progress?.total ?? 0, 1)
            ProgressRing(
                progress: Double(done) / Double(total),
                lineWidth: 12,
                showValue: true,
                valueText: "\(Int(Double(done) / Double(total) * 100))%",
                valueFontSize: 20
            )
            .frame(width: 132, height: 132)
            HStack(spacing: 4) {
                TickingNumber(value: done)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Airi.neutral900)
                Text("/ \(progress?.total ?? 0) \(L("entries"))")
                    .font(Airi.bodyFont)
            }
            .foregroundStyle(Airi.neutral500)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: done)
            Text(L("Measuring big-file locations…"))
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
            AiriButton(title: L("Cancel"), icon: "xmark", variant: .secondary) {
                cancelScan()
            }
            .padding(.top, Airi.space1)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: Airi.space2) {
            if scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Scanning…")).font(Airi.captionFont).foregroundStyle(Airi.neutral500)
                }
            }
            Text("\(selected.count) selected · \(selectedBytes.bytesFormatted)")
                .font(Airi.captionFont)
                .foregroundStyle(Airi.neutral500)
                .monospacedDigit()
                .animation(.spring(response: 0.4, dampingFraction: 0.9), value: selected.count)
            Spacer()
            if !selected.isEmpty, deleteProgress == nil {
                AiriButton(title: String(format: L("Delete %lld"), selected.count), icon: "trash.fill",
                           variant: .destructive) { confirmingTrash = true }
            }
            AiriButton(title: scanning ? L("Scanning…") : L("Rescan"), icon: "arrow.clockwise",
                       variant: .secondary, disabled: scanning || deleteProgress != nil) {
                startScan()
            }
        }
        .padding(Airi.space4)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().overlay(Airi.neutral200.opacity(0.5)) }
        .confirmationDialog(
            Text(String(format: L("Delete %lld items (%@) permanently?"), selected.count, selectedBytes.bytesFormatted)),
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) { trashSelection() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Items are deleted permanently. This cannot be undone."))
        }
    }

    // MARK: - Navigation

    /// Open a folder's layer in TWO phases:
    ///   1. INSTANT — an `ls`-grade listing (one readdir + stat per child)
    ///      pushes the layer onto the path within milliseconds. Directories
    ///      without a warm cache entry show "Measuring…" until phase 2.
    ///   2. STREAM — real sizes fill in the background, one directory at a
    ///      time, each row rising into its sorted place as it lands.
    /// The old code awaited a full recursive sizing of EVERY child before
    /// showing anything, so entering a big directory froze for seconds.
    private func drillDown(_ node: FileNode) {
        guard node.isDirectory else { return }
        guard !node.loadingChildren else { return }
        if node.loaded {
            // Instant switch — animating a whole 100-row list + bubble map
            // re-layout was a visible stutter on drill-down.
            path.append(node)
            return
        }
        node.loadingChildren = true
        pendingDrillDown = node
        let url = node.url
        let pathSnapshot = path.map(\.url.path)
        Task {
            // Phase 1 — off the main thread because it stats every child
            // (127 entries in ~/Library → ~254 syscalls). Warm SizeCache
            // entries land with real sizes; the rest are marked pending.
            let listed = await Task.detached {
                ScanEngine.listChildren(of: url, limit: 500)
            }.value
            node.children = listed.map {
                FileNode(url: $0.url, bytes: $0.bytes, isDirectory: $0.isDirectory,
                         fileCount: $0.fileCount,
                         sizePending: $0.isDirectory && $0.bytes == 0)
            }
            node.loaded = true
            node.loadingChildren = false
            // Clear the pending indicator — must fire before the navigation
            // guard so the spinner disappears even if the user navigated away.
            if pendingDrillDown == node { pendingDrillDown = nil }
            // Only drill in if the user is still where they were when they
            // clicked — a slow scan completing after navigation used to
            // yank the view to a layer nobody asked for. Navigation away
            // must NOT skip phase 2 below: the tree keeps filling for
            // when the user comes back.
            if pathSnapshot == path.map(\.url.path) {
                path.append(node)   // instant switch (no whole-layer animation)
            }

            // Phase 2 — stream real sizes. Runs on even if the user already
            // navigated away: the tree keeps filling for when they return.
            // parallelSize consults SizeCache, so warm entries are free.
            // Entries travel through an AsyncStream so the @Sendable sizing
            // callback only captures the (Sendable) continuation — FileNode
            // updates happen right here on the main actor.
            guard node.children.contains(where: { $0.sizePending }) else { return }
            let nodesByPath = Dictionary(
                node.children.map { ($0.url.path, $0) },
                uniquingKeysWith: { first, _ in first })
            let (stream, continuation) = AsyncStream.makeStream(of: ScanEngine.SpaceEntry.self)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = await ScanEngine.topChildren(of: url, limit: 500, onEntry: {
                        continuation.yield($0)
                    })
                    continuation.finish()
                }
                // Rows re-sort at most ~7×/s while sizes stream in. Sorting
                // the whole layer on EVERY landed entry was O(n² log n) for
                // a 500-row directory (500 sorts of 500 rows) and the list
                // visibly jittered; the final sort below still leaves it
                // perfectly ordered.
                var lastSort = Date.distantPast
                for await entry in stream {
                    guard let target = nodesByPath[entry.id] else { continue }
                    target.bytes = entry.bytes
                    target.fileCount = entry.fileCount
                    target.sizePending = false
                    // Newly measured folders rise into their sorted place.
                    if Date().timeIntervalSince(lastSort) > 0.15 {
                        lastSort = Date()
                        node.children.sort { $0.bytes > $1.bytes }
                    }
                }
            }
            // Zero-byte entries never stream an update (topChildren skips
            // them) — settle every leftover pending flag so no row sticks
            // on "Measuring…" forever.
            node.children.forEach { $0.sizePending = false }
            node.children.sort { $0.bytes > $1.bytes }
        }
    }

    private func goUp() {
        guard !path.isEmpty else { return }
        _ = withAnimation(Airi.controlAnimation) { path.removeLast() }
    }

    // MARK: - Scan

    private func startScan() {
        guard scanTask == nil else { return }
        progress = nil
        let sources = Self.scanSources
        scanning = true
        if rootChildren.isEmpty {
            PetBus.shared.say(L("Measuring big-file locations…"), state: .scanning)
        }
        scanTask = Task {
            // Phase 1 — INSTANT: the top layer IS the source list. Each
            // source lands as one row; warm SizeCache entries show their
            // real size in the first frame, cold ones show "Measuring…"
            // and stream in. Nonexistent sources (no iOS backups, no npm
            // cache) are dropped instead of showing empty rows.
            let listed = await Task.detached {
                sources.compactMap { source -> ScanEngine.SpaceEntry? in
                    guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                    if let cached = SizeCache.shared.lookup(source) {
                        return ScanEngine.SpaceEntry(id: source.path, url: source,
                                                     bytes: cached.bytes, isDirectory: true,
                                                     fileCount: cached.files)
                    }
                    return ScanEngine.SpaceEntry(id: source.path, url: source,
                                                 bytes: 0, isDirectory: true, fileCount: 0)
                }
                .sorted { $0.bytes > $1.bytes }
            }.value
            let nodes = listed.map {
                FileNode(url: $0.url, bytes: $0.bytes, isDirectory: $0.isDirectory,
                         fileCount: $0.fileCount,
                         sizePending: $0.bytes == 0,
                         displayName: Self.displayName(for: $0.url))
            }
            // Rescan rebuilds every node (fresh UUIDs) — stale ids dangled
            // and left a dead "N selected" footer behind.
            selected.removeAll()
            withAnimation(Airi.entranceCurve) { rootChildren = nodes; path = [] }
            scanning = false
            progress = nil

            // Phase 2 — stream real sizes for pending sources. parallelSize
            // consults SizeCache (warm sources are free) and STORES each
            // result, so drilling into a source afterwards is instant too.
            // Same AsyncStream shape as drillDown: @Sendable side sees only
            // the continuation.
            let pending = nodes.filter { $0.sizePending }
            guard !pending.isEmpty else {
                celebrateScan(nodes)
                return
            }
            let nodesByPath = Dictionary(
                nodes.map { ($0.url.path, $0) },
                uniquingKeysWith: { first, _ in first })
            let (stream, continuation) = AsyncStream.makeStream(of: ScanEngine.SpaceEntry.self)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Every source sized concurrently, all streaming into
                    // the same channel.
                    await withTaskGroup(of: Void.self) { inner in
                        for source in sources {
                            inner.addTask {
                                let summary = await ScanEngine.parallelSize(of: source)
                                guard summary.bytes > 0 || summary.files > 0 else { return }
                                continuation.yield(ScanEngine.SpaceEntry(
                                    id: source.path, url: source,
                                    bytes: summary.bytes, isDirectory: true,
                                    fileCount: summary.files))
                            }
                        }
                    }
                    continuation.finish()
                }
                // Rows re-sort at most ~7×/s while sizes stream in.
                var lastSort = Date.distantPast
                for await entry in stream {
                    guard let target = nodesByPath[entry.id] else { continue }
                    target.bytes = entry.bytes
                    target.fileCount = entry.fileCount
                    target.sizePending = false
                    if Date().timeIntervalSince(lastSort) > 0.15 {
                        lastSort = Date()
                        rootChildren.sort { $0.bytes > $1.bytes }
                    }
                }
            }
            scanTask = nil
            guard !Task.isCancelled else { return }
            // Zero-byte entries never stream an update — settle the flags.
            rootChildren.forEach { $0.sizePending = false }
            rootChildren.sort { $0.bytes > $1.bytes }
            celebrateScan(rootChildren)
        }
    }

    private func celebrateScan(_ nodes: [FileNode]) {
        PetBus.shared.say(
            String(format: L("Measured %lld entries (%@)"), nodes.count,
                   nodes.reduce(0) { $0 + $1.bytes }.bytesFormatted),
            state: .celebrating)
    }

    /// Abort the running pass: on-disk sizing of already-started entries
    /// finishes in the background (its results are discarded), but the UI
    /// is back immediately with the previous tree and selection intact.
    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanning = false
        progress = nil
        PetBus.shared.settle()
    }

    private func trashSelection() {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        // The user hand-picked these paths and confirmed the dialog — this
        // is a user-initiated delete, so the relaxed policy applies
        // (protected home categories are allowed; system paths, the home
        // root and the whitelist still refuse). One verdict per path: the
        // old code called `checkDeletable` twice (allowed + blocked), which
        // doubles the symlink resolution and whitelist matching.
        var deletable: [FileNode] = []
        var blocked: [FileNode] = []
        for node in nodes {
            if SafetyGuard.checkDeletable(node.url, policy: .userConfirmed).allowed {
                deletable.append(node)
            } else {
                blocked.append(node)
            }
        }
        guard !deletable.isEmpty else {
            PetBus.shared.say(L("Those paths are protected — nothing was deleted."), state: .sad)
            return
        }
        // Ring in the middle of the page: per-path delete of a big tree can
        // take seconds, and without it the window looked frozen.
        deleteProgress = BatchProgress(title: L("Deleting…"), done: 0, total: deletable.count)
        let startedAt = Date()
        Task {
            // Parallel tiered batch delete (BatchDeleter): small seeds go
            // through ONE recursive removeItem call each; huge trees expand
            // once and unlink their leaves over a bounded worker pool. The
            // ring repaints per chunk. The old loop hopped the main actor
            // once per file and repainted per file — a directory of small
            // files took ages and drowned SwiftUI in updates.
            let progress: BatchDeleter.Progress = { done, total, detail in
                deleteProgress?.total = total
                deleteProgress?.done = done
                if !detail.isEmpty { deleteProgress?.detail = detail }
            }
            // The sizing pass already measured every node's recursive entry
            // count — hand it over so BatchDeleter can tier without walking.
            let hints = Dictionary(
                deletable.map { ($0.url.path, $0.fileCount) },
                uniquingKeysWith: { first, _ in first })
            let outcome = await BatchDeleter.remove(
                urls: deletable.map(\.url), fileCounts: hints, progress: progress)

            // A node is gone iff nothing of it is left on disk — this also
            // folds parent+child selections (select-all in an expanded
            // tree) into a single "removed" verdict: whichever path won the
            // race, the whole subtree is gone.
            let fm = FileManager.default
            var removed: [FileNode] = []
            var failures: [(node: FileNode, error: String)] = []
            for node in deletable {
                if fm.fileExists(atPath: node.url.path) {
                    let message = outcome.failures
                        .first { $0.path == node.url.path || $0.path.hasPrefix(node.url.path + "/") }?
                        .error ?? L("Some contents could not be deleted")
                    failures.append((node, message))
                } else {
                    removed.append(node)
                }
            }
            let freed = removed.reduce(0) { $0 + $1.bytes }
            let record = CleanRecord(
                date: Date(), sectionTitles: [
                    String(format: L("%lld analyzed paths"), nodes.count)
                ],
                requestedBytes: freed, freedBytes: freed, itemCount: nodes.count,
                items: removed.map {
                    CleanRecordItem(path: $0.url.path, bytes: $0.bytes, mode: .permanent,
                                    success: true, error: nil)
                } + failures.map {
                    CleanRecordItem(path: $0.node.url.path, bytes: $0.node.bytes, mode: .permanent,
                                    success: false, error: $0.error)
                } + blocked.map {
                    CleanRecordItem(path: $0.url.path, bytes: $0.bytes, mode: .permanent,
                                    success: false, error: "blocked by safety guard")
                }, source: .analyze)
            HistoryStore.append(record)
            if removed.isEmpty {
                // All paths failed: the old code still celebrated "Deleted 0
                // paths", which reads as success for a no-op.
                PetBus.shared.say(L("Nothing was deleted — those paths are protected or in use."),
                                  state: .sad)
            } else {
                UXFeedback.success()
                PetBus.shared.say(String(format: L("Deleted %lld paths 🗑"), removed.count),
                                  state: .celebrating)
            }
            selected.removeAll()
            // Shrink the tree in place instead of re-measuring the whole home
            // folder (seconds of work that also threw the user back to the
            // root layer). Every parent row, the breadcrumb total and the
            // bubble map read these values.
            for node in removed { applyRemoval(of: node) }
            // The root sources' own summaries aren't derivable from the tree
            // (the tree holds their CHILDREN, capped at the display limit) —
            // drop those single entries so nothing serves a pre-delete total.
            // Every child entry was just refreshed by applyDeletion, so the
            // next visit hits the warm fast path instead of a full re-scan.
            for source in Self.scanSources {
                SizeCache.shared.remove(source)
            }
            // A handful of small files deletes in a few milliseconds — the
            // ring would appear and vanish inside one frame, which reads as a
            // glitch. Hold it long enough to register, then fade out onto the
            // already-updated list.
            await BatchProgressHold.until(startedAt)
            deleteProgress = nil
        }
    }

    /// Drop a deleted node from the in-memory tree and subtract its bytes from
    /// every ancestor (see `FileNode.applyDeletion`).
    private func applyRemoval(of node: FileNode) {
        FileNode.applyDeletion(id: node.id, in: &rootChildren)
    }
}

// MARK: - Lazy node

@Observable
final class FileNode: Identifiable, Equatable {
    let id = UUID().uuidString
    let url: URL
    /// Identity equality: each instance owns a unique UUID, so two nodes are
    /// equal iff they are the same object. Required by `pendingDrillDown ==
    /// node` and by `BubbleChart.Bubble: Equatable` (which stores a node).
    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    /// Mutable: deleting a child subtracts its bytes from every ancestor so
    /// the list, breadcrumb total and bubble map stay correct without a full
    /// re-measure of the home folder.
    var bytes: Int64
    let isDirectory: Bool
    /// Entries inside (from the sizing pass) — "34 items" sub-label.
    var fileCount: Int
    var children: [FileNode] = []
    var loadingChildren = false
    var loaded = false
    /// Directory whose recursive size has NOT been measured yet (instant
    /// ls-grade listing served the layer first). The row shows "Measuring…"
    /// until the background sizing pass fills `bytes`.
    var sizePending = false
    /// Optional row label override — top-level source rows show the real
    /// shortened path ("~/Library/Caches" vs "/Library/Caches"); regular
    /// child nodes keep their lastPathComponent.
    let displayName: String?

    init(url: URL, bytes: Int64, isDirectory: Bool, fileCount: Int = 0,
         sizePending: Bool = false, displayName: String? = nil) {
        self.url = url
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.fileCount = fileCount
        self.sizePending = sizePending
        self.displayName = displayName
    }

    var label: String {
        displayName ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    }

    /// Drop the node `id` from the tree and subtract its size from every
    /// ancestor, so the list rows, the breadcrumb total and the bubble map all
    /// reflect the deletion immediately — no full re-measure of the home
    /// folder (seconds of work, and it used to throw the user back to root).
    ///
    /// Cache handling is UPDATE, not invalidate: the in-memory tree knows each
    /// ancestor's exact post-delete bytes, so their summaries are re-stored
    /// with the current mtime. The old chain-invalidate threw away every
    /// ancestor's entry — which busted the Analyze fast path (`missed == 0`)
    /// and forced a full re-scan on the next visit. Only the deleted node's
    /// own entry is removed; deeper entries under it self-heal via mtime if
    /// the path ever reappears.
    @discardableResult
    static func applyDeletion(id: String, in list: inout [FileNode]) -> Bool {
        var ancestors: [FileNode] = []
        guard let node = detach(id: id, from: &list, ancestors: &ancestors) else { return false }
        SizeCache.shared.remove(node.url)
        for ancestor in ancestors {
            ancestor.bytes = max(0, ancestor.bytes - node.bytes)
            ancestor.fileCount = max(0, ancestor.fileCount - max(1, node.fileCount))
            SizeCache.shared.store(
                ancestor.url,
                summary: ScanEngine.SizeSummary(bytes: ancestor.bytes,
                                                files: ancestor.fileCount))
        }
        return true
    }

    /// Depth-first removal; `ancestors` collects the chain from the root down
    /// to (but excluding) the removed node.
    private static func detach(id: String, from list: inout [FileNode],
                               ancestors: inout [FileNode]) -> FileNode? {
        if let index = list.firstIndex(where: { $0.id == id }) {
            return list.remove(at: index)
        }
        for index in list.indices where !list[index].children.isEmpty {
            ancestors.append(list[index])
            if let node = detach(id: id, from: &list[index].children, ancestors: &ancestors) {
                return node
            }
            ancestors.removeLast()
        }
        return nil
    }
}

// MARK: - List row (select circle · icon · name/count · size · chevron)

private struct EntryRow: View {
    let node: FileNode
    let isSelected: Bool
    var onToggle: () -> Void
    var onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Select circle (the reference design's radio-style tick).
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Airi.primary : Airi.neutral400)
            }
            .buttonStyle(.plain)
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.label)
                    .font(Airi.footnoteFont.weight(.medium))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.sizePending {
                    // Instant-listing placeholder — the real size streams in
                    // from the background pass and this flips to "N items".
                    Text(L("Measuring…"))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                } else if node.fileCount > 0 {
                    Text(String(format: L("%lld items"), node.fileCount))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            Text(node.sizePending ? "…" : node.bytes.bytesFormatted)
                .font(Airi.footnoteFont.weight(.medium))
                .foregroundStyle(Airi.neutral700)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Airi.primary : Airi.neutral400)
            } else {
                Color.clear.frame(width: 10)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusControl)
                .fill(isSelected ? Airi.primary.opacity(0.08)
                      : hovering ? Airi.neutral100.opacity(0.7) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Row body opens a folder; files are toggle-only (via the circle).
            if node.isDirectory { onOpen() } else { onToggle() }
        }
        .help(node.isDirectory ? L("Click to enter") : node.url.path)
    }
}

// MARK: - Bubble map (area ∝ bytes, click to enter)

private struct BubbleChart: View {
    let nodes: [FileNode]
    var onOpen: (FileNode) -> Void

    struct Bubble: Identifiable {
        let id: String
        let node: FileNode
        /// Layout-space coordinates; the view maps the layout bounding box
        /// into the container with an aspect-fit.
        let x: Double
        let y: Double
        let r: Double
    }

    /// Cached bubble layout — `pack` is O(n²×6000) per render, and a
    /// 30-node layer made every scroll/resize frame stutter. Cache on an
    /// id+bytes signature so a re-render with the same data is free, and a
    /// streaming size update (bytes 0 → real) forces exactly one repack.
    /// The sized set is computed canonically (bytes-desc, capped) so live
    /// re-sorts of the underlying list don't invalidate the cache.
    @State private var cachedBubbles: [Bubble] = []
    @State private var cachedSignature: [String] = []
    /// Bubble layout is quadratic — an ls-grade layer can list 500 entries,
    /// but only the top handful are visually meaningful as bubbles.
    static let maxBubbles = 30

    private var bubbles: [Bubble] {
        let sized = Array(nodes.filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
            .prefix(Self.maxBubbles))
        let signature = sized.map { "\($0.id):\($0.bytes)" }
        if signature == cachedSignature, !cachedBubbles.isEmpty {
            return cachedBubbles
        }
        let packed = Self.pack(sized)
        cachedBubbles = packed
        cachedSignature = signature
        return packed
    }

    var body: some View {
        GeometryReader { geo in
            let bubbles = self.bubbles
            if bubbles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Airi.neutral400)
                    Text(L("Nothing measurable in this folder"))
                        .font(Airi.captionFont)
                        .foregroundStyle(Airi.neutral400)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let bbox = Self.bounds(of: bubbles)
                let scale = min(geo.size.width / bbox.w, geo.size.height / bbox.h)
                let offset = CGPoint(
                    x: (geo.size.width - bbox.w * scale) / 2,
                    y: (geo.size.height - bbox.h * scale) / 2)
                ZStack {
                    ForEach(bubbles) { bubble in
                        BubbleView(bubble: bubble, scale: scale) {
                            onOpen(bubble.node)
                        }
                        .position(
                            x: offset.x + (bubble.x - bbox.minX) * scale,
                            y: offset.y + (bubble.y - bbox.minY) * scale)
                    }
                }
                .animation(Airi.cardAnimation, value: bubbles.map(\.id))
            }
        }
        .clipped()
    }

    /// One bubble: primary-tinted circle, folder/doc glyph, name when it fits.
    private struct BubbleView: View {
        let bubble: Bubble
        let scale: Double
        var onOpen: () -> Void

        @State private var hovering = false

        var body: some View {
            let d = max(8, bubble.r * 2 * scale)
            VStack(spacing: 1) {
                Image(systemName: bubble.node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: max(11, min(d * 0.30, 24))))
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                if d > 52 {
                    Text(bubble.node.label)
                        .font(.system(size: max(8, min(11, d * 0.13))))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                    // Size on the bubble — the whole point of the map is
                    // comparing "what's big"; without the number you'd have
                    // to cross-read the list.
                    Text(bubble.node.bytes.bytesFormatted)
                        .font(.system(size: max(8, min(10, d * 0.11))))
                        .fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                }
            }
            .frame(width: d, height: d)
            .background(
                Circle().fill(
                    LinearGradient(colors: [Airi.primary.opacity(hovering ? 0.85 : 0.62),
                                            Airi.primary600.opacity(hovering ? 0.95 : 0.8)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .shadow(color: Airi.primary.opacity(hovering ? 0.3 : 0.12),
                        radius: hovering ? 10 : 5, y: 3)
            )
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(Airi.controlAnimation, value: hovering)
            .onTapGesture {
                if bubble.node.isDirectory { onOpen() }
            }
            .help("\(bubble.node.url.lastPathComponent) · \(bubble.node.bytes.bytesFormatted)\(bubble.node.isDirectory ? " — \(L("Click to enter"))" : "")")
        }
    }

    /// Greedy spiral packing, largest first: place at the first collision-free
    /// spot on an outward spiral from the center. Deterministic (fixed start
    /// angle, size-sorted input). Bubble area is NOT to scale — radius scales
    /// with sqrt(bytes) so small entries stay clickable (perceptual scaling).
    static func pack(_ nodes: [FileNode]) -> [Bubble] {
        let sized = nodes.filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
        guard !sized.isEmpty else { return [] }
        let maxBytes = Double(sized[0].bytes)
        let maxR = 100.0, minR = 12.0
        var placed: [(x: Double, y: Double, r: Double)] = []
        var bubbles: [Bubble] = []
        for node in sized {
            let r = max(minR, sqrt(Double(node.bytes) / maxBytes) * maxR)
            if placed.isEmpty {
                placed.append((0, 0, r))
            } else {
                var dist = placed[0].r + r
                var angle = 0.0
                var found = false
                // 4pt breathing room, hoisted: the inner loop runs up to
                // 6000 × placed.count times and used to call `pow()` for a
                // plain square on every one of them.
                let rPad = r + 4
                for _ in 0..<6000 {
                    let cx = dist * cos(angle), cy = dist * sin(angle)
                    var collides = false
                    for other in placed {
                        let dx = other.x - cx, dy = other.y - cy
                        let need = other.r + rPad
                        if dx * dx + dy * dy < need * need {
                            collides = true
                            break
                        }
                    }
                    if !collides {
                        placed.append((cx, cy, r))
                        found = true
                        break
                    }
                    angle += 0.31
                    if angle > 2 * .pi {
                        angle -= 2 * .pi
                        dist += 3
                    }
                }
                if !found { placed.append((dist, 0, r)) }
            }
            bubbles.append(Bubble(id: node.id, node: node,
                                  x: placed.last!.x, y: placed.last!.y, r: r))
        }
        return bubbles
    }

    static func bounds(of bubbles: [Bubble]) -> (minX: Double, minY: Double, w: Double, h: Double) {
        let minX = bubbles.map { $0.x - $0.r }.min() ?? 0
        let maxX = bubbles.map { $0.x + $0.r }.max() ?? 0
        let minY = bubbles.map { $0.y - $0.r }.min() ?? 0
        let maxY = bubbles.map { $0.y + $0.r }.max() ?? 0
        return (minX, minY, max(1, maxX - minX), max(1, maxY - minY))
    }
}
