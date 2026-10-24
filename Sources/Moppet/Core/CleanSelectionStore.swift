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
    private static var cache: [String: Bool]?

    // MARK: - Read

    static func all() -> [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return loadedLocked()
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
        var map = loadedLocked()
        map[id] = selected
        cache = map
        UserDefaults.standard.set(map, forKey: storageKey)
    }

    /// Restore the rule-library defaults (Settings "reset" affordance).
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func loadedLocked() -> [String: Bool] {
        if let cache { return cache }
        let stored = UserDefaults.standard.dictionary(forKey: storageKey)?
            .compactMapValues { $0 as? Bool } ?? [:]
        cache = stored
        return stored
    }
}
