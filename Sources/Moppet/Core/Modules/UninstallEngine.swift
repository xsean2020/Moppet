import Foundation
import AppKit

/// App uninstall engine — SwiftUI cousin of `mo uninstall`:
/// enumerate apps, resolve bundle IDs, locate related files, review, trash.
enum UninstallEngine {

    struct AppEntry: Identifiable {
        let id: String          // bundle identifier or path
        let name: String
        let url: URL
        let bundleID: String?
        let bytes: Int64
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    struct RelatedFile: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        let kind: String     // preferences / caches / containers / support…
        let deletable: Bool  // false → needs admin or is protected
    }

    // MARK: - List installed apps

    /// Fast metadata-only listing (bundle ids + names, no sizing) — sizing is
    /// a heavy recursive walk, so it is computed off-view in `sizeApps`.
    static func listApps() -> [AppEntry] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            // /System/Applications stays out: the SIP volume rejects recycle,
            // so every system app row was an uninstall that can only fail.
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var entries: [AppEntry] = []
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for child in children where child.pathExtension == "app" {
                let bundle = Bundle(url: child)
                let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? child.deletingPathExtension().lastPathComponent
                // id = path: the same bundleID installed in two roots made
                // both rows share selection state and kill each other's data.
                entries.append(
                    AppEntry(
                        id: child.path,
                        name: name,
                        url: child,
                        bundleID: bundle?.bundleIdentifier,
                        bytes: 0
                    )
                )
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sizes apps in parallel (off the view); returns id → bytes.
    static func sizeApps(_ apps: [AppEntry],
                         progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [String: Int64] {
        await withTaskGroup(of: (String, Int64).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask {
                    let bytes = await ScanEngine.parallelSize(of: app.url).bytes
                    await MainActor.run { progress(index + 1, apps.count) }
                    return (app.id, bytes)
                }
            }
            var sizes: [String: Int64] = [:]
            for await (id, bytes) in group { sizes[id] = bytes }
            return sizes
        }
    }

    // MARK: - Related files for a bundle ID

    static func relatedFiles(appName: String, bundleID: String?) -> [RelatedFile] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        // User-level hidden directories, by bundle id AND by app name.
        var candidates: [(URL, String, Bool)] = [
            (home.appendingPathComponent("Library/Preferences/\(bundleID).plist"), "preferences", true),
            (home.appendingPathComponent("Library/Caches/\(bundleID)"), "caches", true),
            (home.appendingPathComponent("Library/Caches/\(appName)"), "caches (by name)", true),
            (home.appendingPathComponent("Library/Application Support/\(bundleID)"), "app support", true),
            (home.appendingPathComponent("Library/Application Support/\(appName)"), "app support", true),
            (home.appendingPathComponent("Library/Containers/\(bundleID)"), "container", true),
            (home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState"), "saved state", true),
            (home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"), "http storage", true),
            (home.appendingPathComponent("Library/WebKit/\(bundleID)"), "webkit", true),
            (home.appendingPathComponent("Library/Logs/\(bundleID)"), "logs", true),
            (home.appendingPathComponent("Library/Logs/\(appName)"), "logs (by name)", true),
            (home.appendingPathComponent("Library/Application Support/CrashReporter/\(appName)"), "crash logs", true),
            (home.appendingPathComponent("Library/LaunchAgents/\(bundleID).plist"), "launch agent", true),
        ]
        // ~/Library/Preferences/ByHost/<bundleID>.*.plist
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
        if let entries = try? fm.contentsOfDirectory(atPath: byHost.path) {
            for entry in entries where entry.hasPrefix(bundleID + ".") {
                candidates.append((byHost.appendingPathComponent(entry), "preferences (ByHost)", true))
            }
        }
        // System-level leftovers (need admin to remove).
        candidates.append(contentsOf: [
            (URL(fileURLWithPath: "/Library/Preferences/\(bundleID).plist"), "system preferences (admin)", false),
            (URL(fileURLWithPath: "/Library/Caches/\(bundleID)"), "system caches (admin)", false),
            (URL(fileURLWithPath: "/Library/Application Support/\(bundleID)"), "system app support (admin)", false),
            (URL(fileURLWithPath: "/Library/LaunchAgents/\(bundleID).plist"), "system launch agent (admin)", false),
            // NOTE: no by-appName candidates at system scope — the removal is
            // a root `rm -rf`, and name collisions with other products under
            // /Library would destroy their data. bundleID paths only.
            (URL(fileURLWithPath: "/private/var/db/receipts/\(bundleID).plist"), "pkg receipt (report)", false),
            (URL(fileURLWithPath: "/private/var/db/receipts/\(bundleID).bom"), "pkg bom (report)", false),
        ])
        var results: [RelatedFile] = []
        // Group containers partial match (report-only; group containers are protected).
        let groupRoot = home.appendingPathComponent("Library/Group Containers")
        if let groups = try? FileManager.default.contentsOfDirectory(atPath: groupRoot.path) {
            for g in groups where g.contains(bundleID) {
                let url = groupRoot.appendingPathComponent(g)
                results.append(RelatedFile(url: url, bytes: ScanEngine.cachedSize(of: url).bytes,
                                           kind: "group container", deletable: false))
            }
        }

        for (url, kind, userLevel) in candidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            let bytes = ScanEngine.cachedSize(of: url).bytes
            // A bundle-scoped preference plist IS deletable even though
            // ~/Library/Preferences is a protected category as a whole —
            // without the exemption the most common uninstall leftover was
            // a dead locked row.
            let bundleScopedPref = url.path.hasPrefix(home.path + "/Library/Preferences/")
                && (url.lastPathComponent == "\(bundleID).plist"
                    || url.lastPathComponent.hasPrefix(bundleID + "."))
            let allowed = SafetyGuard.checkDeletable(url).allowed || bundleScopedPref
            results.append(RelatedFile(
                url: url, bytes: bytes, kind: kind,
                deletable: userLevel && allowed))
        }
        // The by-name LaunchAgent plist and the by-content scan hit the SAME
        // file → the second recycle always failed ("failures: 1").
        var seen = Set<String>()
        results = results.filter { seen.insert($0.url.path).inserted }
        // Launch agents/daemons that reference the bundle id BY CONTENT — both
        // user-level and system-level (the usual "zombie" startup items).
        let launchRoots = [
            (home.appendingPathComponent("Library/LaunchAgents"), true),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), false),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), false),
        ]
        for (root, userLevel) in launchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries {
                let p = root.appendingPathComponent(entry)
                guard let text = try? String(contentsOf: p, encoding: .utf8),
                      text.contains(bundleID) else { continue }
                let kind = userLevel
                    ? "launch agent (references app)"
                    : (root.path.contains("Daemons") ? "system launch daemon (admin)"
                                                     : "system launch agent (admin)")
                results.append(RelatedFile(
                    url: p, bytes: 0, kind: kind,
                    deletable: userLevel && SafetyGuard.checkDeletable(p).allowed))
            }
        }
        return results
    }

    /// Removes SYSTEM-level leftovers with an administrator prompt
    /// (AppleScript privileges — the GUI counterpart of mole's sudo).
    @MainActor
    static func removeSystemLeftovers(_ files: [RelatedFile],
                                      progress: ((_ done: Int, _ total: Int, _ name: String) -> Void)? = nil)
        async -> [(String, String?)] {
        var results: [(String, String?)] = []
        let total = files.count
        for (index, file) in files.enumerated() {
            let path = file.url.path
            progress?(index, total, file.url.lastPathComponent)
            guard path.hasPrefix("/Library/") || path.hasPrefix("/private/var/db/receipts/") else {
                results.append((path, "not a system path"))
                progress?(index + 1, total, file.url.lastPathComponent)
                continue
            }
            do {
                _ = try await OptimizeEngine.shellWithAdmin(
                    "rm -rf '\(path.replacingOccurrences(of: "'", with: "'\\''"))'")
                results.append((path, nil))
            } catch {
                results.append((path, error.localizedDescription))
            }
            progress?(index + 1, total, file.url.lastPathComponent)
        }
        return results
    }

    // MARK: - Batch uninstall (multi-select)

    struct BatchOutcome {
        /// id = AppEntry.id (the app's path) — the view removes ONLY these
        /// rows; names alone couldn't disambiguate and failed uninstalls
        /// used to ghost their rows out of the list anyway.
        var trashed: [(id: String, name: String)] = []
        var failed: [(name: String, reason: String)] = []
        var freedBytes: Int64 = 0
        /// App-data sweep (withData): how many related files went away and
        /// how many bytes they held. Zero when the sweep was not requested.
        var relatedFiles: Int = 0
        var relatedBytes: Int64 = 0
    }

    /// A related file is removable when SafetyGuard allows it, with ONE
    /// exemption: a preference plist scoped to this bundle. ~/Library/
    /// Preferences is a protected category as a whole, but the app's own
    /// `<bundleid>.plist` / `<bundleid>.<host>.plist` is exactly the leftover
    /// users expect an uninstall to sweep. Both the single and batch paths
    /// must agree, or the batch leaves preferences behind in silence.
    static func isDeletableRelated(_ file: RelatedFile, bundleID: String?) -> Bool {
        guard file.deletable else { return false }
        if SafetyGuard.checkDeletable(file.url).allowed { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        guard file.url.path.contains("/Library/Preferences/") else { return false }
        let name = file.url.lastPathComponent
        return name == "\(bundleID).plist" || name.hasPrefix(bundleID + ".")
    }

    /// Removes several apps permanently in one pass. Related user
    /// data is only removed when `withData` is enabled and files are found.
    /// NOT @MainActor on purpose: the batch is pure async file work, and the
    /// MainActor annotation deadlocked every headless caller (smoke blocks the
    /// main thread on a semaphore, so a MainActor hop can never run).
    static func batchUninstall(apps: [AppEntry], sizes: [String: Int64],
                               withData: Bool,
                               appendRecord: Bool = true) async -> BatchOutcome {
        var outcome = BatchOutcome()
        // Fill in any app the caller hadn't sized yet (AppEntry.bytes is 0 and
        // the dict can be incomplete mid-sizing) BEFORE recycling — once the
        // bundle is in the Trash its size can't be measured reliably.
        var effectiveSizes = sizes
        for app in apps where (effectiveSizes[app.id] ?? 0) <= 0 {
            effectiveSizes[app.id] = await ScanEngine.parallelSize(of: app.url).bytes
        }
        // Permanent delete (the user opted out of Trash). Per-app so one
        // failure doesn't abort the rest; verify the path is really gone.
        for app in apps {
            do {
                try await Task.detached { try FileManager.default.removeItem(at: app.url) }.value
                if !FileManager.default.fileExists(atPath: app.url.path) {
                    outcome.trashed.append((app.id, app.name))
                    outcome.freedBytes += effectiveSizes[app.id] ?? 0
                } else {
                    outcome.failed.append((app.name, "could not delete"))
                }
            } catch {
                outcome.failed.append((app.name, error.localizedDescription))
            }
        }
        var relatedItems: [(path: String, bytes: Int64)] = []
        if withData {
            for app in apps {
                let files = relatedFiles(
                    appName: app.name, bundleID: app.bundleID)
                for file in files where Self.isDeletableRelated(file, bundleID: app.bundleID) {
                    do {
                        try await Task.detached { try FileManager.default.removeItem(at: file.url) }.value
                        relatedItems.append((file.url.path, file.bytes))
                        outcome.relatedFiles += 1
                        outcome.relatedBytes += file.bytes
                    } catch {
                        outcome.failed.append((file.url.lastPathComponent,
                                               error.localizedDescription))
                    }
                }
            }
        }
        let relatedBytes = relatedItems.reduce(0) { $0 + $1.bytes }
        // Record ONLY apps that actually trashed, each with its real size, so
        // History's per-path rows show numbers instead of "—" and failed apps
        // no longer masquerade as successful removals.
        let appItems = outcome.trashed.map { (path: $0.id, bytes: effectiveSizes[$0.id] ?? 0) }
        let record = CleanRecord(
            date: Date(), sectionTitles: ["Uninstall (batch)"],
            requestedBytes: outcome.freedBytes + relatedBytes,
            freedBytes: outcome.freedBytes + relatedBytes,
            itemCount: appItems.count + relatedItems.count,
            items: appItems.map {
                CleanRecordItem(path: $0.path, bytes: $0.bytes, mode: .permanent, success: true, error: nil)
            } + relatedItems.map {
                CleanRecordItem(path: $0.path, bytes: $0.bytes, mode: .permanent, success: true, error: nil)
            }, source: .uninstallBatch)
        // Callers that run several single-app passes (the UI's sequential
        // progress loop) pass appendRecord:false and write ONE aggregated
        // record themselves — otherwise History got a row per app.
        if appendRecord { HistoryStore.append(record) }
        return outcome
    }

    // MARK: - Uninstall (app bundle + selected related files → Trash)

    struct UninstallResult {
        let appTrashed: Bool
        let removedFiles: [String]
        let failed: [(String, String)]
    }

    /// Uninstalls one app plus its related files.
    ///
    /// `progress` reports (done, total, current name) over the app bundle and
    /// every related file: an app with hundreds of leftovers takes long enough
    /// that a static page reads as a hang.
    @MainActor
    static func uninstall(app: AppEntry, files: [RelatedFile], removeData: Bool,
                          progress: ((_ done: Int, _ total: Int, _ name: String) -> Void)? = nil)
        async -> UninstallResult {
        var removed: [String] = []
        var failed: [(String, String)] = []
        var appOK = false
        let dataFiles = removeData ? files.filter(\.deletable) : []
        let total = 1 + dataFiles.count
        var done = 0
        progress?(done, total, app.name)

        // App bundle removal (works for user-writable /Applications subfolders and ~/Applications).
        // removed/failed carry full paths so the history audit can show exactly what happened.
        do {
            // Permanent delete (the user opted out of Trash): removeItem is
            // synchronous and recursive for bundles — run it off the main
            // actor so a multi-GB app doesn't freeze the UI.
            try await Task.detached { try FileManager.default.removeItem(at: app.url) }.value
            appOK = !FileManager.default.fileExists(atPath: app.url.path)
            if appOK { removed.append(app.url.path) }
        } catch {
            failed.append((app.url.path, error.localizedDescription))
        }
        done += 1
        progress?(done, total, app.name)

        for file in dataFiles {
            progress?(done, total, file.url.lastPathComponent)
            // Same bundle-scoped-preferences exemption as relatedFiles —
            // otherwise the row is deletable in the UI but blocked here.
            let prefExempt: Bool
            if let bid = app.bundleID {
                prefExempt = file.url.path.hasSuffix("/\(bid).plist")
                    || (file.url.path.contains("/Library/Preferences/")
                        && file.url.lastPathComponent.hasPrefix(bid + "."))
            } else {
                prefExempt = false
            }
            guard SafetyGuard.checkDeletable(file.url).allowed || prefExempt else {
                failed.append((file.url.path, "blocked by safety guard"))
                done += 1
                progress?(done, total, file.url.lastPathComponent)
                continue
            }
            do {
                try await Task.detached { try FileManager.default.removeItem(at: file.url) }.value
                removed.append(file.url.path)
            } catch {
                failed.append((file.url.path, error.localizedDescription))
            }
            done += 1
            progress?(done, total, file.url.lastPathComponent)
        }
        return UninstallResult(appTrashed: appOK, removedFiles: removed, failed: failed)
    }
}
