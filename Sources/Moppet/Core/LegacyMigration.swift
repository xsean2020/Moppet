import Foundation

/// One-time data relocation from the pre-rename "Cleaner" locations to the
/// "Moppet" ones. An unbundled SPM binary keys UserDefaults by its EXECUTABLE
/// name and the dot-dirs are named after the product, so the rename would
/// otherwise orphan the stored AI settings, keys, brain sessions, persona,
/// history and whitelist.
///
/// Every move is best-effort and skipped when the target already exists —
/// running repeatedly is a no-op, and a partially-migrated machine just
/// fills in the missing pieces. The legacy keychain service `cc.cleaner.ai`
/// is intentionally NOT touched: it is only ever a one-time migration SOURCE
/// inside APIKeyStore, and renaming it would orphan un-migrated items.
enum LegacyMigration {
    static func runIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // ~/.cleaner → ~/.moppet (ai-keys.json, ai-providers.json, brain/)
        move(home.appendingPathComponent(".cleaner", isDirectory: true),
             to: home.appendingPathComponent(".moppet", isDirectory: true))
        // ~/.config/cleaner → ~/.config/moppet (SafetyGuard whitelist)
        move(home.appendingPathComponent(".config/cleaner", isDirectory: true),
             to: home.appendingPathComponent(".config/moppet", isDirectory: true))
        // Application Support/Cleaner → Application Support/Moppet (history.json)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        move(support.appendingPathComponent("Cleaner", isDirectory: true),
             to: support.appendingPathComponent("Moppet", isDirectory: true))

        // UserDefaults: copy the old executable-name domain's keys once.
        // Guarded on the flagship key so a user who already reconfigured
        // under Moppet is never overwritten by stale Cleaner values.
        let fresh = UserDefaults.standard
        if fresh.object(forKey: AISettings.storageKey) == nil,
           let old = UserDefaults(suiteName: "Cleaner") {
            for (key, value) in old.dictionaryRepresentation() {
                guard !key.hasPrefix("NS") else { continue }
                // Per-key guard: the whole-domain copy used to overwrite
                // preferences the user had already set under Moppet (e.g.
                // changing the language before touching AI settings).
                if fresh.object(forKey: key) == nil {
                    fresh.set(value, forKey: key)
                }
            }
        }
    }

    /// Whole-dir rename when possible (preserves 0600 perms); when both ends
    /// exist, fill in only the missing children.
    private static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        if !fm.fileExists(atPath: to.path) {
            try? fm.moveItem(at: from, to: to)
            return
        }
        guard let children = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        for child in children {
            let dest = to.appendingPathComponent(child.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: child, to: dest)
            }
        }
    }
}
