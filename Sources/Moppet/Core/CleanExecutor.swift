import Foundation
import AppKit

/// Executes deletions for a batch of findings and records history.
///
/// Mirrors mole's `mole_delete` semantics: trash-routed items go through
/// NSWorkspace (recoverable), permanent items through FileManager, and every
/// path is re-validated by SafetyGuard immediately before removal
/// (post-scan, pre-delete — the TOCTOU guard mole also performs).
enum CleanExecutor {

    static func clean(findings: [Finding],
                      progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in })
        async -> [CleanOutcome] {
        var outcomes: [CleanOutcome] = []
        let modeByItem = itemModes()

        // Group trash items so NSWorkspace can recycle them in one batch.
        let trashTargets = findings.filter { modeByItem[$0.itemID] == .trash }
        let permanentTargets = findings.filter { modeByItem[$0.itemID] != .trash }

        var done = 0
        let total = findings.count

        // 1) Permanent removals, one by one, re-validated just before removal.
        for finding in permanentTargets {
            let outcome = remove(finding: finding)
            outcomes.append(outcome)
            done += 1
            progress(done, total)
        }

        // 2) Trash removals in a single recycle batch (async recycle) —
        // re-validated first, like the permanent branch (the whitelist must
        // apply no matter which route deletes).
        if !trashTargets.isEmpty {
            let allowed = trashTargets.filter { SafetyGuard.checkDeletable($0.url).allowed }
            for blocked in trashTargets where !allowed.contains(where: { $0.url == blocked.url }) {
                outcomes.append(CleanOutcome(
                    path: blocked.url.path, bytes: blocked.bytes, itemID: blocked.itemID,
                    mode: .trash, success: false, error: "blocked by safety guard"))
                done += 1
                progress(done, total)
            }
            let urls = allowed.map(\.url)
            _ = try? await NSWorkspace.shared.recycle(urls)
            for finding in allowed {
                // If the original path no longer exists, recycling succeeded.
                let ok = !FileManager.default.fileExists(atPath: finding.url.path)
                outcomes.append(
                    CleanOutcome(
                        path: finding.url.path,
                        bytes: finding.bytes,
                        itemID: finding.itemID,
                        mode: .trash,
                        success: ok,
                        error: ok ? nil : "could not move to Trash"
                    )
                )
                done += 1
                progress(done, total)
            }
        }

        return outcomes
    }

    private static func remove(finding: Finding) -> CleanOutcome {
        let fm = FileManager.default
        // Final re-validation right before the destructive call.
        guard SafetyGuard.checkDeletable(finding.url).allowed else {
            return CleanOutcome(path: finding.url.path, bytes: finding.bytes,
                                itemID: finding.itemID, mode: .permanent,
                                success: false, error: "blocked by safety guard")
        }
        do {
            try fm.removeItem(at: finding.url)
            return CleanOutcome(path: finding.url.path, bytes: finding.bytes,
                                itemID: finding.itemID, mode: .permanent,
                                success: true, error: nil)
        } catch {
            return CleanOutcome(path: finding.url.path, bytes: finding.bytes,
                                itemID: finding.itemID, mode: .permanent,
                                success: false, error: error.localizedDescription)
        }
    }

    private static func itemModes() -> [String: DeletionMode] {
        var map: [String: DeletionMode] = [:]
        for section in RuleLibrary.sections {
            for item in section.items { map[item.id] = item.mode }
        }
        return map
    }
}

// MARK: - History store (JSON, mole operations.log analogue)

enum HistoryStore {

    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Moppet/history.json")
    }

    static func load() -> [CleanRecord] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([CleanRecord].self, from: data) {
            return decoded
        }
        // Undecodable history (schema drift from a newer build, corruption):
        // back it up instead of letting the next append overwrite the file —
        // the audit log is the only trace of what a clean removed.
        let backup = storageURL.deletingLastPathComponent()
            .appendingPathComponent("history-corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: storageURL, to: backup)
        return []
    }

    /// Lifetime totals for the dashboard: how much has Moppet cleaned, how
    /// often, and how it was split between permanent removal and the Trash.
    struct Totals {
        var runs: Int = 0
        /// Successful deletions only (failed outcomes never freed bytes).
        var permanentBytes: Int64 = 0
        var trashBytes: Int64 = 0
        var itemCount: Int = 0
        var lastRun: Date?
        /// Freed bytes per run, oldest → newest (dashboard sparkline).
        var recentRuns: [(date: Date, bytes: Int64)] = []

        var totalBytes: Int64 { permanentBytes + trashBytes }
    }

    /// Computed from the audit log — the History page and the dashboard show
    /// the same numbers because both come from here.
    static func totals(limitRecent: Int = 10) -> Totals {
        // Sort by date: the dashboard sparkline must read chronologically
        // regardless of the order records happen to sit in the file.
        let records = load().sorted { $0.date < $1.date }
        var totals = Totals()
        totals.runs = records.count
        for record in records {
            totals.lastRun = max(totals.lastRun ?? .distantPast, record.date)
            for item in record.items where item.success {
                totals.itemCount += 1
                switch item.mode {
                case .permanent: totals.permanentBytes += item.bytes
                case .trash: totals.trashBytes += item.bytes
                }
            }
        }
        // Older records (pre-item-detail schemas) may carry only freedBytes.
        if totals.totalBytes == 0 {
            totals.permanentBytes = records.reduce(0) { $0 + $1.freedBytes }
        }
        totals.recentRuns = records.suffix(limitRecent).map { ($0.date, $0.freedBytes) }
        return totals
    }

    /// load→append→save is read-modify-write; the UI and the agent's
    /// cleaning tools call it from different threads and used to drop each
    /// other's audit records.
    private static let lock = NSLock()

    static func append(_ record: CleanRecord) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        all.append(record)
        if all.count > 200 { all = Array(all.suffix(200)) }
        save(all)
    }

    static func save(_ records: [CleanRecord]) {
        let fm = FileManager.default
        let dir = storageURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}

// MARK: - Disk info

enum DiskInfo {
    struct Snapshot {
        let volumeName: String
        let totalBytes: Int64
        let freeBytes: Int64
        var usedBytes: Int64 { totalBytes - freeBytes }
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    static func snapshot() -> Snapshot {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey,
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            return Snapshot(
                volumeName: values.volumeName ?? "Macintosh HD",
                totalBytes: total,
                freeBytes: free
            )
        }
        return Snapshot(volumeName: "Macintosh HD", totalBytes: 0, freeBytes: 0)
    }
}
