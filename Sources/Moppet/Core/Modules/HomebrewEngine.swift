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

    /// Parses `brew cleanup -n` output. Layout:
    /// ```
    /// Would remove:
    /// /opt/homebrew/Cellar/foo/1.0 (12 files, 3.5MB)
    /// /opt/homebrew/Cellar/bar/2.0 (1,004 files, 120MB)
    /// ```
    /// Sizes are human units — parsed with a multiplier table rather than
    /// re-measuring the paths (the preview lists paths brew WILL delete;
    /// measuring them again races the cleanup).
    static func parseCleanupPreview(_ output: String) -> Preview {
        var preview = Preview()
        var inRemoveBlock = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Would remove:" {
                inRemoveBlock = true
                continue
            }
            guard inRemoveBlock, trimmed.hasPrefix("/") else {
                if !trimmed.isEmpty { inRemoveBlock = false }
                continue
            }
            preview.lines.append(trimmed)
            preview.totalBytes += parseHumanSize(in: trimmed)
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

    // MARK: - Commands

    static func preview() async -> Preview? {
        guard installed else { return nil }
        // `brew cleanup -n` exits non-zero with warnings on some taps —
        // tolerate the exit code and parse whatever came out.
        guard let output = try? await OptimizeEngine.shell(
            "\(shellQuote(brewBin())) cleanup -n 2>/dev/null || true") else { return nil }
        return parseCleanupPreview(output)
    }

    static func run() async throws -> String {
        guard installed else {
            throw NSError(domain: "homebrew", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Homebrew is not installed"])
        }
        return try await OptimizeEngine.shell("\(shellQuote(brewBin())) cleanup")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
