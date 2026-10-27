import Foundation
import AppKit

/// Startup items manager — disable LaunchAgents/LaunchDaemons so apps stop
/// launching at login / running in the background.
///
/// Scopes scanned:
/// - `~/Library/LaunchAgents`   (user agents — no admin needed)
/// - `/Library/LaunchAgents`    (global agents — root-owned, admin prompt)
/// - `/Library/LaunchDaemons`   (boot daemons — root-owned, admin prompt)
///
/// Disable semantics (reversible, never deletes):
/// 1. `plutil -replace Disabled -bool true <plist>`  (persistent)
/// 2. `launchctl bootout …`                          (unload NOW — stops
///    a running agent immediately; errors ignored when not loaded)
/// Enable: `Disabled` → false + (best effort) `launchctl bootstrap` so the
/// service is registered again for the next login.
///
/// Apple's own `com.apple.*` items are EXCLUDED from results (shown only as
/// a hidden count): disabling boot daemons like sandboxd can wedge the
/// system, and users who need that know launchctl already.
enum LaunchItemsEngine {

    enum Scope: String, Codable, CaseIterable {
        case userAgents = "user-agents"
        case globalAgents = "global-agents"
        case globalDaemons = "global-daemons"

        var directory: String {
            switch self {
            case .userAgents:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents").path
            case .globalAgents:
                return "/Library/LaunchAgents"
            case .globalDaemons:
                return "/Library/LaunchDaemons"
            }
        }

        var needsAdmin: Bool { self != .userAgents }
    }

    struct Item: Identifiable, Equatable {
        var id: String { path }
        let label: String
        let path: String
        let scope: Scope
        let program: String
        let runAtLoad: Bool
        let keepAlive: Bool
        /// plist `Disabled` key — true means macOS will not start it.
        let disabled: Bool
        /// Whether launchctl currently has it loaded (`launchctl list`).
        let loaded: Bool

        var displayName: String {
            (program as NSString).lastPathComponent.isEmpty
                ? label
                : (program as NSString).lastPathComponent
        }
    }

    struct Outcome: Identifiable {
        let id = UUID()
        let label: String
        let enabled: Bool
        let success: Bool
        let message: String
    }

    // MARK: - plist parsing (pure, smoke-tested)

    struct ParsedInfo: Equatable {
        var label: String
        var program: String
        var runAtLoad: Bool
        var keepAlive: Bool
        var disabled: Bool
    }

    /// Extracts the fields the UI needs from a launchd plist. `keepAlive`
    /// may be a bool OR a dictionary (keepalive conditions) — any non-false
    /// value counts as "kept alive".
    static func parsePlistData(_ data: Data) -> ParsedInfo? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
            let label = plist["Label"] as? String else { return nil }
        let program: String
        if let prog = plist["Program"] as? String {
            program = prog
        } else if let args = plist["ProgramArguments"] as? [Any],
                  let first = args.first as? String {
            program = first
        } else {
            program = ""
        }
        let keepAliveValue = plist["KeepAlive"]
        let keepAlive = !(keepAliveValue == nil || (keepAliveValue as? Bool) == false)
        return ParsedInfo(
            label: label,
            program: program,
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
            keepAlive: keepAlive,
            disabled: (plist["Disabled"] as? Bool) ?? false)
    }

    static func isSystemItem(_ label: String) -> Bool {
        label.hasPrefix("com.apple.")
    }

    // MARK: - Scan

    static func scan(progress: ((String) -> Void)? = nil) async -> (items: [Item], hiddenSystem: Int) {
        // `launchctl list` output rows end with the label; a hit means loaded.
        let listed = await shell("launchctl list", admin: false)
        let loadedLabels = Set(listed.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        })

        var items: [Item] = []
        var hiddenSystem = 0
        for scope in Scope.allCases {
            let dir = scope.directory
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() where file.hasSuffix(".plist") {
                progress?(file)
                let path = dir + "/" + file
                guard let data = FileManager.default.contents(atPath: path),
                      let info = parsePlistData(data) else { continue }
                if isSystemItem(info.label) {
                    hiddenSystem += 1
                    continue
                }
                items.append(Item(
                    label: info.label, path: path, scope: scope,
                    program: info.program, runAtLoad: info.runAtLoad,
                    keepAlive: info.keepAlive, disabled: info.disabled,
                    loaded: loadedLabels.contains(info.label)))
            }
        }
        return (items.sorted { $0.label < $1.label }, hiddenSystem)
    }

    // MARK: - Enable / disable

    /// Matches an item by label or exact path (strict per HANDOFF §6.22 —
    /// no fuzzy widening: unknown identifiers are an error listing what IS
    /// available).
    static func matchItem(_ identifier: String, in items: [Item]) -> Item? {
        // Exact path first: the same label installed in BOTH ~/Library and
        // /Library (updater agents) made label-only matching hit the wrong
        // scope's plist — a user-domain row could flip the global one.
        items.first { $0.path == identifier }
            ?? items.first { $0.label == identifier }
    }

    static func setEnabled(_ identifier: String, enabled: Bool,
                           dryRun: Bool = false) async -> Outcome {
        let (items, _) = await scan()
        guard let item = matchItem(identifier, in: items) else {
            let available = items.map(\.label).sorted().joined(separator: "\n")
            return Outcome(label: identifier, enabled: enabled, success: false,
                           message: "no such launch item (match by label or exact path). Available:\n\(available)")
        }
        if enabled && item.disabled == false && item.loaded {
            return Outcome(label: item.label, enabled: enabled, success: true,
                           message: "already enabled and loaded")
        }
        if !enabled && item.disabled {
            // Plist flag set but launchd still has it loaded (override DB) —
            // the user's intent is "stop it", so fall through to bootout
            // instead of reporting success with the agent still running.
            if !item.loaded {
                return Outcome(label: item.label, enabled: enabled, success: true,
                               message: "already disabled (persisted)")
            }
        }
        if dryRun {
            return Outcome(label: item.label, enabled: enabled, success: true,
                           message: enabled
                               ? "would set Disabled=false in \(item.path)"
                               : "would set Disabled=true and unload \(item.path)")
        }

        // POSIX single-quote escaping — file names under LaunchAgents dirs
        // are chosen by the apps that install them; the global scope runs
        // this through an ADMIN shell, so $, backticks and \\ must not pass.
        let plistEscaped = "'" + item.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var command = "plutil -replace Disabled -bool \(enabled ? "false" : "true") \(plistEscaped)"
        if !enabled {
            // Unload now: stops a currently running agent immediately.
            if item.scope == .userAgents {
                command += "; launchctl bootout gui/$(id -u) \(plistEscaped) || true"
            } else {
                command += "; launchctl bootout system \(plistEscaped) || true"
            }
        }
        do {
            _ = item.scope.needsAdmin
                ? try await OptimizeEngine.shellWithAdmin(command)
                : try await OptimizeEngine.shell(command)
        } catch {
            let message = item.scope.needsAdmin
                ? "administrator authorization failed or refused: \(error.localizedDescription)"
                : "command failed: \(error.localizedDescription)"
            record(item, enabled: enabled, success: false, message: message)
            return Outcome(label: item.label, enabled: enabled, success: false, message: message)
        }
        let message = enabled
            ? "enabled (Disabled=false) — starts at next login; reload now if needed"
            : "disabled (Disabled=true) and unloaded"
        record(item, enabled: enabled, success: true, message: message)
        return Outcome(label: item.label, enabled: enabled, success: true, message: message)
    }

    /// Startup-item changes join the audit trail like every other
    /// state-changing operation.
    private static func record(_ item: Item, enabled: Bool, success: Bool, message: String) {
        HistoryStore.append(CleanRecord(
            date: Date(),
            sectionTitles: [item.label],
            requestedBytes: 0,
            freedBytes: 0,
            itemCount: 1,
            items: [CleanRecordItem(
                path: item.path, bytes: 0, mode: .permanent,
                success: success,
                error: success ? nil : message)], source: .startup))
    }

    private static func shell(_ command: String, admin: Bool) async -> String {
        do {
            return admin ? try await OptimizeEngine.shellWithAdmin(command)
                         : try await OptimizeEngine.shell(command)
        } catch {
            return ""
        }
    }
}
