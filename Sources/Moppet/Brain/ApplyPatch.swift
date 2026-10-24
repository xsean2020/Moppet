import Foundation

/// Complete parser & applier for Codex's custom patch format
/// (codex-rs/apply-patch). Format:
///
/// ```
/// *** Begin Patch
/// *** Add File: path/to/new.txt
/// +line
/// +line
/// *** Update File: path/to/existing.txt
/// @@ optional context hint
/// context line (unchanged)
///-removed line
///+added line
/// *** Delete File: path/to/old.txt
/// *** Move to: new/path.txt          (renames the previous file, keeping hunks)
/// *** End Patch
/// ```
enum ApplyPatch {

    enum PatchError: LocalizedError, Equatable {
        case malformed(String)
        case notFound(String)
        case contextMismatch(path: String, line: Int, expected: String, actual: String)
        case alreadyExists(String)
        case outsideWorkspace(String)
        case protected(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let m): return "malformed patch: \(m)"
            case .notFound(let p): return "file not found: \(p)"
            case .contextMismatch(let p, let line, let expected, let actual):
                return "context mismatch in \(p) at line \(line):\n  expected: \(expected)\n  actual:   \(actual)"
            case .alreadyExists(let p): return "file already exists: \(p)"
            case .outsideWorkspace(let p): return "path escapes workspace: \(p)"
            case .protected(let p): return "path is protected by the user whitelist: \(p)"
            }
        }
    }

    enum FileChange {
        case add(path: String, content: String)
        case update(path: String, hunks: [Hunk])
        case delete(path: String)
        case move(from: String, to: String, hunks: [Hunk])   // hunks ride along with the rename
    }

    struct Hunk {
        var contextHint: String?
        var lines: [PatchLine]
    }

    enum PatchLine: Equatable {
        case context(String)
        case remove(String)
        case add(String)
    }

    // MARK: - Parsing

    static func parse(_ patch: String) throws -> [FileChange] {
        var lines = patch
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        guard let begin = lines.firstIndex(of: "*** Begin Patch") else {
            throw PatchError.malformed("missing '*** Begin Patch'")
        }
        guard let endIdx = lines.lastIndex(of: "*** End Patch") else {
            throw PatchError.malformed("missing '*** End Patch'")
        }
        lines = Array(lines[(begin + 1)..<endIdx])

        var changes: [FileChange] = []
        var index = 0

        func parseCurrentChange() throws -> FileChange? {
            guard index < lines.count else { return nil }
            let line = lines[index]

            if line.hasPrefix("*** Add File: ") {
                let path = String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var content: [String] = []
                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let l = lines[index]
                    if l.hasPrefix("+") {
                        content.append(String(l.dropFirst()))
                    } else if l.isEmpty {
                        content.append("")
                    } else {
                        throw PatchError.malformed("Add File body line must start with '+': \(l)")
                    }
                    index += 1
                }
                return .add(path: path, content: content.joined(separator: "\n"))
            }

            if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var hunks: [Hunk] = []
                var current: Hunk? = nil
                while index < lines.count, !lines[index].hasPrefix("*** ") {
                    let l = lines[index]
                    if l.hasPrefix("@@") {
                        if let h = current { hunks.append(h) }
                        current = Hunk(contextHint: String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces), lines: [])
                        index += 1
                    } else if l == "@@" {
                        if let h = current { hunks.append(h) }
                        current = Hunk(contextHint: nil, lines: [])
                        index += 1
                    } else if l.hasPrefix("+") {
                        current?.lines.append(.add(String(l.dropFirst())))
                        index += 1
                    } else if l.hasPrefix("-") {
                        current?.lines.append(.remove(String(l.dropFirst())))
                        index += 1
                    } else if l.hasPrefix(" ") || l.isEmpty {
                        current?.lines.append(.context(l.isEmpty ? "" : String(l.dropFirst())))
                        index += 1
                    } else {
                        throw PatchError.malformed("unexpected line in Update File: \(l)")
                    }
                }
                if let h = current { hunks.append(h) }
                guard !hunks.isEmpty else {
                    throw PatchError.malformed("Update File without hunks: \(path)")
                }
                return .update(path: path, hunks: hunks)
            }

            if line.hasPrefix("*** Delete File: ") {
                let path = String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                return .delete(path: path)
            }

            throw PatchError.malformed("unexpected directive: \(line)")
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("*** Move to: ") {
                // Renames the most recent change's target; content hunks ride
                // along (rename + edit is one atomic operation, like codex).
                let to = String(line.dropFirst("*** Move to: ".count)).trimmingCharacters(in: .whitespaces)
                index += 1
                guard case .update(let from, let hunks) = changes.last else {
                    throw PatchError.malformed("'*** Move to:' must follow an Update File block")
                }
                changes[changes.count - 1] = .move(from: from, to: to, hunks: hunks)
                continue
            }
            guard let change = try parseCurrentChange() else { break }
            changes.append(change)
        }
        return changes
    }

    /// Paths a patch would delete or move away — feeds the deletion approval
    /// gate in BrainTools without applying anything.
    static func deletionTargets(in patch: String) -> [String] {
        guard let changes = try? parse(patch) else { return [] }
        return changes.flatMap { change -> [String] in
            switch change {
            case .delete(let p): return [p]
            case .move(let from, _, _): return [from]
            default: return []
            }
        }
    }

    // MARK: - Applying

    struct Result {
        var added: [String] = []
        var updated: [String] = []
        var deleted: [String] = []
        var moved: [(String, String)] = []

        var summary: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.count)") }
            if !updated.isEmpty { parts.append("updated \(updated.count)") }
            if !deleted.isEmpty { parts.append("deleted \(deleted.count)") }
            if !moved.isEmpty { parts.append("moved \(moved.count)") }
            return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
        }
    }

    @discardableResult
    static func apply(_ patch: String, workspaceRoot: URL) throws -> Result {
        let changes = try parse(patch)
        let fm = FileManager.default

        func resolve(_ path: String) throws -> URL {
            // Resolve symlinks on BOTH sides: standardizedFileURL alone does
            // not follow links, so a link inside the workspace could point
            // the write outside it.
            let root = workspaceRoot.resolvingSymlinksInPath().path
            let url = URL(fileURLWithPath: path, relativeTo: workspaceRoot)
                .standardizedFileURL.resolvingSymlinksInPath()
            // The workspace root itself is never a valid target —
            // "Delete File: ." must not rm -rf the whole tree.
            guard url.path.hasPrefix(root + "/") else {
                throw PatchError.outsideWorkspace(path)
            }
            return url
        }

        // Phase 1 — validate everything and compute outcomes in memory.
        // Nothing touches disk until the whole patch parses AND matches:
        // a multi-file patch that dies at file 3 of 5 used to leave the
        // first two files mutated with no rollback.
        enum WriteRecord { case added(String), updated(String), movedDestination(String) }
        enum RemoveRecord { case deleted(String), movedSource(from: String, to: String) }
        enum Planned {
            case write(url: URL, content: String, record: WriteRecord)
            case remove(url: URL, record: RemoveRecord)
            case rename(fromPath: String, fromURL: URL, toURL: URL)
        }
        var planned: [Planned] = []

        for change in changes {
            switch change {
            case .add(let path, let content):
                let url = try resolve(path)
                guard !fm.fileExists(atPath: url.path) else {
                    throw PatchError.alreadyExists(path)
                }
                planned.append(.write(url: url, content: content, record: .added(path)))

            case .update(let path, let hunks):
                let url = try resolve(path)
                guard fm.fileExists(atPath: url.path) else {
                    throw PatchError.notFound(path)
                }
                let original = try String(contentsOf: url, encoding: .utf8)
                planned.append(.write(url: url,
                                      content: try applyHunks(hunks, to: original, path: path),
                                      record: .updated(path)))

            case .delete(let path):
                let url = try resolve(path)
                guard fm.fileExists(atPath: url.path) else {
                    throw PatchError.notFound(path)
                }
                guard !SafetyGuard.isWhitelisted(url) else {
                    throw PatchError.protected(path)
                }
                planned.append(.remove(url: url, record: .deleted(path)))

            case .move(let from, let to, let hunks):
                let fromURL = try resolve(from)
                let toURL = try resolve(to)
                guard fm.fileExists(atPath: fromURL.path) else {
                    throw PatchError.notFound(from)
                }
                guard !SafetyGuard.isWhitelisted(fromURL) else {
                    throw PatchError.protected(from)
                }
                if hunks.isEmpty, fromURL.path != toURL.path {
                    guard !fm.fileExists(atPath: toURL.path) else {
                        throw PatchError.alreadyExists(to)
                    }
                    planned.append(.rename(fromPath: from, fromURL: fromURL, toURL: toURL))
                } else {
                    // Rename with edits (or a no-op rename): content lands at
                    // the destination, source removed afterwards.
                    if fromURL.path != toURL.path {
                        guard !fm.fileExists(atPath: toURL.path) else {
                            throw PatchError.alreadyExists(to)
                        }
                    }
                    let original = try String(contentsOf: fromURL, encoding: .utf8)
                    planned.append(.write(url: toURL,
                                          content: try applyHunks(hunks, to: original, path: from),
                                          record: .movedDestination(to)))
                    if fromURL.path != toURL.path {
                        planned.append(.remove(url: fromURL, record: .movedSource(from: from, to: to)))
                    }
                }
            }
        }

        // Phase 2 — commit (validation already passed; only IO can fail here).
        var result = Result()
        for step in planned {
            switch step {
            case .write(let url, let content, let record):
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
                if case .added(let path) = record { result.added.append(path) }
                if case .updated(let path) = record { result.updated.append(path) }
                if case .movedDestination = record { /* paired below */ }

            case .remove(let url, let record):
                try fm.removeItem(at: url)
                switch record {
                case .deleted(let path): result.deleted.append(path)
                case .movedSource(let from, let to): result.moved.append((from, to))
                }

            case .rename(let fromPath, let fromURL, let toURL):
                try fm.createDirectory(at: toURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: fromURL, to: toURL)
                result.moved.append((fromPath, toURL.lastPathComponent))
            }
        }
        return result
    }

    // MARK: - Hunks

    /// Applies parsed hunks against file content. Hunks are applied bottom-up
    /// so earlier line indices stay valid; each hunk must match at or above
    /// the previous (lower) hunk's position — the search window tightens so
    /// duplicate text deeper in the file can't swallow two hunks.
    static func applyHunks(_ hunks: [Hunk], to original: String, path: String) throws -> String {
        var lines = original.components(separatedBy: "\n")
        let crlf = original.contains("\r\n")
        var searchCeiling = lines.count
        for hunk in hunks.reversed() {
            // A hunk with no context/remove lines has no anchor — it would
            // silently insert at line 0 no matter what the @@ hint says.
            let anchored = hunk.lines.contains { if case .add = $0 { return false }; return true }
            if !anchored && !lines.isEmpty {
                throw PatchError.malformed(
                    "hunk in \(path) has only '+' lines — include a context or '-' line to locate the insertion")
            }
            let start = try findHunkStart(hunk, in: lines, upperBound: searchCeiling, path: path)
            try replace(hunk, at: start, in: &lines, path: path, crlf: crlf)
            searchCeiling = start
        }
        return lines.joined(separator: "\n")
    }

    private static func findHunkStart(_ hunk: Hunk, in lines: [String],
                                      upperBound: Int, path: String) throws -> Int {
        let bound = min(upperBound, lines.count)
        for start in 0...max(0, bound) {
            var ok = true
            var li = start
            for pl in hunk.lines {
                switch pl {
                case .context(let text):
                    if li >= lines.count || normalize(lines[li]) != normalize(text) { ok = false }
                case .remove(let text):
                    if li >= lines.count || normalize(lines[li]) != normalize(text) { ok = false }
                case .add:
                    continue
                }
                if !ok { break }
                li += 1
            }
            if ok { return start }
        }
        // No exact window inside the search region: fall back to the first
        // line match of the first non-add line, still bounded by the region.
        if case .context(let text)? = hunk.lines.first(where: { if case .add = $0 { return false }; return true }) {
            let bounded = lines[0..<max(0, min(bound + 1, lines.count))]
            if let idx = bounded.firstIndex(where: { normalize($0) == normalize(text) }) {
                return idx
            }
        }
        throw PatchError.contextMismatch(path: path, line: 0,
                                         expected: hunk.lines.compactMap {
                                             if case .context(let t) = $0 { return t }
                                             if case .remove(let t) = $0 { return t }
                                             return nil
                                         }.first ?? "",
                                         actual: lines.first ?? "")
    }

    private static func replace(_ hunk: Hunk, at start: Int, in lines: inout [String],
                                path: String, crlf: Bool) throws {
        // Unified cursor model: insertAt always points at the line currently
        // being examined (context/remove consume it, add inserts above it).
        var insertAt = start

        for pl in hunk.lines {
            switch pl {
            case .context(let text):
                guard insertAt < lines.count, normalize(lines[insertAt]) == normalize(text) else {
                    throw PatchError.contextMismatch(
                        path: path, line: insertAt + 1, expected: text,
                        actual: insertAt < lines.count ? lines[insertAt] : "<EOF>")
                }
                insertAt += 1
            case .remove(let text):
                guard insertAt < lines.count, normalize(lines[insertAt]) == normalize(text) else {
                    throw PatchError.contextMismatch(
                        path: path, line: insertAt + 1, expected: text,
                        actual: insertAt < lines.count ? lines[insertAt] : "<EOF>")
                }
                lines.remove(at: insertAt)
            case .add(let text):
                // Preserve the file's line-ending style for inserted lines.
                let line = crlf && !text.hasSuffix("\r") ? text + "\r" : text
                lines.insert(line, at: insertAt)
                insertAt += 1
            }
        }
    }

    /// Codex tolerates trailing-whitespace drift between patch context and
    /// file; leading indentation is significant and must match exactly.
    private static func normalize(_ line: String) -> String {
        if let lastNonWS = line.lastIndex(where: { !$0.isWhitespace }) {
            return String(line[...lastNonWS])
        }
        return ""
    }
}
