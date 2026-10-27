import Foundation

// MARK: - Rule model (mole-style sections → items)

/// How a matched path is removed.
enum DeletionMode: String, Codable {
    /// Move to Trash (recoverable).
    case trash
    /// Remove permanently (regenerable caches).
    case permanent
}

/// A single cleanable location. The path pattern supports `~` expansion and a
/// single trailing or embedded `*` segment (non-recursive glob).
struct CleanItem: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    /// Glob-ish path pattern, e.g. `~/Library/Caches/*`
    let pattern: String
    let mode: DeletionMode
    /// Extra caution note shown in review UI.
    var warning: String? = nil
    /// Selected by default during configure phase.
    var defaultSelected: Bool = true
    /// Directory-name prefixes excluded when expanding a `*` pattern
    /// (used by the generic user-cache rule to avoid double counting items
    /// owned by more specific rules).
    var excludedPrefixes: [String] = []
    /// When set, the item ignores `pattern` and DEEP-scans the whole home
    /// directory for files with these extensions (case-insensitive). The
    /// walk prunes SafetyGuard's protected categories, ~/.Trash and
    /// ~/.moppet, so protected data is never even enumerated.
    var deepExtensions: [String]? = nil
}

struct CleanSection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let items: [CleanItem]
}

// MARK: - Scan findings

struct Finding: Identifiable, Hashable {
    let id: String
    let url: URL
    let bytes: Int64
    let fileCount: Int
    let itemID: String

    var lastPathComponent: String { url.lastPathComponent }
}

struct ItemScanResult {
    let item: CleanItem
    let findings: [Finding]
    var totalBytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
}

// MARK: - History

struct CleanRecordItem: Codable, Hashable {
    let path: String
    let bytes: Int64
    let mode: DeletionMode
    let success: Bool
    let error: String?
}

/// Which surface produced a history record. The audit log used to carry only
/// section titles (e.g. "Browsers"), so the History page could not answer
/// "which menu did this come from?" — the one thing users ask of an audit
/// trail. Optional in the model so older files still decode.
enum RecordSource: String, Codable, CaseIterable {
    case clean          // Clean page (scan → review → clean)
    case quickScan      // menu bar / pet menu / ⌘S quick sweep
    case aiAgent        // the AI agent's cleaning tools (scan_clean → execute_clean)
    case uninstall      // single-app uninstall
    case uninstallBatch // multi-app uninstall
    case analyze        // Analyze → Trash selection
    case purge          // project artifact purge
    case slim           // binary slimming
    case startup        // startup item enable/disable
    case optimize       // maintenance tasks
    case largeFiles     // Large Files page → Trash
    case orphans        // orphan residue cleanup
    case hogs           // system hogs (snapshots / Docker / Homebrew)
    case scheduled      // the LaunchAgent's --scheduled-clean run

    var icon: String {
        switch self {
        case .clean: "sparkles"
        case .quickScan: "bolt"
        case .aiAgent: "brain"
        case .uninstall, .uninstallBatch: "app.badge.minus"
        case .analyze: "magnifyingglass"
        case .purge: "flame"
        case .slim: "scissors"
        case .startup: "power"
        case .optimize: "wrench.and.screwdriver"
        case .largeFiles: "doc.magnifyingglass"
        case .orphans: "tray.full"
        case .hogs: "internaldrive"
        case .scheduled: "clock.badge.checkmark"
        }
    }

    /// Localized menu name shown as the record's badge.
    var title: String {
        switch self {
        case .clean: L("Clean")
        case .quickScan: L("Quick Scan")
        case .aiAgent: L("AI Agent")
        case .uninstall, .uninstallBatch: L("Uninstall")
        case .analyze: L("Analyze")
        case .purge: L("Purge")
        case .slim: L("Slim")
        case .startup: L("Startup")
        case .optimize: L("Optimize")
        case .largeFiles: L("Large Files")
        case .orphans: L("Orphans")
        case .hogs: L("Space Hogs")
        case .scheduled: L("Scheduled")
        }
    }
}

struct CleanRecord: Codable, Identifiable {
    var id: UUID = UUID()
    let date: Date
    let sectionTitles: [String]
    let requestedBytes: Int64
    let freedBytes: Int64
    let itemCount: Int
    let items: [CleanRecordItem]
    /// Which menu produced this run (nil for records written before the field
    /// existed — the UI falls back to inferring it from sectionTitles).
    var source: RecordSource? = nil

    // Forward-compatible decode: a default value on a non-optional field is
    // NOT optional at decode time — any missing key used to fail the WHOLE
    // history file (which then got overwritten with just the new record).
    init(date: Date, sectionTitles: [String], requestedBytes: Int64, freedBytes: Int64,
         itemCount: Int, items: [CleanRecordItem], source: RecordSource? = nil) {
        self.date = date
        self.sectionTitles = sectionTitles
        self.requestedBytes = requestedBytes
        self.freedBytes = freedBytes
        self.itemCount = itemCount
        self.items = items
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        sectionTitles = try c.decodeIfPresent([String].self, forKey: .sectionTitles) ?? []
        requestedBytes = try c.decodeIfPresent(Int64.self, forKey: .requestedBytes) ?? 0
        freedBytes = try c.decodeIfPresent(Int64.self, forKey: .freedBytes) ?? 0
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount) ?? 0
        items = try c.decodeIfPresent([CleanRecordItem].self, forKey: .items) ?? []
        source = try c.decodeIfPresent(RecordSource.self, forKey: .source)
    }
}

// MARK: - Clean outcome for UI

struct CleanOutcome: Identifiable {
    let id = UUID()
    let path: String
    let bytes: Int64
    let itemID: String
    let mode: DeletionMode
    let success: Bool
    let error: String?
}
