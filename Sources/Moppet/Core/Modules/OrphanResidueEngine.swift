import Foundation

/// Orphan residue scanner — leftovers of apps that are no longer installed.
///
/// The uninstaller only ever sees INSTALLED apps; an app that was dragged to
/// the Trash by hand (or whose uninstaller missed folders) leaves data behind
/// forever. This engine walks the bundle-id-shaped directories under
/// `~/Library`, extracts each candidate's bundle id, and diffs it against the
/// bundle ids of every installed app.
///
/// Conservative by design — this is a DELETE surface:
/// - `com.apple.*` and a fixed list of updater/helper ids (Keystone,
///   AutoUpdate…) that belong to installed-but-not-.app software are excluded.
/// - A candidate whose first two DNS segments match ANY installed app
///   (`com.google.Keystone` vs `com.google.Chrome`) is kept — the vendor
///   prefix is shared helper/updater space, not orphaned data.
/// - Directories touched within `staleDays` (default 30) are skipped: active
///   software writes there; orphans sit still.
/// - Every final deletion goes through SafetyGuard + the same bundle-scoped
///   preference exemption the uninstaller uses.
enum OrphanResidueEngine {

    struct Candidate: Identifiable, Equatable {
        let id: String
        let url: URL
        let bundleID: String
        let kind: String          // caches / app support / preferences / container / logs…
        let bytes: Int64
        let lastModified: Date?
    }

    /// Library roots holding bundle-id-named entries, with display kinds.
    /// LaunchAgents plists are included per the gap-analysis appendix: a
    /// dead app's registration file is residue like any other (trashing it
    /// unregisters the agent; launchd reads it at login only).
    static var scanRoots: [(subpath: String, kind: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Library/Caches", "caches"),
            ("Library/Application Support", "app support"),
            ("Library/Containers", "container"),
            ("Library/Logs", "logs"),
            ("Library/HTTPStorages", "http storage"),
            ("Library/WebKit", "webkit data"),
            ("Library/Saved Application State", "saved state"),
            ("Library/Preferences", "preferences"),
            ("Library/LaunchAgents", "launch agent"),
        ].map { (home.appendingPathComponent($0.0).path, $0.1) }
    }

    /// Bundle-id-shaped dirs that belong to Apple or to software that is not
    /// an .app bundle (updaters, helpers, daemons) — never reported orphaned.
    static let builtinProtectedIDs: Set<String> = [
        "com.apple",
        "com.google.Keystone", "com.google.Keystone.Agent",
        "com.microsoft.autoupdate2", "com.microsoft.update",
        "com.adobe.AAM.Updater", "com.adobe.acc.Installer",
        "com.adobe.ARMDCHelper", "com.adobe.acc.ACCDesktop",
    ]

    // MARK: - Classification (pure, smoke-tested)

    /// `com.example.app` from `~/Library/Caches/com.example.app`,
    /// `com.example.app.plist` (Preferences), `com.example.app.<host>.plist`
    /// (ByHost) or `com.example.app.savedState` suffixes; nil for anything
    /// that is not reverse-DNS shaped.
    ///
    /// Bare directories (no .plist/.savedState suffix) need THREE or more
    /// segments — a two-segment "readme.txt" style name in a Library root is
    /// noise, while real app-data dirs are `com./org./io.`-prefixed and
    /// almost always deeper. Suffix-stripped names only need two.
    static func bundleID(fromEntryName name: String) -> String? {
        var candidate = name
        var isFile = false
        for suffix in [".plist", ".savedState"] where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
            isFile = true
        }
        var parts = candidate.split(separator: ".")
        // ByHost plists are <bundleid>.<host>.plist — the trailing segment
        // is the host, not part of the id.
        if isFile && parts.count > 3 { parts = Array(parts.dropLast()) }
        guard isFile || parts.count >= 3, parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } })
        else { return nil }
        return parts.joined(separator: ".")
    }

    /// True when the candidate id is a helper/updater of an installed app:
    /// shares the first two DNS segments with an installed bundle id
    /// (`com.google.Keystone` ↔ `com.google.Chrome`), or is prefixed by one
    /// (`com.example.app.helper` ↔ `com.example.app`).
    static func belongsToInstalledApp(_ candidateID: String, installedIDs: Set<String>) -> Bool {
        let candidateParts = candidateID.split(separator: ".")
        for installed in installedIDs {
            let installedParts = installed.split(separator: ".")
            // Same vendor (first two segments) — helper/updater space.
            if installedParts.count >= 2, candidateParts.count >= 2,
               installedParts[0] == candidateParts[0],
               installedParts[1] == candidateParts[1] {
                return true
            }
            // The installed app IS the candidate's prefix (plugin bundles).
            if candidateID.hasPrefix(installed + ".") || installed == candidateID {
                return true
            }
        }
        return false
    }

    /// The bundle-id extraction rule for one Library entry.
    static func isSystemOwned(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.")
    }

    // MARK: - Scan

    /// Scans all roots. `progress` reports the directory being walked.
    static func scan(progress: ((String) -> Void)? = nil,
                     staleDays: Int = 30) async -> [Candidate] {
        let installedIDs = Self.installedBundleIDs()
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(staleDays) * 24 * 3600)
        var candidates: [Candidate] = []
        var index = 0

        for (root, kind) in scanRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() {
                progress?(root)
                index += 1
                guard let bundleID = bundleID(fromEntryName: entry) else { continue }
                guard !isSystemOwned(bundleID),
                      !builtinProtectedIDs.contains(bundleID) else { continue }
                guard !belongsToInstalledApp(bundleID, installedIDs: installedIDs) else { continue }
                let url = URL(fileURLWithPath: root + "/" + entry)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let modified = attrs?[.modificationDate] as? Date
                // Active software writes within the window — skip anything
                // touched recently regardless of classification.
                if let modified, modified > cutoff { continue }
                // A deletion candidate must pass the safety layer (the
                // Preferences category needs the bundle-scoped exemption).
                guard deletable(url, bundleID: bundleID) else { continue }
                let bytes = await ScanEngine.parallelSize(of: url).bytes
                guard bytes > 0 else { continue }
                candidates.append(Candidate(
                    id: "\(bundleID)#\(kind)#\(index)",
                    url: url, bundleID: bundleID, kind: kind,
                    bytes: bytes, lastModified: modified))
            }
        }
        return candidates.sorted { $0.bytes > $1.bytes }
    }

    /// Same rule the uninstaller applies: SafetyGuard verdict, with ONE
    /// exemption for a preference plist scoped to the orphan's own bundle id.
    static func deletable(_ url: URL, bundleID: String) -> Bool {
        if SafetyGuard.checkDeletable(url).allowed { return true }
        let name = url.lastPathComponent
        return url.path.contains("/Library/Preferences/")
            && (name == "\(bundleID).plist" || name.hasPrefix(bundleID + "."))
    }

    /// Bundle ids of every installed app (user + system Applications roots).
    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications",
                     "/System/Applications",
                     FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Applications").path]
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                if let bundle = Bundle(url: URL(fileURLWithPath: root + "/" + entry)),
                   let id = bundle.bundleIdentifier {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    // MARK: - Removal

    struct Outcome: Identifiable {
        let id = UUID()
        let path: String
        let success: Bool
        let error: String?
    }

    /// Moves the selected orphans to the Trash (recoverable — the
    /// classification is heuristic, so nothing here is permanent).
    static func trash(_ candidates: [Candidate]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        for candidate in candidates {
            guard deletable(candidate.url, bundleID: candidate.bundleID) else {
                outcomes.append(Outcome(path: candidate.url.path, success: false,
                                        error: "blocked by safety guard"))
                continue
            }
            do {
                try await Task.detached {
                    try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
                }.value
                outcomes.append(Outcome(path: candidate.url.path, success: true, error: nil))
            } catch {
                outcomes.append(Outcome(path: candidate.url.path, success: false,
                                        error: error.localizedDescription))
            }
        }
        return outcomes
    }
}
