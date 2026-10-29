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

        // 1. Tier the selection.
        var direct: [URL] = []
        var expandable: [URL] = []
        for url in urls {
            if (fileCounts[url.path] ?? 0) > expandThreshold {
                expandable.append(url)
            } else {
                direct.append(url)
            }
        }

        // 2. Expand the big trees on a background task (metadata-only walk,
        //    but a million-entry tree must not stutter the main actor).
        var files: [URL] = []
        var dirs: [URL] = []
        if !expandable.isEmpty {
            let expanded = await Task.detached { Self.expand(urls: expandable) }.value
            files = expanded.files
            dirs = expanded.dirs
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
        //    leaves are already gone, so each is a cheap metadata op;
        //    removeItem still cleans up recursively when a leaf failed and
        //    left debris behind.
        let orderedDirs = dirs.sorted { $0.pathComponents.count > $1.pathComponents.count }
        if !orderedDirs.isEmpty {
            let (count, failures) = await Task.detached {
                var count = 0
                var failures: [(path: String, error: String)] = []
                let fm = FileManager.default
                for url in orderedDirs {
                    do {
                        try fm.removeItem(at: url)
                        count += 1
                    } catch {
                        failures.append((url.path, error.localizedDescription))
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
    private static func expand(urls: [URL]) -> (files: [URL], dirs: [URL]) {
        var files: [URL] = []
        var dirs: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default
        // resourceValues(forKeys:) wants a Set, contentsOfDirectory an array.
        let keySet: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        func classify(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
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
        return (files, dirs)
    }
}
