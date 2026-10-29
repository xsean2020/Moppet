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

    @State private var rootChildren: [FileNode] = []
    @State private var scanning = false
    @State private var selected: Set<String> = []
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

    var currentChildren: [FileNode] { path.last?.children ?? rootChildren }
    var currentLayerLoading: Bool { path.last?.loadingChildren ?? false }

    var selectedNodes: [FileNode] { rootChildrenRecursive.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedNodes.reduce(0) { $0 + $1.bytes } }

    /// Flattened loaded nodes (children load lazily, so selection is
    /// restricted to what has actually been visited and seen).
    var rootChildrenRecursive: [FileNode] {
        var out: [FileNode] = []
        func walk(_ node: FileNode) {
            out.append(node)
            node.children.forEach(walk)
        }
        rootChildren.forEach(walk)
        return out
    }

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
                    if currentLayerLoading {
                        ProgressView().controlSize(.large)
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

    /// `sean › Library › Caches` — click any segment to jump back to it.
    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            CircleIconButton(icon: "chevron.left") { goUp() }
                .disabled(path.isEmpty)
                .opacity(path.isEmpty ? 0.35 : 1)
            Button {
                withAnimation(Airi.controlAnimation) { path = [] }
            } label: {
                Label(NSUserName(), systemImage: "house")
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
                             isSelected: selected.contains(node.id),
                             onToggle: {
                                 if selected.contains(node.id) {
                                     selected.remove(node.id)
                                 } else {
                                     selected.insert(node.id)
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
            Text(L("Measuring your home folder…"))
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

    /// Open a folder's layer: load its sized children once, then push it
    /// onto the breadcrumb path. Clicking a bubble or a list row routes here.
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
        let pathSnapshot = path.map(\.url.path)
        Task {
            // Probe the size cache OFF the main thread. It enumerates the
            // directory and stats every child (127 entries in ~/Library →
            // ~254 syscalls); running that synchronously froze the first
            // click into a folder.
            let (stale, missed) = await Task.detached {
                ScanEngine.cachedTopChildren(of: node.url, limit: 30)
            }.value
            let children: [ScanEngine.SpaceEntry]
            if missed == 0, !stale.isEmpty {
                children = stale
            } else {
                children = await ScanEngine.topChildren(of: node.url, limit: 30)
            }
            node.children = children.map {
                FileNode(url: $0.url, bytes: $0.bytes, isDirectory: $0.isDirectory, fileCount: $0.fileCount)
            }
            node.loaded = true
            node.loadingChildren = false
            // Only drill in if the user is still where they were when they
            // clicked — a slow scan completing after navigation used to
            // yank the view to a layer nobody asked for.
            guard pathSnapshot == path.map(\.url.path) else { return }
            path.append(node)   // instant switch (no whole-layer animation)
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
        let rescan = !rootChildren.isEmpty
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Cache fast-path: SizeCache invalidates on directory mtime, so a
        // full hit means nothing changed under this layer — the snapshot IS
        // the measurement. Serve it SYNCHRONOUSLY so the first frame already
        // has the right state (no "loading flash" then jump); any miss falls
        // through to the real pass, because a partial snapshot would silently
        // HIDE folders.
        if !rescan {
            let (stale, missed) = ScanEngine.cachedTopChildren(of: home, limit: 40)
            if missed == 0, stale.count >= 4, rootChildren.isEmpty {
                rootChildren = stale.map {
                    FileNode(url: $0.url, bytes: $0.bytes, isDirectory: $0.isDirectory, fileCount: $0.fileCount)
                }
                withAnimation(Airi.entranceCurve) { scanning = false }
                PetBus.shared.say(String(format: L("Measured %lld entries (%@)"),
                                         stale.count, stale.reduce(0) { $0 + $1.bytes }.bytesFormatted),
                                  state: .celebrating)
                return
            }
        }
        scanning = true
        if !rescan { PetBus.shared.say(L("Measuring your home folder…"), state: .scanning) }
        scanTask = Task {
            let entries = await ScanEngine.topChildren(of: home, limit: 40) { done, total in
                Task { @MainActor in
                    // Monotonic guard: parallel entries finish out of order
                    // and the @MainActor hop does not preserve ordering —
                    // without this the counter visibly jumps BACKWARD.
                    if done >= (self.progress?.done ?? 0) {
                        self.progress = (done, total)
                    }
                }
            }
            scanTask = nil
            // Cancelled mid-pass → keep whatever is on screen untouched
            // (selection included); the user pressed Cancel, not Rescan.
            guard !Task.isCancelled else { return }
            // Rescan rebuilds every node (fresh UUIDs) — stale ids dangled
            // and left a dead "N selected" footer behind.
            selected.removeAll()
            let nodes = entries.map {
                FileNode(url: $0.url, bytes: $0.bytes, isDirectory: $0.isDirectory, fileCount: $0.fileCount)
            }
            withAnimation(Airi.entranceCurve) { rootChildren = nodes; path = [] }
            scanning = false
            progress = nil
            PetBus.shared.say(
                String(format: L("Measured %lld entries (%@)"), nodes.count,
                       nodes.reduce(0) { $0 + $1.bytes }.bytesFormatted),
                state: .celebrating)
        }
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

    private var totalProgress: Double {
        guard let progress, progress.total > 0 else { return 0 }
        return Double(progress.done) / Double(progress.total)
    }

    private func trashSelection() {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }
        let deletable = nodes.filter { SafetyGuard.checkDeletable($0.url).allowed }
        let blocked = nodes.filter { !SafetyGuard.checkDeletable($0.url).allowed }
        guard !deletable.isEmpty else {
            PetBus.shared.say(L("Those paths are protected — nothing was deleted."), state: .sad)
            return
        }
        // Ring in the middle of the page: per-path delete of a big tree can
        // take seconds, and without it the window looked frozen.
        deleteProgress = BatchProgress(title: L("Deleting…"), done: 0, total: deletable.count)
        let startedAt = Date()
        Task {
            // Permanent delete (the user opted out of Trash): per-path so one
            // failure doesn't abort the rest.
            var removed: [FileNode] = []
            var failures: [(node: FileNode, error: String)] = []
            for (index, node) in deletable.enumerated() {
                deleteProgress?.detail = node.url.lastPathComponent
                do {
                    try await Task.detached { try FileManager.default.removeItem(at: node.url) }.value
                    removed.append(node)
                } catch {
                    failures.append((node, error.localizedDescription))
                }
                deleteProgress?.done = index + 1
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
final class FileNode: Identifiable {
    let id = UUID().uuidString
    let url: URL
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

    init(url: URL, bytes: Int64, isDirectory: Bool, fileCount: Int = 0) {
        self.url = url
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.fileCount = fileCount
    }

    /// Drop the node `id` from the tree and subtract its size from every
    /// ancestor, so the list rows, the breadcrumb total and the bubble map all
    /// reflect the deletion immediately — no full re-measure of the home
    /// folder (seconds of work, and it used to throw the user back to root).
    ///
    /// Also drops the on-disk size cache for the whole ancestor chain: a
    /// nested delete only bumps the DIRECT parent's mtime, so directories
    /// further up kept serving their pre-delete size until the 3-day TTL.
    @discardableResult
    static func applyDeletion(id: String, in list: inout [FileNode]) -> Bool {
        var ancestors: [FileNode] = []
        guard let node = detach(id: id, from: &list, ancestors: &ancestors) else { return false }
        SizeCache.shared.invalidate(node.url)
        for ancestor in ancestors {
            ancestor.bytes = max(0, ancestor.bytes - node.bytes)
            ancestor.fileCount = max(0, ancestor.fileCount - max(1, node.fileCount))
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
                Text(node.url.lastPathComponent.isEmpty ? node.url.path : node.url.lastPathComponent)
                    .font(Airi.footnoteFont.weight(.medium))
                    .foregroundStyle(Airi.neutral900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.fileCount > 0 {
                    Text(String(format: L("%lld items"), node.fileCount))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral500)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            Text(node.bytes.bytesFormatted)
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

    var body: some View {
        GeometryReader { geo in
            let bubbles = Self.pack(nodes)
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
                    Text(bubble.node.url.lastPathComponent)
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
                for _ in 0..<6000 {
                    let cx = dist * cos(angle), cy = dist * sin(angle)
                    let collides = placed.contains {
                        let dx = $0.x - cx, dy = $0.y - cy
                        return dx * dx + dy * dy < pow($0.r + r + 4, 2)
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
