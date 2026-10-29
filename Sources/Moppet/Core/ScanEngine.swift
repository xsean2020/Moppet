import Foundation

/// Scan engine — parallel glob expansion + directory sizing, mirroring
/// mole's approach (parallel workers, safety filtering applied to every
/// candidate before it enters the preview list).
enum ScanEngine {

    /// Bounds how many directory walks run at once across the WHOLE engine.
    ///
    /// `parallelSize` fans out 8 children per level and recurses two levels
    /// deep, while `topChildren` keeps 8 of those chains in flight — so a
    /// 500-entry layer could put hundreds of `enumerator` walks on the disk
    /// simultaneously. Past a few dozen concurrent walks the volume stops
    /// going faster and starts thrashing: memory pressure rises, the CPU
    /// burns in kernel stat paths, and the OS filesystem lock contention
    /// shows up as erratic progress. 32 keeps the queue saturated without
    /// the pile-up.
    private actor IOThrottle {
        static let shared = IOThrottle(limit: 32)

        private let limit: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func acquire() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Hands the permit straight to the next waiter when there is one
        /// (no decrement/increment round trip, so `active` can never drift).
        func release() {
            if waiters.isEmpty {
                active = max(0, active - 1)
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    /// The synchronous leaf walk, behind the global throttle.
    private static func throttledSize(of url: URL) async -> SizeSummary {
        await IOThrottle.shared.acquire()
        let summary = size(of: url)
        await IOThrottle.shared.release()
        return summary
    }

    /// C realpath(3) — resolves firmlinks (/var→/private/var) that
    /// URL.resolvingSymlinksInPath leaves untouched on this machine.
    static func realFileSystemPath(_ path: String) -> String {
        path.withCString { cPath -> String in
            guard let resolved = realpath(cPath, nil) else { return path }
            let result = String(cString: resolved)
            free(resolved)
            return result
        }
    }


    // MARK: - Path pattern expansion

    /// Expands `~` and a single `*` wildcard segment (non-recursive).
    /// Returns only entries that exist on disk. Excluded prefixes apply to
    /// the entry name directly after the wildcard.
    static func expand(pattern: String, excludedPrefixes: [String] = []) -> [URL] {
        let fm = FileManager.default
        let expanded = pattern.hasPrefix("~")
            ? SafetyGuard.home.path + pattern.dropFirst()
            : pattern

        guard expanded.contains("*") else {
            let url = URL(fileURLWithPath: expanded)
            return fm.fileExists(atPath: expanded) ? [url] : []
        }

        let components = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let starIndex = components.firstIndex(where: { $0.contains("*") }),
              starIndex == components.lastIndex(where: { $0.contains("*") })
        else { return [] }  // only one wildcard segment supported

        let base = "/" + components[0..<starIndex].joined(separator: "/")
        guard fm.fileExists(atPath: base) else { return [] }

        let suffix = components[(starIndex + 1)...].joined(separator: "/")
        let starSegment = components[starIndex]

        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return [] }
        var results: [URL] = []
        for entry in entries {
            if starSegment == "*" {
                // wildcard matches everything in the directory
            } else if starSegment.hasPrefix("*."), let ext = starSegment.split(separator: ".").last {
                guard entry.lowercased().hasSuffix("." + ext.lowercased()) else { continue }
            } else if !globSegment(starSegment, matches: entry) {
                continue
            }
            if excludedPrefixes.contains(where: { entry.hasPrefix($0) }) { continue }
            let full = base + "/" + entry + (suffix.isEmpty ? "" : "/" + suffix)
            if fm.fileExists(atPath: full) {
                results.append(URL(fileURLWithPath: full))
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    /// Recursive extension search under `root` for the deep-clean items.
    /// Prunes (never descends into) SafetyGuard's protected categories,
    /// ~/.Trash and ~/.moppet, so protected data is not even enumerated and
    /// the walk skips the heaviest irrelevant trees. Errors are skipped, not
    /// fatal — a permission-denied subtree just yields nothing.
    static func deepScan(root: URL, extensions: [String],
                         prunePrefixes: [String]? = nil,
                         onVisitedDirectory: ((String) -> Void)? = nil) -> [URL] {
        // Realpath FIRST — resolvingSymlinksInPath leaves /var unresolved on
        // this machine while the enumerator yields /private/var paths, so
        // prefix pruning never matched (verified in smoke).
        let resolvedRoot = realFileSystemPath(root.path)
        let lowerExtensions = Set(extensions.map { $0.lowercased() })
        var pruneList = prunePrefixes ?? []
        if pruneList.isEmpty {
            let home = SafetyGuard.home.path
            for sub in SafetyGuard.protectedHomeSubpaths {
                pruneList.append(home + "/" + sub)
            }
            pruneList.append(home + "/.Trash")
            pruneList.append(home + "/.moppet")
        }
        let prunes = pruneList.map { realFileSystemPath($0) }
        func pruned(_ path: String) -> Bool {
            prunes.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // Stage 1 — Spotlight: a whole-home extension search in ~1s. Covers
        // everything indexed; misses folders excluded from Spotlight.
        // ONE query for every extension: the old per-extension loop spawned
        // one `mdfind` process (and one index walk) per extension — three
        // process launches for a dmg/pkg/iso rule, each paying its own
        // ~150ms startup before the search even began.
        let query = extensions
            .map { "(kMDItemFSName == '*.\($0)'c)" }
            .joined(separator: " || ")
        let mdfindOutput = runShell("/usr/bin/mdfind", ["-onlyin", resolvedRoot, query])
        let mdfindResults: [URL] = mdfindOutput.split(separator: "\n").compactMap { line -> URL? in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !pruned(path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        if Task.isCancelled {
            return []
        }
        if mdfindResults.isEmpty {
            // Empty is ambiguous: "no installers anywhere" vs "Spotlight
            // off". A control query that MUST match when indexing works
            // (plists exist on every Mac) disambiguates — without it, every
            // clean home paid the 45s fallback walk (measured).
            let control = runShell("/usr/bin/mdfind",
                                   ["-onlyin", resolvedRoot, "(kMDItemFSName == '*.plist'c)"])
            if !control.split(separator: "\n").isEmpty {
                return []   // Spotlight works and found nothing — trust it
            }
        } else {
            return Array(Set(mdfindResults)).sorted { $0.path < $1.path }
        }

        // Stage 2 — fallback walk (Spotlight off / nothing indexed). The
        // naive walk measured >600s over a real home. ~/Library holds no
        // user installers in practice (and its protected subpaths are
        // pruned anyway) — skipping it entirely brings the walk to ~1s;
        // Spotlight-enabled machines still get Library coverage via stage 1.
        // The 45s deadline stays as a belt: partial-but-timely beats
        // complete-but-never.
        let deadline = Date().addingTimeInterval(45)
        var extraPrunes = prunes
        let home = SafetyGuard.home.path
        extraPrunes.append(realFileSystemPath(home + "/Library"))
        // Regenerable directory NAMES are pruned by name (not path): dev
        // repos at the home top level hold hundreds of thousands of files in
        // .git/node_modules — none ever a user installer. Same list as the
        // Purge engine plus VCS internals.
        let prunedNames: Set<String> = [
            ".git", ".svn", ".hg", "node_modules", ".gradle", "Pods",
            "DerivedData", "__pycache__", ".venv", "venv", ".next", ".nuxt",
            ".output", ".turbo", ".parcel-cache", ".dart_tool", ".terraform",
            "vendor", "target", "build", "dist", "cmake-build-debug",
            "cmake-build-release", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ]
        // Toolchains / package-manager roots at the home top level: measured
        // 20s (go), 4.5s (miniconda3) with zero installers in them.
        let toolchainRoots: Set<String> = [
            "go", "miniconda3", "anaconda3", "miniforge3", "toolchains",
            "rustup", "rbenv", "nvm", "pyenv", "sdkman",
        ]
        let maxDepth = 6   // installers live shallow; depth caps runaway trees
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: resolvedRoot),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: { _, _ in true })   // keep walking past errors
        while let next = enumerator?.nextObject() as? URL {
            if Task.isCancelled || Date() > deadline || results.count >= 1000 { break }
            let path = next.path
            if extraPrunes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                enumerator?.skipDescendants()
                continue
            }
            // Name-based pruning + depth cap for regenerable trees.
            let name = next.lastPathComponent
            if prunedNames.contains(name) || (enumerator?.level ?? 0) > maxDepth {
                enumerator?.skipDescendants()
                continue
            }
            let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            // Hidden directories are tool state (~/.hermes 7.5s, ~/.npm 4.9s,
            // ~/.cache 3.5s, ~/.pub-cache 3.7s — measured). A user installer
            // never lives in one; Spotlight still covers them when enabled.
            if isDirectory, name.hasPrefix(".") {
                enumerator?.skipDescendants()
                continue
            }
            // Top-level toolchain roots (go = 19.8s, miniconda3 = 4.5s).
            if isDirectory, (enumerator?.level ?? 0) <= 1, toolchainRoots.contains(name) {
                enumerator?.skipDescendants()
                continue
            }
            if isDirectory, (enumerator?.level ?? 0) <= 2 {
                onVisitedDirectory?(name)
            }
            guard values?.isRegularFile == true else { continue }
            guard lowerExtensions.contains(next.pathExtension.lowercased()) else { continue }
            results.append(next)
        }
        return results.sorted { $0.path < $1.path }
    }

    /// Runs a command, returns stdout (empty on failure — deep scan
    /// degrades to the fallback walk instead of failing the item).
    ///
    /// The wait is a semaphore signalled from `terminationHandler`, not a
    /// `Thread.sleep` poll: the old loop woke every 20ms for up to 20s
    /// (1000 wakeups per query) and held a thread spinning on a process
    /// that was doing all the actual work.
    private static func runShell(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return "" }

        // Drain concurrently: a full 64KB pipe buffer would block the child
        // forever if we waited for exit before reading (mdfind over a home
        // easily exceeds it).
        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            var data: Data {
                lock.lock(); defer { lock.unlock() }
                return storage
            }
            func set(_ value: Data) {
                lock.lock(); storage = value; lock.unlock()
            }
        }
        let box = OutputBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }

        if exited.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                // A child that ignores SIGTERM would otherwise keep the read
                // blocked forever; closing our read end forces it to return.
                try? pipe.fileHandleForReading.close()
            }
        }
        drained.wait()
        return String(data: box.data, encoding: .utf8) ?? ""
    }

    private static func globSegment(_ segment: String, matches name: String) -> Bool {
        SafetyGuard.glob(segment, matches: name)
    }

    // MARK: - Sizing

    struct SizeSummary: Equatable {
        var bytes: Int64 = 0
        var files: Int = 0
    }

    /// Recursively sizes a file or directory using allocated size
    /// (closer to real disk usage than logical size).
    static func size(of url: URL) -> SizeSummary {
        var summary = SizeSummary()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey,
        ]

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return summary }
        guard isDir.boolValue else {
            let values = try? url.resourceValues(forKeys: keys)
            summary.bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            summary.files = 1
            return summary
        }

        guard let deep = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return summary
        }
        for case let child as URL in deep {
            guard let values = try? child.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true { continue }
            summary.bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            summary.files += 1
        }
        return summary
    }

    /// mtime-guarded cached sizing for sync call sites (clean findings,
    /// uninstall leftovers, purge artifacts): a path whose directory mtime
    /// is unchanged serves the cached summary; any change re-measures just
    /// that path. Same contract as parallelSize's cache, without needing an
    /// async context.
    static func cachedSize(of url: URL) -> SizeSummary {
        if let cached = SizeCache.shared.lookup(url) {
            return cached
        }
        let summary = size(of: url)
        guard summary.bytes > 0 || summary.files > 0 else { return summary }
        SizeCache.shared.store(url, summary: summary)
        return summary
    }

    /// Parallel recursive sizing — enumerates first-level children, then
    /// descends each subdirectory concurrently (depth-limited so huge trees
    /// don't explode the task count). Results are memoized in SizeCache.
    static func parallelSize(of url: URL, depth: Int = 2) async -> SizeSummary {
        if let cached = SizeCache.shared.lookup(url) {
            return cached
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, depth > 0 else {
            let summary = await throttledSize(of: url)
            SizeCache.shared.store(url, summary: summary)
            return summary
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys) else {
            let summary = await throttledSize(of: url)
            SizeCache.shared.store(url, summary: summary)
            return summary
        }

        var direct = SizeSummary()
        var subdirs: [URL] = []
        for child in entries {
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                subdirs.append(child)
            } else {
                direct.bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                direct.files += 1
            }
        }

        // Batch the children so a 500-entry layer does not create 500 child
        // tasks; the real concurrency ceiling is `IOThrottle` at the leaf
        // walk, which is what the disk actually feels.
        let fanOut = 8
        let grouped = stride(from: 0, to: max(subdirs.count, 1), by: fanOut).map {
            Array(subdirs[$0..<min($0 + fanOut, subdirs.count)])
        }
        let childDepth = depth - 1
        let totals: [SizeSummary] = await withTaskGroup(of: SizeSummary.self) { group in
            for batch in grouped {
                group.addTask {
                    var batchSum = SizeSummary()
                    for dir in batch {
                        let sub = await parallelSize(of: dir, depth: childDepth)
                        batchSum.bytes += sub.bytes
                        batchSum.files += sub.files
                    }
                    return batchSum
                }
            }
            var out: [SizeSummary] = []
            for await sum in group { out.append(sum) }
            return out
        }

        var summary = direct
        for sum in totals {
            summary.bytes += sum.bytes
            summary.files += sum.files
        }
        SizeCache.shared.store(url, summary: summary)
        return summary
    }

    // MARK: - Rule scanning (dry-run equivalent)

    /// Expands every item pattern, filters candidates through the safety
    /// layer, sizes them in parallel, and returns one result per item.
    static func scan(items: [CleanItem],
                     progress: @escaping @Sendable (String) -> Void = { _ in })
        async -> [ItemScanResult] {
        let selected = items
        let results = await withTaskGroup(of: (String, [Finding]).self) { group in
            for item in selected {
                group.addTask {
                    // Deep items walk the whole home for their extensions;
                    // classic items use single-wildcard pattern expansion.
                    let candidates: [URL]
                    if let extensions = item.deepExtensions {
                        // 10–15s over a real home: report the folder being
                        // walked so the UI is not a frozen ring.
                        candidates = deepScan(root: SafetyGuard.home,
                                              extensions: extensions) { name in
                            progress("Scanning \(name)…")
                        }
                    } else {
                        candidates = expand(pattern: item.pattern,
                                            excludedPrefixes: item.excludedPrefixes)
                    }
                    var findings: [Finding] = []
                    var idx = 0
                    for url in candidates {
                        // Cooperative cancel (CleanView's Cancel button): the
                        // task group propagates the parent task's cancellation,
                        // but each child must check it between candidates or a
                        // huge directory walk keeps burning CPU after cancel.
                        if Task.isCancelled { break }
                        // Safety filtering happens BEFORE sizing so protected
                        // paths never even show up in the preview.
                        guard SafetyGuard.checkDeletable(url).allowed else { continue }
                        let summary = cachedSize(of: url)
                        guard summary.bytes > 0 || summary.files > 0 else { continue }
                        findings.append(
                            Finding(
                                id: "\(item.id)#\(idx)#\(url.lastPathComponent)",
                                url: url,
                                bytes: summary.bytes,
                                fileCount: summary.files,
                                itemID: item.id
                            )
                        )
                        idx += 1
                    }
                    let scanned = findings
                    let label = item.name
                    // Progress only while the scan still owns the slot: after
                    // Cancel the stragglers used to bump the NEXT scan's
                    // counters (progress could read >100%).
                    if !Task.isCancelled {
                        progress("Scanned \(label) — \(scanned.count) paths")
                    }
                    return (item.id, findings)
                }
            }
            var map: [String: [Finding]] = [:]
            for await (id, findings) in group {
                map[id] = findings
            }
            var ordered: [ItemScanResult] = []
            for item in selected {
                if let findings = map[item.id] {
                    ordered.append(ItemScanResult(item: item, findings: findings))
                }
            }
            return ordered
        }
        return results
    }

    // MARK: - Disk usage (for Analyze view)

    struct SpaceEntry: Identifiable {
        let id: String
        let url: URL
        let bytes: Int64
        var isDirectory = true
        /// Files/entries inside (from the sizing pass) — shown in the
        /// Analyze list like the reference design ("34 items").
        var fileCount: Int = 0
    }

    /// Instant snapshot from SizeCache for the Analyze stale-while-revalidate
    /// path: every entry with a still-valid cached summary is served without
    /// touching the disk walk. `missed` counts entries whose cache entry was
    /// absent/expired — callers decide whether a partial snapshot is useful
    /// (top layer: show it and refresh behind; sub-layers: require 0 misses).
    static func cachedTopChildren(of directory: URL, limit: Int = 24) -> (entries: [SpaceEntry], missed: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([], 0)
        }
        var out: [SpaceEntry] = []
        var missed = 0
        for entry in entries {
            guard let cached = SizeCache.shared.lookup(entry), cached.bytes > 0 || cached.files > 0 else {
                missed += 1
                continue
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            out.append(SpaceEntry(id: entry.path, url: entry, bytes: cached.bytes,
                                  isDirectory: isDir.boolValue, fileCount: cached.files))
        }
        return (Array(out.sorted { $0.bytes > $1.bytes }.prefix(limit)), missed)
    }

    /// `ls`-grade listing — ONE `contentsOfDirectory` call, stat-grade
    /// attributes only. Files get their allocated size for free; directories
    /// come back with bytes=0 because a real size needs a recursive walk
    /// (directories with a still-valid SizeCache entry land with their real
    /// size in the same pass). This is what makes entering a huge directory
    /// instant: the layer is navigable after ~one readdir, and real sizes
    /// stream in afterwards via `topChildren`.
    static func listChildren(of directory: URL, limit: Int = 500) -> [SpaceEntry] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else {
            return []
        }
        var out: [SpaceEntry] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            if isDir, let cached = SizeCache.shared.lookup(entry) {
                // Warm entry: real size in the first frame, no "Measuring…".
                out.append(SpaceEntry(id: entry.path, url: entry, bytes: cached.bytes,
                                      isDirectory: true, fileCount: cached.files))
            } else {
                let bytes: Int64 = isDir ? 0
                    : Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                out.append(SpaceEntry(id: entry.path, url: entry, bytes: bytes,
                                      isDirectory: isDir, fileCount: isDir ? 0 : 1))
            }
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Sizes direct children of a directory in parallel, returning the top N.
    /// `progress` fires on a background executor as (completed, total) —
    /// the AnalyzeView progress bar; hop to main before touching @State.
    /// `onEntry` streams each sized child THE MOMENT it lands (also on a
    /// background executor) so a caller can fill sizes in live instead of
    /// waiting for the whole layer — entering a big directory no longer
    /// blocks on a full recursive walk of every child.
    ///
    /// Concurrency is WINDOWED (see `maxInFlight`): every result comes from
    /// `parallelSize`, whose own 8-way fan-out multiplies whatever window we
    /// open here — unbounded, a 500-entry layer spawned 500 sizing chains at
    /// once and the I/O thrash made cold walks slower, not faster. Cache
    /// hits inside `parallelSize` make warm runs near-free either way.
    static func topChildren(of directory: URL, limit: Int = 24,
                            progress: (@Sendable (Int, Int) -> Void)? = nil,
                            onEntry: (@Sendable (SpaceEntry) -> Void)? = nil) async -> [SpaceEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        // Thread-safe completion counter (the sizing tasks run concurrently).
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let total = entries.count
        // 8 concurrent child sizings: saturates the parallelSize fan-out
        // (8×8 = 64 leaves in flight) without piling hundreds of directory
        // walks on top of each other.
        let maxInFlight = 8
        let sizeEntry = { @Sendable (entry: URL) async -> SpaceEntry? in
            // Cooperative cancel: skip any entry not yet started.
            if Task.isCancelled { return nil }
            // Created inside the closure: FileManager is thread-safe but not
            // Sendable, so capturing the outer instance trips the compiler.
            let fm = FileManager.default
            // Cache-aware sizing: warm entries are a single mtime stat.
            let summary = await parallelSize(of: entry)
            progress?(counter.bump(), total)
            guard summary.bytes > 0 else { return nil }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            let sized = SpaceEntry(id: entry.path, url: entry, bytes: summary.bytes,
                                   isDirectory: isDir.boolValue, fileCount: summary.files)
            onEntry?(sized)
            return sized
        }
        // Sliding window: whenever one sizing finishes, seed the next entry.
        var next = entries.makeIterator()
        let sized: [SpaceEntry] = await withTaskGroup(of: SpaceEntry?.self) { group in
            for _ in 0..<maxInFlight {
                guard let entry = next.next() else { break }
                group.addTask { await sizeEntry(entry) }
            }
            var out: [SpaceEntry] = []
            for await e in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let e { out.append(e) }
                if let entry = next.next() {
                    group.addTask { await sizeEntry(entry) }
                }
            }
            return out
        }
        // Flush the throttled cache writes so a quit right after a cold
        // walk doesn't drop the just-measured subtree summaries.
        SizeCache.shared.persistNow()
        return Array(sized.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
