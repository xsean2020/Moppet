import Foundation

/// Scan engine — parallel glob expansion + directory sizing, mirroring
/// mole's approach (parallel workers, safety filtering applied to every
/// candidate before it enters the preview list).
enum ScanEngine {

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
            let summary = size(of: url)
            SizeCache.shared.store(url, summary: summary)
            return summary
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys) else {
            let summary = size(of: url)
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

        // Cap the fan-out; surplus subdirs sized serially inside one task.
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
                    let candidates = expand(pattern: item.pattern, excludedPrefixes: item.excludedPrefixes)
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

    /// Sizes direct children of a directory in parallel, returning the top N.
    /// `progress` fires on a background executor as (completed, total) —
    /// the AnalyzeView progress bar; hop to main before touching @State.
    static func topChildren(of directory: URL, limit: Int = 24,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [SpaceEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
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
        let sized: [SpaceEntry] = await withTaskGroup(of: SpaceEntry?.self) { group in
            for entry in entries {
                group.addTask {
                    // Cooperative cancel: skip any entry not yet started.
                    if Task.isCancelled { return nil }
                    // Cache-aware parallel sizing: warm runs are instant.
                    let summary = await parallelSize(of: entry)
                    progress?(counter.bump(), total)
                    guard summary.bytes > 0 else { return nil }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: entry.path, isDirectory: &isDir)
                    return SpaceEntry(id: entry.path, url: entry, bytes: summary.bytes,
                                      isDirectory: isDir.boolValue, fileCount: summary.files)
                }
            }
            var out: [SpaceEntry] = []
            for await e in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let e { out.append(e) }
            }
            return out
        }
        return Array(sized.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }
}
