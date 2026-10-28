import Foundation

/// Homebrew old-version cleaner.
///
/// Cellar keeps every formula version ever installed; `brew cleanup` removes
/// the superseded ones plus expired downloads. The contract is preview-first
/// (`brew cleanup -n` prints exactly what WOULD be removed) → execute on
/// explicit confirmation — the same dry-run gate every other destructive
/// surface in this app uses.
enum HomebrewEngine {

    struct Preview: Equatable {
        /// One line per would-be removal, e.g.
        /// `/opt/homebrew/Cellar/node/18.0.0 (1,234 files, 75.5MB)`.
        var lines: [String] = []
        var totalBytes: Int64 = 0

        var isEmpty: Bool { lines.isEmpty }
    }

    static var installed: Bool {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }

    private static func brewBin() -> String {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "brew"
    }

    // MARK: - Parsing (pure, smoke-tested)

    /// Parses `brew cleanup -n` output. Modern Homebrew (4+/7+) prints the
    /// path and size on ONE line:
    /// ```
    /// Would remove: /opt/homebrew/Cellar/pcre2/10.47_1 (244 files, 7.3MB)
    /// Would remove (empty directory): /opt/homebrew/share/.../.tmp
    /// ```
    /// Older builds printed a bare `Would remove:` header followed by
    /// path-only lines. Both shapes are accepted — the previous parser only
    /// understood the legacy one, so a modern brew returned an EMPTY preview
    /// and the card said "nothing to clean" even with 20+ removals pending.
    static func parseCleanupPreview(_ output: String) -> Preview {
        var preview = Preview()
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let path: String
            if let r = trimmed.range(of: "Would remove (empty directory): ") {
                path = String(trimmed[r.upperBound...])
            } else if let r = trimmed.range(of: "Would remove: ") {
                path = String(trimmed[r.upperBound...])
            } else if trimmed == "Would remove:" {
                continue            // legacy header; bare paths follow
            } else if trimmed.hasPrefix("/") {
                path = trimmed      // legacy bare-path line
            } else {
                continue
            }
            preview.lines.append(path)
            preview.totalBytes += parseHumanSize(in: path)
        }
        return preview
    }

    /// Extracts `(…files, 75.5MB)` style sizes; 0 when the line carries none.
    static func parseHumanSize(in line: String) -> Int64 {
        guard let open = line.lastIndex(of: "("),
              let close = line.lastIndex(of: ")"), open < close else { return 0 }
        let inner = line[line.index(after: open)..<close]
        for token in inner.split(separator: ",").reversed() {
            let part = token.trimmingCharacters(in: .whitespaces)
            let units: [(suffix: String, multiplier: Int64)] = [
                ("KB", 1_000), ("MB", 1_000_000), ("GB", 1_000_000_000),
                ("TB", 1_000_000_000_000), ("B", 1),
            ]
            for (suffix, multiplier) in units {
                if part.hasSuffix(suffix) {
                    let numberPart = part.dropLast(suffix.count)
                        .trimmingCharacters(in: .whitespaces)
                    guard let value = Double(numberPart.replacingOccurrences(of: ",", with: "")) else { break }
                    return Int64((value * Double(multiplier)).rounded())
                }
            }
        }
        return 0
    }

    /// Readable name for one preview line: "/opt/homebrew/Cellar/node/18.0.0
    /// (12 files, 75.5MB)" → "node/18.0.0" (formula + version, not just "18.0.0").
    static func displayName(for line: String) -> String {
        let pathPart = line.split(separator: " (").first.map(String.init) ?? line
        return pathPart.split(separator: "/").suffix(2).joined(separator: "/")
    }

    /// The footprint text of one preview line: "(12 files, 75.5MB)" →
    /// "12 files, 75.5MB" (empty when the line carries none).
    static func sizeText(for line: String) -> String {
        guard let open = line.lastIndex(of: "("),
              let close = line.lastIndex(of: ")"), open < close else { return "" }
        return String(line[line.index(after: open)..<close])
    }

    // MARK: - Commands

    static func preview() async -> Preview? {
        guard installed else { return nil }
        // `brew cleanup -n` exits non-zero with warnings on some taps —
        // tolerate the exit code and parse whatever came out. Long cap:
        // the dry run stats every Cellar file and is genuinely slow on
        // big installs.
        guard let output = try? await OptimizeEngine.shell(
            "\(shellQuote(brewBin())) cleanup -n 2>/dev/null || true", timeout: 300) else { return nil }
        return parseCleanupPreview(output)
    }

    static func run() async throws -> String {
        guard installed else {
            throw NSError(domain: "homebrew", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Homebrew is not installed"])
        }
        return try await OptimizeEngine.shell("\(shellQuote(brewBin())) cleanup", timeout: 900)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
