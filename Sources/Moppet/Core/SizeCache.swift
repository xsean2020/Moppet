import Foundation

/// Result cache for heavy scans (directory sizing) — mole's 7-day TTL
/// directory-size cache, adapted. Entries invalidate on directory mtime
/// change or TTL expiry; stored as JSON under ~/.moppet/brain/.
final class SizeCache {

    struct Entry: Codable {
        var bytes: Int64
        var files: Int
        var dirMTime: Double
        var cachedAt: Date
    }

    static let shared = SizeCache()

    private var store: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval = 3 * 24 * 3600
    private var lastPersist = Date.distantPast
    /// LRU cap — without one the store grew without bound. 5000, not 500:
    /// ONE Analyze pass over ~/Library at depth 2 stores hundreds of subtree
    /// entries; a 500 cap evicted the earlier ones DURING the scan, so the
    /// next visit was cold everywhere ("nothing changed but it re-measured").
    /// Entries are ~100B of JSON — 5000 ≈ 500KB on disk.
    static let maxEntries = 5000

    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("size-cache.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL) {
            // Must match persist()'s .iso8601 — the default decoder strategy
            // made every reload fail silently, so the disk cache never worked.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([String: Entry].self, from: data) {
                store = decoded
            } else {
                // Undecodable cache (schema change, corruption): drop the file
                // rather than re-writing over it forever.
                try? FileManager.default.removeItem(at: Self.fileURL)
                store = [:]
            }
        }
    }

    private func persist() {
        evictIfNeeded()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(store) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Caller must hold `lock`.
    private func evictIfNeeded() {
        guard store.count > Self.maxEntries else { return }
        // Evict in BATCHES down to 90% of the cap. Trimming to exactly the
        // cap meant the very next insert pushed the store over again, so a
        // cold scan re-sorted all 5000 entries on every persist tick.
        // Sorted-prefix is O(n log n) on an already-small dictionary — the
        // win here is doing it 10× less often, not a fancier data structure.
        let target = Self.maxEntries - Self.maxEntries / 10
        let surplus = store.count - target
        guard surplus > 0 else { return }
        let oldest = store.sorted { $0.value.cachedAt < $1.value.cachedAt }.prefix(surplus)
        for (key, _) in oldest {
            store.removeValue(forKey: key)
        }
    }

    private func directoryMTime(_ url: URL) -> Double {
        // URL.resourceValues(.contentModificationDateKey) does NOT update for
        // directories when children are created/deleted (verified on macOS 26:
        // identical value across create+delete — the old guard compared a
        // constant, so cached sizes stuck until TTL no matter what changed).
        // FileManager.attributesOfItem(.modificationDate) is the real signal.
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
    }

    /// Canonical cache key: symlink/firmlink-resolved path. `contentsOfDirectory`
    /// returns URLs under the RESOLVED path (/var → /private/var on macOS),
    /// while a caller-built URL keeps the unresolved form — keys must match
    /// or every enumerated child misses its own just-stored summary.
    /// Uses real `realpath` (ScanEngine.realFileSystemPath), NOT
    /// resolvingSymlinksInPath: that API leaves /var-class paths unresolved
    /// (the very mismatch this key exists to prevent), so a caller URL
    /// /tmp/x and an enumerated child /private/tmp/x produced two entries
    /// for one directory and remove()/invalidate() could miss the real key.
    private static func cacheKey(_ url: URL) -> String {
        ScanEngine.realFileSystemPath(url.path)
    }

    func lookup(_ url: URL) -> ScanEngine.SizeSummary? {
        lock.lock(); defer { lock.unlock() }
        let key = Self.cacheKey(url)
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.cachedAt) < ttl else {
            store.removeValue(forKey: key)
            return nil
        }
        guard entry.dirMTime == directoryMTime(url) else { return nil }
        return ScanEngine.SizeSummary(bytes: entry.bytes, files: entry.files)
    }

    func store(_ url: URL, summary: ScanEngine.SizeSummary) {
        lock.lock(); defer { lock.unlock() }
        store[Self.cacheKey(url)] = Entry(
            bytes: summary.bytes, files: summary.files,
            dirMTime: directoryMTime(url), cachedAt: Date())
        // Throttle disk writes during big cold scans.
        if Date().timeIntervalSince(lastPersist) > 2 {
            lastPersist = Date()
            persist()
        }
    }

    /// Drop ONE entry — no ancestor walk. Analyze deletions refresh their
    /// ancestors' summaries from the in-memory tree instead of dropping them
    /// (see `FileNode.applyDeletion`); only the deleted path itself and the
    /// home root (not derivable from the tree) need a plain removal.
    func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: Self.cacheKey(url))
        persist()
    }

    /// Immediate flush of the throttled disk writes — call at the end of a
    /// bulk measuring pass so a quit right afterwards doesn't lose the
    /// just-measured subtree summaries (store() only persists every 2s).
    func persistNow() {
        lock.lock(); defer { lock.unlock() }
        persist()
    }

    /// Drop the cached summary for `url` AND every ancestor up to the home
    /// folder.
    ///
    /// Deleting a file bumps the mtime of its own parent directory only —
    /// directories further up keep their old mtime (verified: same value
    /// before and after a nested delete). Their cached `bytes` therefore
    /// looked "still valid" and the Analyze view kept showing the pre-delete
    /// size for every parent until the 3-day TTL. Callers that mutate a tree
    /// must drop the whole chain.
    func invalidate(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        // Same canonicalization as the STORE side (realpath): with the old
        // resolvingSymlinksInPath here, /var-class paths removed keys that
        // were never stored and left the real ones alive.
        var current = URL(fileURLWithPath: ScanEngine.realFileSystemPath(url.path))
        let home = URL(fileURLWithPath: ScanEngine.realFileSystemPath(
            FileManager.default.homeDirectoryForCurrentUser.path))
        while true {
            store.removeValue(forKey: current.path)
            if current.path == home.path || current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        persist()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }
}
