import Foundation

/// Scheduled cleaning — a LaunchAgent that runs a SAFE, headless clean on a
/// daily / weekly calendar interval.
///
/// Design constraints:
/// - The scheduled run never widens scope: it cleans exactly the items that
///   are permanent-mode AND non-deep (caches, logs, dev package caches —
///   all regenerable). Trash, installers and whole-home deep scans are
///   never included; a background task with no one to confirm must not
///   decide to empty the Trash.
/// - The agent writes a real launchd plist (XML only — launchd rejects JSON)
///   and bootstraps it into the user's gui domain. No admin prompt needed.
/// - `--scheduled-clean` is the headless entry: scan → clean → audit record
///   (source: scheduled) → exit, printing a summary for the log file.
enum Scheduler {

    static let plistURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.moppet.schedule.plist")
    static let label = "com.moppet.schedule"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/moppet-schedule.log")
    private static let settingsKey = "schedule.settings"

    // MARK: - Settings

    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case daily, weekly
        var id: String { rawValue }
    }

    struct Settings: Codable, Equatable {
        var enabled: Bool = false
        var frequency: Frequency = .daily
        /// 1 = Sunday … 7 = Saturday (launchd's Weekday convention).
        var weekday: Int = 1
        /// Hour of day, 0–23.
        var hour: Int = 3

        static func load() -> Settings {
            guard let data = UserDefaults.standard.data(forKey: settingsKey),
                  let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
                return Settings()
            }
            return settings
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: settingsKey)
            }
        }
    }

    // MARK: - Safe item set

    /// The only rules a background run may execute: permanent-mode,
    /// non-deep, non-Trash. Installers/archives are trash-routed (needs a
    /// human review) and deep scans walk the whole home (too slow for a
    /// scheduled task).
    static func safeCleanItems() -> [CleanItem] {
        RuleLibrary.sections.flatMap(\.items).filter { item in
            item.mode == .permanent && item.deepExtensions == nil && item.id != "trash"
        }
    }

    // MARK: - Plist generation (pure, smoke-tested)

    /// Builds the launchd plist. `executablePath` must be absolute.
    static func plistXML(settings: Settings, executablePath: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var calendar = "<key>Hour</key><integer>\(max(0, min(settings.hour, 23)))</integer>"
        calendar += "<key>Minute</key><integer>0</integer>"
        if settings.frequency == .weekly {
            calendar += "<key>Weekday</key><integer>\(max(0, min(settings.weekday, 7)))</integer>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(esc(executablePath))</string>
                <string>--scheduled-clean</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>\(calendar)</dict>
            <key>StandardOutPath</key><string>\(esc(logURL.path))</string>
            <key>StandardErrorPath</key><string>\(esc(logURL.path))</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Install / uninstall

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Installs (or refreshes) the LaunchAgent and bootstraps it. Errors
    /// carry the launchctl output so the Settings UI can show why it failed.
    static func install(settings: Settings) async throws {
        guard let executable = Bundle.main.executableURL?.path,
              executable.hasPrefix("/") else {
            throw NSError(domain: "scheduler", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "cannot determine the app binary path"])
        }
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plistXML(settings: settings, executablePath: executable)
            .write(to: plistURL, atomically: true, encoding: .utf8)
        let uid = getuid()
        // bootout ignores "not loaded" failures; bootstrap must succeed.
        _ = try? await OptimizeEngine.shell(
            "launchctl bootout gui/\(uid)/\(label) 2>/dev/null || true")
        _ = try await OptimizeEngine.shell(
            "launchctl bootstrap gui/\(uid) '\(plistURL.path)'")
        settings.save()
    }

    static func uninstall() async {
        let uid = getuid()
        _ = try? await OptimizeEngine.shell(
            "launchctl bootout gui/\(uid)/\(label) 2>/dev/null || true")
        try? FileManager.default.removeItem(at: plistURL)
        Settings.load().withEnabled(false).save()
    }

    /// Readable schedule summary for the Settings row.
    static func describe(_ settings: Settings) -> String {
        let weekdays = [L("Sunday"), L("Monday"), L("Tuesday"), L("Wednesday"),
                        L("Thursday"), L("Friday"), L("Saturday")]
        let hour = String(format: "%02d:00", settings.hour)
        switch settings.frequency {
        case .daily: return String(format: L("Every day at %@"), hour)
        case .weekly: return String(format: L("Every %@ at %@"),
                                    weekdays[settings.weekday - 1], hour)
        }
    }
}

extension Scheduler.Settings {
    /// Fluent toggle used by uninstall()'s load-modify-save.
    func withEnabled(_ value: Bool) -> Scheduler.Settings {
        var copy = self
        copy.enabled = value
        return copy
    }
}

// MARK: - Headless run (--scheduled-clean, launched by the LaunchAgent)

extension Scheduler {

    /// Blocking headless entry point: safe-item scan → clean → audit record
    /// → summary on stdout. Launchd captures stdout/stderr into the log
    /// file, so the summary doubles as the run's audit trail.
    static func runScheduledClean() -> Never {
        // Mirror BrainExec's headless posture: no UI can appear, so any
        // interactive confirmation request would hang forever — the safe
        // item set guarantees the executor never needs one.
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode = 0
        Task {
            do {
                let summary = try await performScheduledClean()
                print(summary)
            } catch {
                FileHandle.standardError.write(
                    Data("scheduled clean failed: \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(Int32(exitCode))
    }

    static func performScheduledClean() async throws -> String {
        let items = safeCleanItems()
        guard !items.isEmpty else { throw NSError(domain: "scheduler", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "no safe clean items"]) }
        let results = await ScanEngine.scan(items: items)
        let findings = results.flatMap(\.findings)
        guard !findings.isEmpty else {
            return "Scheduled clean: nothing to clean."
        }
        let outcomes = await CleanExecutor.clean(findings: findings)
        let freed = outcomes.filter(\.success).reduce(0) { $0 + $1.bytes }
        let failed = outcomes.filter { !$0.success }
        HistoryStore.append(CleanRecord(
            date: Date(),
            sectionTitles: [L("Scheduled Clean")],
            requestedBytes: findings.reduce(0) { $0 + $1.bytes },
            freedBytes: freed,
            itemCount: findings.count,
            items: outcomes.map {
                CleanRecordItem(path: $0.path, bytes: $0.bytes, mode: $0.mode,
                                success: $0.success, error: $0.error)
            }, source: .scheduled))
        var text = "Scheduled clean freed \(freed.bytesFormatted) in "
            + "\(outcomes.count - failed.count) paths."
        if !failed.isEmpty {
            text += " \(failed.count) failed:"
            text += "\n" + failed.prefix(5).map {
                "  · \((($0.path) as NSString).lastPathComponent): \($0.error ?? "?")"
            }.joined(separator: "\n")
        }
        return text
    }
}
