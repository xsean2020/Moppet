import Foundation

/// Tiered recursive deletion for the Analyze page's user-confirmed batch.
///
/// The user's rule of thumb is right: a selected directory should be ONE
/// `removeItem` call — the kernel's single-pass recursion is the fastest
/// way to delete a small tree, and any walker overhead is pure loss.
/// Parallelism only pays off when a tree is huge, because plain recursion
/// is one thread of unlink syscalls while APFS unlink scales across cores.
///
/// So this tiers by estimated size:
/// - Seed ≤ `expandThreshold` entries → one direct recursive `removeItem`.
/// - Bigger trees → expand once, unlink the leaves over a bounded worker
///   pool (2–4× faster on APFS), then rmdir the emptied dirs deepest-first.
///
/// Direct seeds themselves run chunked across the same worker pool, and
/// every phase ticks progress at chunk granularity — never per file.
enum BatchDeleter {

    struct Outcome {
        var deletedCount = 0
        /// One entry per failed seed/leaf/dir, path-keyed so the caller can
        /// match a failure back to the node that owns it (by exact path or
        /// path prefix).
        var failures: [(path: String, error: String)] = []
        /// Paths kept because the user's whitelist protects them — found
        /// under a selected seed during expansion, or as a seed itself.
        var skippedWhitelist: [String] = []
    }

    /// Main-actor-isolated tick. A closure value with actor isolation is
    /// implicitly Sendable, so the nonisolated engine can hop to it with
    /// `await`.
    typealias Progress = @MainActor (_ done: Int, _ total: Int, _ detail: String) -> Void

    /// Unlink is kernel-bound; past a handful of workers the contention
    /// outweighs the parallelism win.
    private static let workerCount = 6
    /// Seeds (or leaf files) per chunk — one task hop and one progress
    /// tick per chunk, never per item.
    private static let chunkSize = 256
    /// Seeds at or below this estimated entry count go through a single
    /// recursive `removeItem` — one call, kernel-recursed. Only bigger
    /// trees pay for the expansion walk in exchange for parallel unlink.
    private static let expandThreshold = 1024

    /// Deletes the given URLs permanently. `fileCounts` maps a URL's path
    /// to its recursive entry count (the Analyze tree already measured
    /// this) and drives the direct-vs-expand tiering; missing hints count
    /// as small. One failing item never aborts the rest.
    static func remove(urls: [URL],
                       fileCounts: [String: Int] = [:],
                       progress: Progress? = nil) async -> Outcome {
        var outcome = Outcome()
        var done = 0

        // Whitelist defense-in-depth. The caller gates every seed with
        // checkDeletable, but that check only looks at the seed itself and
        // its ANCESTORS — a whitelisted DESCENDANT (~/Library/Caches/Steam
        // under a selected ~/Library/Caches) would sail through and die in
        // the recursive remove. Two layers here: whitelisted seeds are
        // dropped outright, and any seed whose subtree could contain a
        // whitelist hit is demoted to the expand tier, where every path is
        // checked individually.
        let patterns = SafetyGuard.loadWhitelistPatterns()
        let seeds = urls.filter { url in
            if SafetyGuard.isWhitelisted(url) {
                outcome.skippedWhitelist.append(url.path)
                return false
            }
            return true
        }
        var direct: [URL] = []
        var expandable: [URL] = []
        for url in seeds {
            // Structural whitelist check in the canonical form — seed URLs
            // can carry a different /var-class form than the patterns.
            let mayContain = !patterns.isEmpty && subtreeMayContainWhitelisted(
                canonical(url.path), patterns: patterns)
            if (fileCounts[url.path] ?? 0) > expandThreshold || mayContain {
                expandable.append(url)
            } else {
                direct.append(url)
            }
        }

        // 2. Expand the big trees on a background task (metadata-only walk,
        //    but a million-entry tree must not stutter the main actor).
        var files: [URL] = []
        var dirs: [URL] = []
        var skipped: [String] = []
        if !expandable.isEmpty {
            let expanded = await Task.detached {
                Self.expand(urls: expandable, patterns: patterns)
            }.value
            files = expanded.files
            dirs = expanded.dirs
            skipped = expanded.skipped
            outcome.skippedWhitelist.append(contentsOf: expanded.skipped)
        }

        let total = direct.count + files.count + dirs.count
        await progress?(0, total, "")

        // 3. Run chunked work (direct recursive deletes, then parallel leaf
        //    unlinks) with at most `workerCount` chunks in flight, consuming
        //    results as slots free up so the ring streams forward.
        let work: [(urls: [URL], detail: String)] =
            direct.map { ([$0], $0.lastPathComponent) }
            + stride(from: 0, to: files.count, by: chunkSize).map {
                (Array(files[$0 ..< Swift.min($0 + chunkSize, files.count)]),
                 files[Swift.min($0 + chunkSize, files.count) - 1].lastPathComponent)
            }
        await withTaskGroup(of: (Int, String, [(path: String, error: String)]).self) { group in
            var iterator = work.makeIterator()
            var inFlight = 0
            func absorb(_ result: (Int, String, [(path: String, error: String)])) async {
                done += result.0
                outcome.deletedCount += result.0
                outcome.failures.append(contentsOf: result.2)
                await progress?(done, total, result.1)
            }
            while let unit = iterator.next() {
                group.addTask {
                    var count = 0
                    var failures: [(path: String, error: String)] = []
                    let fm = FileManager.default
                    for url in unit.urls {
                        do {
                            try fm.removeItem(at: url)
                            count += 1
                        } catch {
                            failures.append((url.path, error.localizedDescription))
                        }
                    }
                    return (count, unit.detail, failures)
                }
                inFlight += 1
                if inFlight == workerCount, let result = await group.next() {
                    await absorb(result)
                    inFlight -= 1
                }
            }
            for await result in group { await absorb(result) }
        }

        // 4. Rmdir the expanded trees' directories deepest-first. Their
        //    leaves are already gone, so each is a cheap metadata op.
        //    removeItem's recursive cleanup is still used to sweep debris
        //    from failed leaves — EXCEPT where whitelisted content lives:
        //    a recursive remove there would take the protected subtree with
        //    it, so those dirs get a plain `rmdir` that only ever succeeds
        //    on an empty directory. The protected content (and every dir
        //    holding it) stays and is reported as "kept whitelisted content".
        let orderedDirs = dirs.sorted { $0.pathComponents.count > $1.pathComponents.count }
        if !orderedDirs.isEmpty {
            let skippedSet = Set(skipped)
            let (count, failures) = await Task.detached { [skippedSet] in
                var count = 0
                var failures: [(path: String, error: String)] = []
                let fm = FileManager.default
                for url in orderedDirs {
                    // Both sides canonicalized (see canonical(_:)).
                    let dirKey = canonical(url.path)
                    let kept = skippedSet.first { $0.hasPrefix(dirKey + "/") }
                    let holdsProtected = kept != nil
                    do {
                        if holdsProtected {
                            guard rmdir(url.path) == 0 else {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                        } else {
                            try fm.removeItem(at: url)
                        }
                        count += 1
                    } catch {
                        // A dir holding whitelisted content can never empty —
                        // name the reason instead of a bare "not empty".
                        failures.append((url.path, kept != nil
                            ? String(format: L("kept whitelisted content: %@"), kept!)
                            : error.localizedDescription))
                    }
                }
                return (count, failures)
            }.value
            done += count
            outcome.deletedCount += count
            outcome.failures.append(contentsOf: failures)
            await progress?(done, total, orderedDirs.last?.lastPathComponent ?? "")
        }

        return outcome
    }

    // MARK: - Expansion

    /// Walks every seed URL and splits the subtree into leaf files (to
    /// unlink in parallel) and directories (to rmdir afterwards). Symlinks
    /// count as leaves no matter what they point at, and the descent is
    /// manual (`contentsOfDirectory` per level) so a symlinked directory is
    /// never entered — a link to ~/Documents inside the selection must not
    /// turn into a delete of Documents' real contents.
    ///
    /// Every path is also matched against the whitelist: a hit is recorded
    /// in `skipped` and never deleted — and because a skipped directory is
    /// never entered either, a whitelisted folder protects its whole
    /// subtree, same semantics as checkDeletable's ancestor rule.
    private static func expand(urls: [URL], patterns: [String])
        -> (files: [URL], dirs: [URL], skipped: [String]) {
        var files: [URL] = []
        var dirs: [URL] = []
        var skipped: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default
        // resourceValues(forKeys:) wants a Set, contentsOfDirectory an array.
        let keySet: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        // Empty whitelist: skip the per-path resolution entirely.
        let whitelistActive = !patterns.isEmpty

        func classify(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            if whitelistActive, SafetyGuard.isWhitelisted(url) {
                // Canonical form at record time: enumerated children can
                // carry a different /var-class form than the seed URLs the
                // rmdir phase will compare against.
                skipped.append(canonical(url.path))
                return
            }
            let values = try? url.resourceValues(forKeys: keySet)
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = values?.isDirectory ?? false
            if isSymlink || !isDirectory {
                files.append(url)
                return
            }
            dirs.append(url)
            if let children = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: []) {
                for child in children { classify(child) }
            }
        }

        for url in urls { classify(url) }
        return (files, dirs, skipped)
    }

    /// The path form SafetyGuard's whitelist matching operates in —
    /// `resolvingSymlinksInPath`, same as isWhitelisted/checkDeletable.
    /// EVERY prefix comparison in here canonicalizes both sides with THIS,
    /// not realpath: /var-class paths have two live forms (/var and
    /// /private/var) and the two canonicalizers DISAGREE on which one is
    /// canonical — mixing them silently voids the whitelist protection.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Conservative structural test: could any whitelist pattern match a
    /// path AT OR BELOW the seed? `glob` wildcards are single-segment, so a
    /// pattern only reaches into the seed's subtree when its wildcard-free
    /// prefix is the seed itself, lies under it, or is an ancestor of it
    /// (`~/Library/*/Steam` reaches under `~/Library/Caches`; `~/Downloads`
    /// cannot reach under `~/Library/Caches`). Seeds the pattern matches
    /// directly never get here — the caller's checkDeletable denies them.
    private static func subtreeMayContainWhitelisted(
        _ seedPath: String, patterns: [String]) -> Bool {
        let home = NSHomeDirectory()
        for pattern in patterns {
            let expanded = pattern.hasPrefix("~") ? home + pattern.dropFirst() : pattern
            let segments = expanded.split(separator: "/", omittingEmptySubsequences: false)
            var end = segments.count
            if let idx = segments.firstIndex(where: { $0.contains("*") || $0.contains("?") }) {
                end = idx
            }
            let prefix = segments[..<end].joined(separator: "/")
            if prefix == seedPath
                || prefix.hasPrefix(seedPath + "/")
                || seedPath.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }
}
