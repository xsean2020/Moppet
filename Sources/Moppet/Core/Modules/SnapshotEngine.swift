import Foundation

/// APFS / Time Machine local snapshot manager.
///
/// Local snapshots are the classic "disk is full but no file explains it"
/// cause — macOS silently keeps hourly APFS snapshots (often 10–100 GB of
/// purgeable space) while Time Machine is on. `tmutil listlocalsnapshots /`
/// lists them; `tmutil deletelocalsnapshots <date>` deletes one. Deleting is
/// IRREVERSIBLE and can remove a local restore point, so the UI/tools must
/// always show the dry-run list first and delete only explicitly named dates.
enum SnapshotEngine {

    struct Snapshot: Identifiable, Equatable {
        /// The date string as tmutil prints it, e.g. `2026-10-27-123456` —
        /// the exact token `tmutil deletelocalsnapshots` expects back.
        let id: String
        let date: Date?
    }

    // MARK: - Parsing (pure, smoke-tested)

    /// Parses `tmutil listlocalsnapshots /` output:
    /// `Snapshot dates for /:\ncom.apple.TimeMachine.2026-10-27-123456.local`
    /// (older macOS also prints bare `2026-10-27-123456` lines.)
    static func parseListOutput(_ output: String) -> [Snapshot] {
        var seen = Set<String>()
        var result: [Snapshot] = []
        for line in output.split(separator: "\n") {
            let token = line.trimmingCharacters(in: .whitespaces)
            let candidate = extractSnapshotToken(token)
            guard let candidate, !candidate.isEmpty else { continue }
            guard seen.insert(candidate).inserted else { continue }
            result.append(Snapshot(id: candidate, date: Self.date(from: candidate)))
        }
        return result.sorted { $0.id > $1.id }   // newest first
    }

    /// Accepts the full mount name, the bare token, or nothing. The bare
    /// token must parse as a REAL date — `2026-13-99-999999` is 17 chars
    /// with the right dash positions but is not a snapshot, and it must
    /// never reach `tmutil deletelocalsnapshots`.
    static func extractSnapshotToken(_ line: String) -> String? {
        var candidate: String?
        if line.hasPrefix("com.apple.TimeMachine."), line.hasSuffix(".local") {
            candidate = String(line.dropFirst("com.apple.TimeMachine.".count)
                                  .dropLast(".local".count))
        } else if line.count == 17,
                  line[line.index(line.startIndex, offsetBy: 4)] == "-",
                  line[line.index(line.startIndex, offsetBy: 7)] == "-",
                  line[line.index(line.startIndex, offsetBy: 10)] == "-" {
            candidate = line
        }
        guard let candidate, date(from: candidate) != nil else { return nil }
        return candidate
    }

    /// `2026-10-27-123456` → Date (nil when malformed — display falls back
    /// to the raw token instead of crashing a formatter).
    static func date(from token: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: token)
    }

    // MARK: - Commands

    static func list() async -> [Snapshot] {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/bin/tmutil listlocalsnapshots /") else { return [] }
        return parseListOutput(output)
    }

    /// Deletes ONE snapshot by its exact date token (strict per HANDOFF
    /// §6.22 — no fuzzy date matching, no "delete everything" path).
    static func delete(_ snapshotID: String) async throws -> String {
        guard extractSnapshotToken(snapshotID) == snapshotID else {
            throw NSError(domain: "snapshots", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "not a snapshot date token: \(snapshotID)"])
        }
        return try await OptimizeEngine.shell(
            "/usr/bin/tmutil deletelocalsnapshots \(snapshotID)")
    }
}
