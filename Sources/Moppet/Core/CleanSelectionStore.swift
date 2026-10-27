import Foundation

/// Persisted "what to scan" selection — the user's checkboxes on the Clean
/// page, shared by every scan entry point.
///
/// Why this exists: `CleanViewModel` is created per view appearance, so its
/// selection died with the view — every re-entry (and every Quick Scan / AI
/// `scan_clean`) fell back to the rule library's `defaultSelected`, silently
/// scanning items the user had unchecked. The complaint "没选中的不要扫描"
/// was exactly that.
///
/// Only EXPLICIT user choices are stored (`itemID → selected`). Items the
/// user never touched keep following their rule default, so new rules in a
/// later build still start in a sensible state.
enum CleanSelectionStore {

    static let storageKey = "clean.item-selection"

    private static let lock = NSLock()

    // MARK: - Read
    //
    // No process-lifetime cache: the GUI app and a long-running MCP server
    // are separate processes sharing one plist — a cached map let the stale
    // side overwrite the live side's ticks on its next write. UserDefaults
    // already caches the plist; a fresh read per call is effectively free at
    // this size (26 keys).

    static func all() -> [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.dictionary(forKey: storageKey)?
            .compactMapValues { $0 as? Bool } ?? [:]
    }

    /// True when the user has ever toggled anything (so an empty selection
    /// means "scan nothing", not "never configured").
    static var hasCustomSelection: Bool {
        !all().isEmpty
    }

    static func isSelected(_ item: CleanItem) -> Bool {
        all()[item.id] ?? item.defaultSelected
    }

    /// The items to scan: every rule item whose effective state is selected.
    static func selectedItems() -> [CleanItem] {
        let map = all()
        return RuleLibrary.sections.flatMap(\.items).filter { item in
            map[item.id] ?? item.defaultSelected
        }
    }

    // MARK: - Write

    static func setSelected(id: String, _ selected: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // Read-modify-write against DISK, not a cache — merges with any
        // ticks another process made since our last write.
        var map = UserDefaults.standard.dictionary(forKey: storageKey)?
            .compactMapValues { $0 as? Bool } ?? [:]
        map[id] = selected
        UserDefaults.standard.set(map, forKey: storageKey)
    }

    /// Restore the rule-library defaults (Settings "reset" affordance).
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
