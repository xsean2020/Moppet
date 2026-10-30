import Foundation

/// Project artifact purger — SwiftUI cousin of `mo purge`:
/// finds regenerable build artifacts (node_modules, target/, build/, …)
/// under developer roots, reports sizes, removes selected.
enum PurgeEngine {

    struct Artifact: Identifiable {
        let id = UUID()
        let url: URL
        let kind: String
        let bytes: Int64
        let projectPath: String
    }

    /// Directory names that are always regenerable build output.
    static let artifactNames: Set<String> = [
        "node_modules", "target", "build", "dist", ".next", ".nuxt", ".output",
        ".turbo", ".parcel-cache", ".gradle", ".dart_tool", "Pods", "DerivedData",
        ".terraform", "vendor",  // PHP/Go vendor dirs regenerate from lock files
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        "cmake-build-debug", "cmake-build-release",
    ]

    /// Default developer roots, checked for existence.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Projects", "Developer", "dev", "code", "work", "src", "repos"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The root list the Purge page last showed, persisted so the folders
    /// picked in the panel survive relaunch. `nil` means "never saved" —
    /// the page then seeds itself from `defaultRoots()`.
    enum RootsStore {
        private static let key = "purge.roots"
        static func load() -> [URL]? {
            guard let paths = UserDefaults.standard.stringArray(forKey: key) else { return nil }
            return paths.map { URL(fileURLWithPath: $0) }
        }
        static func save(_ roots: [URL]) {
            UserDefaults.standard.set(roots.map(\.path), forKey: key)
        }
    }

    /// Depth-limited parallel search for artifact directories.
    static func scan(roots: [URL], maxDepth: Int = 5,
                     progress: @escaping @Sendable (String) -> Void = { _ in }) async -> [Artifact] {
        let fm = FileManager.default
        // Collect candidate paths serially (cheap dir listing), then size in parallel.
        var candidates: [(URL, String)] = []

        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for entry in entries {
                let url = dir.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if artifactNames.contains(entry) {
                    candidates.append((url, entry))
                } else if !entry.hasPrefix(".") && depth < maxDepth {
                    walk(url, depth: depth + 1)
                }
            }
        }
        for root in roots { walk(root, depth: 1) }

        let sized = await withTaskGroup(of: Artifact?.self) { group in
            for (url, kind) in candidates {
                group.addTask {
                    let summary = ScanEngine.cachedSize(of: url)
                    guard summary.bytes > 0 else { return nil }
                    return Artifact(
                        url: url,
                        kind: kind,
                        bytes: summary.bytes,
                        projectPath: url.deletingLastPathComponent().path
                    )
                }
            }
            var out: [Artifact] = []
            for await artifact in group {
                if let artifact { out.append(artifact) }
            }
            return out
        }
        return sized.sorted { $0.bytes > $1.bytes }
    }

    /// Remove artifacts permanently (regenerable output).
    static func purge(_ artifacts: [Artifact]) -> [(Artifact, String?)] {
        var results: [(Artifact, String?)] = []
        for artifact in artifacts {
            guard SafetyGuard.checkDeletable(artifact.url).allowed else {
                results.append((artifact, "blocked by safety guard"))
                continue
            }
            do {
                try FileManager.default.removeItem(at: artifact.url)
                results.append((artifact, nil))
            } catch {
                results.append((artifact, error.localizedDescription))
            }
        }
        return results
    }
}

/// Large-file finder — the report-only `large files` section of `mo clean`,
/// now also the engine behind the Large Files page (P0 in the gap analysis).
enum LargeFilesEngine {

    struct LargeFile: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
    }

    /// Where the UI (and the tool) look. `wholeHome` relies on Spotlight —
    /// the `find` fallback over an entire home measured >600s, so when
    /// mdfind comes back empty we run the control query and TRUST an empty
    /// result instead of walking (same contract as deepScan). `custom` has
    /// no fixed roots: the Large Files page passes the user's folders in.
    enum Scope: CaseIterable {
        case userFolders      // Downloads / Documents / Desktop
        case wholeHome        // ~ via Spotlight
        case containers       // Containers / Caches / Application Support
        case custom           // user-picked folders

        var roots: [String] {
            switch self {
            case .userFolders: return ["~/Downloads", "~/Documents", "~/Desktop"]
            case .wholeHome: return ["~"]
            case .containers: return ["~/Library/Containers", "~/Library/Caches",
                                      "~/Library/Application Support"]
            case .custom: return []
            }
        }
    }

    /// User-added scan folders (Large Files → 自定义目录), persisted so the
    /// selection survives relaunches. Paths are absolute; the page's folder
    /// picker owns writes, the engine only receives them as arguments.
    enum CustomRoots {
        private static let key = "largeFiles.customRoots"
        static var paths: [String] {
            UserDefaults.standard.stringArray(forKey: key) ?? []
        }
        static func save(_ paths: [String]) {
            UserDefaults.standard.set(paths, forKey: key)
        }
    }

    /// Spotlight-backed search for files above `minBytes`; falls back to
    /// a bounded `find` pass when mdfind yields nothing (except for
    /// `wholeHome`, where the fallback is prohibitively slow).
    static func find(minBytes: Int64, limit: Int = 50,
                     in paths: [String] = ["~/Downloads", "~/Library/Mobile Documents",
                                           "~/Library/Containers", "~/Documents"]) async -> [LargeFile] {
        let expanded = paths.map {
            $0.hasPrefix("~") ? FileManager.default.homeDirectoryForCurrentUser.path + $0.dropFirst() : $0
        }
        let minMB = max(1, minBytes / 1_000_000)

        // EVERY configured root gets scanned — the old version silently
        // searched only the first (Downloads) while the tool description
        // promised Downloads/Documents/iCloud.
        var files: [LargeFile] = []
        for dir in expanded {
            let script = """
            mdfind -onlyin \(shellQuote(dir)) 'kMDItemFSSize > \(minBytes * 1_000_000)' 2>/dev/null | head -\(limit * 2)
            """
            files += parseAndStat(await runShell(script), minBytes: minBytes, limit: limit)
            if files.count >= limit { break }
        }
        if files.isEmpty {
            let findScript = expanded.map { dir in
                "find \(shellQuote(dir)) -type f -size +\(minMB)M -not -path '*/Library/Caches/*' 2>/dev/null | head -\(limit)"
            }.joined(separator: "; ")
            files = parseAndStat(await runShell(findScript), minBytes: minBytes, limit: limit)
        }
        return Array(files.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// Scope-aware search for the Large Files page. Whole-home scans trust
    /// Spotlight (control-query disambiguated) and never fall back to the
    /// slow walk. `progress` reports (steps done, steps total): one step per
    /// mdfind root, plus a final step for the find fallback when it runs.
    /// `customRoots` is only read for `.custom`; missing / non-directory
    /// paths are dropped so a stale saved folder can't hang the scan.
    static func find(minBytes: Int64, limit: Int = 200, scope: Scope,
                     customRoots: [String] = [],
                     progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [LargeFile] {
        let expanded = (scope == .custom ? customRoots : scope.roots)
            .map {
                $0.hasPrefix("~") ? FileManager.default.homeDirectoryForCurrentUser.path + $0.dropFirst() : $0
            }
            .filter { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    && isDir.boolValue
            }
        // Nothing to walk (first run, or every saved folder was deleted).
        guard !expanded.isEmpty else { return [] }
        var files: [LargeFile] = []
        let totalSteps = expanded.count + (scope == .wholeHome ? 0 : 1)
        for (index, dir) in expanded.enumerated() {
            let script = """
            mdfind -onlyin \(shellQuote(dir)) 'kMDItemFSSize > \(minBytes * 1_000_000)' 2>/dev/null | head -\(limit * 2)
            """
            files += parseAndStat(await runShell(script), minBytes: minBytes, limit: limit)
            progress?(index + 1, totalSteps)
        }
        if files.isEmpty && scope != .wholeHome {
            let minMB = max(1, minBytes / 1_000_000)
            let findScript = expanded.map { dir in
                "find \(shellQuote(dir)) -type f -size +\(minMB)M -not -path '*/Library/Caches/*' 2>/dev/null | head -\(limit)"
            }.joined(separator: "; ")
            files = parseAndStat(await runShell(findScript), minBytes: minBytes, limit: limit)
            progress?(totalSteps, totalSteps)
        }
        // Dedupe (nested scopes can report the same file twice) + sort.
        var seen = Set<String>()
        return files
            .filter { seen.insert($0.url.path).inserted }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Whether Spotlight indexing works in `dir` — a control query for
    /// plists (present on every Mac) disambiguates "no big files" from
    /// "indexing off".
    static func spotlightWorks(in dir: String) async -> Bool {
        let script = "mdfind -onlyin \(shellQuote(dir)) '(kMDItemFSName == \\\"*.plist\\\"c)' 2>/dev/null | head -1"
        let output = await runShell(script)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func parseAndStat(_ output: String, minBytes: Int64, limit: Int) -> [LargeFile] {
        output.split(separator: "\n").compactMap { line -> LargeFile? in
            let path = String(line).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber, size.int64Value >= minBytes else { return nil }
            return LargeFile(url: url, bytes: size.int64Value)
        }
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runShell(_ command: String) async -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "" }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in c.resume() }
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
