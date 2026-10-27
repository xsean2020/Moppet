import Foundation

/// The single registry of built-in tools that BOTH the in-app AI agent and
/// external MCP clients call. This is the "AI-callable built-in tools" layer:
/// every mole capability is exposed as a typed tool with a JSON schema,
/// safety-gated exactly like the interactive UI.
///
/// Destructive tools are gated two ways:
/// - `.ui` mode (in-app agent): a native approval dialog via ApprovalCenter.
/// - `.mcp` mode (external agents): the caller must pass `"confirmed": true`
///   after asking the user — the same contract mole's AI skill encodes.
enum ToolRegistry {

    // MARK: - Tool definition

    struct Param {
        let name: String
        let type: String          // string | boolean | number | array
        let description: String
        let required: Bool
        let enums: [String]?

        init(_ name: String, _ type: String, _ description: String,
             required: Bool = false, enums: [String]? = nil) {
            self.name = name
            self.type = type
            self.description = description
            self.required = required
            self.enums = enums
        }
    }

    struct Tool {
        let name: String
        let description: String
        let params: [Param]
        let destructive: Bool
        let handler: ([String: Any], ApprovalMode) async throws -> String

        /// JSON Schema object for OpenAI tool-calling / MCP inputSchema.
        var jsonSchema: [String: Any] {
            var properties: [String: Any] = [:]
            var required: [String] = []
            for p in params {
                var prop: [String: Any] = ["type": p.type, "description": p.description]
                if let enums = p.enums { prop["enum"] = enums }
                properties[p.name] = prop
                if p.required { required.append(p.name) }
            }
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return schema
        }
    }

    enum ApprovalMode {
        /// In-app agent: show a native confirmation dialog.
        case ui
        /// MCP: require caller-provided `"confirmed": true`.
        case confirmedFlag
    }

    // MARK: - Errors

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Pending clean tokens (scan → confirm pipeline)
    // Lock-protected with a TTL: the registry is reachable from parallel
    // brain tool calls AND two MCP transports, and a stale token must not
    // keep Findings alive (or stay executable) long after the scan.

    private static let pendingLock = NSLock()
    private static var pendingCleans: [UUID: (findings: [Finding], createdAt: Date)] = [:]
    private static let pendingTTL: TimeInterval = 30 * 60

    private static func pendingStore(_ token: UUID, _ findings: [Finding]) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let now = Date()
        for (key, entry) in pendingCleans where now.timeIntervalSince(entry.createdAt) > pendingTTL {
            pendingCleans[key] = nil
        }
        pendingCleans[token] = (findings, now)
    }

    private static func pendingTake(_ token: UUID) -> [Finding]? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingCleans.removeValue(forKey: token)?.findings
    }

    // MARK: - Registry

    static var tools: [Tool] { buildTools() }

    static func tool(named name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    /// Execute a tool by name. `args` values come straight from JSON.
    static func execute(name: String, args: [String: Any], approval: ApprovalMode) async throws -> String {
        guard let tool = tool(named: name) else {
            throw ToolError(message: "unknown tool: \(name)")
        }

        // Destructive gate.
        if tool.destructive {
            switch approval {
            case .confirmedFlag:
                guard args["confirmed"] as? Bool == true else {
                    throw ToolError(message: """
                    \(name) is destructive. Show the dry-run result to the user, get their \
                    explicit consent, then call again with "confirmed": true.
                    """)
                }
            case .ui:
                let confirmed = await ApprovalCenter.shared.request(
                    title: "AI wants to run \(name)",
                    detail: describeArgs(args)
                )
                guard confirmed else { throw ToolError(message: "user declined \(name)") }
            }
        }
        PetBus.shared.setState(.thinking)
        defer { PetBus.shared.settle() }
        return try await tool.handler(args, approval)
    }

    private static func describeArgs(_ args: [String: Any]) -> String {
        args.map { key, value in
            "\(key): \(String(describing: value).prefix(120))"
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func str(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }
    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }
    private static func num(_ args: [String: Any], _ key: String) -> Double? {
        args[key] as? Double ?? (args[key] as? Int).map(Double.init) ?? (args[key] as? NSNumber)?.doubleValue
    }
    private static func strArray(_ args: [String: Any], _ key: String) -> [String]? {
        (args[key] as? [Any])?.compactMap { $0 as? String }
    }

    private static func table(_ rows: [(String, String)]) -> String {
        rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    // MARK: - Tool implementations

    private static func buildTools() -> [Tool] {
        var list: [Tool] = []

        // ---- Read-only status ----
        list.append(Tool(
            name: "disk_status",
            description: "Get overall disk usage of the boot volume (total, used, free, fraction).",
            params: [], destructive: false
        ) { _, _ in
            let d = DiskInfo.snapshot()
            return table([
                ("volume", d.volumeName),
                ("total", d.totalBytes.bytesFormatted),
                ("used", "\(d.usedBytes.bytesFormatted) (\(d.usedFraction.percentFormatted))"),
                ("free", d.freeBytes.bytesFormatted),
            ])
        })

        list.append(Tool(
            name: "system_status",
            description: "Live system metrics: CPU usage, memory pressure, network rates, battery, uptime.",
            params: [], destructive: false
        ) { _, _ in
            _ = SystemStatus.network  // prime rate sampling
            _ = SystemStatus.cpu      // prime delta sampling
            try? await Task.sleep(nanoseconds: 300_000_000)
            let cpu = SystemStatus.cpu
            let mem = SystemStatus.memory
            let net = SystemStatus.network
            let battery = SystemStatus.battery
            var rows: [(String, String)] = [
                ("cpu", "\(cpu.usage.percentFormatted) across \(cpu.cores) cores"),
                ("memory", "\(mem.usedBytes.bytesFormatted) used / \(mem.totalBytes.bytesFormatted) (pressure \(mem.pressure.percentFormatted))"),
                ("network", "↓\(Int64(net.rateIn).bytesFormatted)/s ↑\(Int64(net.rateOut).bytesFormatted)/s"),
                ("uptime", SystemStatus.uptimeFormatted),
            ]
            if battery.present {
                rows.append(("battery", "\(Int(battery.percentage * 100))%\(battery.charging ? " charging" : "")"))
            }
            return table(rows)
        })

        // ---- Clean (dry-run first!) ----
        list.append(Tool(
            name: "list_clean_rules",
            description: "List all built-in cleaning sections and items with their path patterns and deletion modes.",
            params: [], destructive: false
        ) { _, _ in
            RuleLibrary.sections.map { section in
                "\(section.title) [\(section.id)]\n" + section.items.map { item in
                    "  - \(item.name) [\(item.id)] \(item.pattern) (\(item.mode.rawValue))"
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        })

        list.append(Tool(
            name: "scan_clean",
            description: "DRY RUN. Scan clean items (read-only, deletes nothing). Returns per-item candidates with sizes plus a confirmation_token to use in execute_clean. ALWAYS pass sections or items when the user scoped the request (e.g. 'scan my browser caches' → sections:[\"browsers\"]) — omitting both scans exactly what the user has ticked on the Clean page (never more).",
            params: [
                Param("sections", "array", "Section ids to scan (e.g. [\"browsers\"]). Omit ONLY for a full sweep — never omit when the user named a category or app.", enums: RuleLibrary.sections.map(\.id)),
                Param("items", "array", "Specific item ids to scan (takes precedence over sections)"),
            ],
            destructive: false
        ) { args, _ in
            let selected = resolveItems(sections: strArray(args, "sections"), items: strArray(args, "items"))
            guard !selected.isEmpty else {
                throw ToolError(message:
                    "no matching clean items for sections=\(strArray(args, "sections") ?? []) items=\(strArray(args, "items") ?? [])"
                    + " — available section ids: \(RuleLibrary.sections.map(\.id).joined(separator: ", "))")
            }
            PetBus.shared.say("Scanning \(selected.count) locations…", state: .scanning)
            let results = await ScanEngine.scan(items: selected)
            let token = UUID()
            let findings = results.flatMap(\.findings)
            pendingStore(token, findings)
            PetBus.shared.say("Found \(findings.count) paths (\(findings.reduce(0) { $0 + $1.bytes }.bytesFormatted))", state: .celebrating)

            var text = "Scan complete (nothing deleted). Scanned scope: \(selected.map(\.id).joined(separator: ", "))\n"
            for r in results where !r.findings.isEmpty {
                text += "\n\(r.item.name) — \(r.totalBytes.bytesFormatted), \(r.findings.count) paths\n"
                text += r.findings.prefix(8).map { "  · \($0.lastPathComponent) (\($0.bytes.bytesFormatted))" }
                    .joined(separator: "\n")
                if r.findings.count > 8 { text += "\n  · … \(r.findings.count - 8) more" }
            }
            text += "\n\nconfirmation_token: \(token.uuidString)"
            text += "\nTotal reclaimable: \(findings.reduce(0) { $0 + $1.bytes }.bytesFormatted) in \(findings.count) paths."
            return text
        })

        list.append(Tool(
            name: "execute_clean",
            description: "Execute a previously scanned clean using its confirmation_token. Destructive: caches/logs are deleted permanently, installers/archives go to Trash. Always show the scan result to the user and get consent first.",
            params: [
                Param("confirmation_token", "string", "Token returned by scan_clean", required: true),
            ],
            destructive: true
        ) { args, _ in
            guard let tokenString = str(args, "confirmation_token"),
                  let token = UUID(uuidString: tokenString),
                  let findings = pendingTake(token) else {
                throw ToolError(message: "invalid or expired confirmation_token — run scan_clean first")
            }
            guard !findings.isEmpty else { throw ToolError(message: "nothing to delete") }
            PetBus.shared.say("Cleaning \(findings.count) items…", state: .cleaning)
            let outcomes = await CleanExecutor.clean(findings: findings)
            let freed = outcomes.filter(\.success).reduce(0) { $0 + $1.bytes }
            let failed = outcomes.filter { !$0.success }

            let record = CleanRecord(
                date: Date(),
                sectionTitles: ["AI Agent"],
                requestedBytes: findings.reduce(0) { $0 + $1.bytes },
                freedBytes: freed,
                itemCount: findings.count,
                items: outcomes.map {
                    CleanRecordItem(path: $0.path, bytes: $0.bytes, mode: $0.mode,
                                    success: $0.success, error: $0.error)
                }, source: .aiAgent)
            HistoryStore.append(record)
            PetBus.shared.say("Freed \(freed.bytesFormatted) 🎉", state: .celebrating)
            var text = "Freed \(freed.bytesFormatted) across \(outcomes.count - failed.count) items."
            if !failed.isEmpty {
                text += "\n\(failed.count) failures:\n" + failed.prefix(5).map {
                    "  · \(($0.path as NSString).lastPathComponent): \($0.error ?? "?")"
                }.joined(separator: "\n")
            }
            return text
        })

        // ---- Analyze / large files ----
        list.append(Tool(
            name: "analyze_disk",
            description: "Rank the largest direct children of a directory (default: home).",
            params: [Param("path", "string", "Directory to analyze (absolute path, default ~)")],
            destructive: false
        ) { args, _ in
            let target: URL
            if let p = str(args, "path"), p.hasPrefix("/") {
                target = URL(fileURLWithPath: p)
            } else {
                target = FileManager.default.homeDirectoryForCurrentUser
            }
            let entries = await ScanEngine.topChildren(of: target)
            return entries.enumerated().map { i, e in
                "\(i + 1). \(e.url.lastPathComponent) — \(e.bytes.bytesFormatted)"
            }.joined(separator: "\n")
        })

        list.append(Tool(
            name: "find_large_files",
            description: "Find large files (default >500MB) in Downloads/Documents/iCloud (report-only).",
            params: [
                Param("min_mb", "number", "Minimum size in MB (default 500)"),
                Param("limit", "number", "Max results (default 20)"),
            ],
            destructive: false
        ) { args, _ in
            let minMB = max(1, min(num(args, "min_mb") ?? 500, 1_000_000))
            let limit = max(1, min(Int(num(args, "limit") ?? 20), 200))
            let files = await LargeFilesEngine.find(
                minBytes: Int64(minMB * 1_000_000), limit: limit)
            if files.isEmpty { return "No files over \(Int(minMB))MB found." }
            return files.enumerated().map { i, f in
                "\(i + 1). \(f.url.path) — \(f.bytes.bytesFormatted)"
            }.joined(separator: "\n")
        })

        // ---- Purge (project artifacts) ----
        list.append(Tool(
            name: "find_project_artifacts",
            description: "Find regenerable build artifacts (node_modules, target, dist, .gradle, Pods, …) under developer directories. Report-only.",
            params: [Param("roots", "array", "Directories to search (default: ~/Projects, ~/Developer, ~/dev, ~/code, ~/work, ~/src)")],
            destructive: false
        ) { args, _ in
            let roots = (strArray(args, "roots") ?? []).map { URL(fileURLWithPath: ($0.hasPrefix("~") ? NSHomeDirectory() + $0.dropFirst() : $0)) }
            let effective = roots.isEmpty ? PurgeEngine.defaultRoots() : roots
            guard !effective.isEmpty else { return "No developer roots found." }
            let artifacts = await PurgeEngine.scan(roots: effective)
            guard !artifacts.isEmpty else { return "No project artifacts found." }
            let total = artifacts.reduce(0) { $0 + $1.bytes }
            return artifacts.enumerated().map { i, a in
                "\(i + 1). \(a.kind) @ \(a.projectPath) — \(a.bytes.bytesFormatted)"
            }.joined(separator: "\n") + "\nTotal: \(total.bytesFormatted)"
        })

        list.append(Tool(
            name: "purge_artifacts",
            description: "Permanently delete the listed artifact directories (regenerable build output). Destructive — confirm with the user first.",
            params: [Param("paths", "array", "Absolute artifact directory paths from find_project_artifacts", required: true)],
            destructive: true
        ) { args, _ in
            guard let paths = strArray(args, "paths"), !paths.isEmpty else {
                throw ToolError(message: "paths required")
            }
            let artifacts = paths.map {
                PurgeEngine.Artifact(url: URL(fileURLWithPath: $0), kind: "artifact", bytes: 0, projectPath: "-")
            }
            let results = PurgeEngine.purge(artifacts)
            let ok = results.filter { $0.1 == nil }
            let freedText = "\(ok.count) directories removed"
            let failures = results.filter { $0.1 != nil }
            return failures.isEmpty
                ? freedText
                : freedText + "; \(failures.count) failed: " + failures.prefix(3).map { "\($0.0.url.lastPathComponent): \($0.1!)" }.joined(separator: "; ")
        })

        // ---- Uninstall ----
        list.append(Tool(
            name: "list_apps",
            description: "List installed applications with bundle IDs and sizes (largest first).",
            params: [], destructive: false
        ) { _, _ in
            let apps = UninstallEngine.listApps().prefix(40)
            return apps.enumerated().map { i, app in
                "\(i + 1). \(app.name) [\(app.bundleID ?? "-")] — \(app.bytes.bytesFormatted) @ \(app.url.path)"
            }.joined(separator: "\n")
        })

        list.append(Tool(
            name: "app_related_files",
            description: "Find files related to an app by bundle id (preferences, caches, containers, support data). Report-only.",
            params: [Param("bundle_id", "string", "Bundle identifier, e.g. com.example.app", required: true)],
            destructive: false
        ) { args, _ in
            guard let bundleID = str(args, "bundle_id") else { throw ToolError(message: "bundle_id required") }
            let files = UninstallEngine.relatedFiles(appName: bundleID, bundleID: bundleID)
            if files.isEmpty { return "No related files found." }
            return files.map { "· [\($0.kind)] \($0.url.path) — \($0.bytes.bytesFormatted)\($0.deletable ? "" : " (protected)")" }
                .joined(separator: "\n")
        })

        list.append(Tool(
            name: "uninstall_app",
            description: "Move an application to the Trash, optionally including its user data (preferences/caches/containers). App goes to Trash — recoverable. Destructive — confirm with the user first.",
            params: [
                Param("app_path", "string", "Absolute path of the .app bundle", required: true),
                Param("remove_data", "boolean", "Also remove related user data (default false)"),
            ],
            destructive: true
        ) { args, _ in
            guard let appPath = str(args, "app_path"), appPath.hasSuffix(".app") else {
                throw ToolError(message: "app_path must point at a .app bundle")
            }
            // Absolute + standard roots only: a relative path resolved against
            // the process cwd, and any user-writable .app anywhere on disk
            // could be trashed by mistake.
            guard appPath.hasPrefix("/") else {
                throw ToolError(message: "app_path must be absolute")
            }
            let url = URL(fileURLWithPath: appPath).standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let allowedRoots = ["/Applications/", "/System/Applications/", home + "/Applications/"]
            guard allowedRoots.contains(where: { url.path.hasPrefix($0) }) else {
                throw ToolError(message: "app_path must live under /Applications or ~/Applications")
            }
            guard FileManager.default.fileExists(atPath: appPath) else {
                throw ToolError(message: "app not found: \(appPath)")
            }
            let removeData = bool(args, "remove_data") ?? false
            let files: [UninstallEngine.RelatedFile]
            if removeData {
                let bundle = Bundle(url: url)
                files = UninstallEngine.relatedFiles(
                    appName: url.deletingPathExtension().lastPathComponent,
                    bundleID: bundle?.bundleIdentifier)
            } else {
                files = []
            }
            let entry = UninstallEngine.AppEntry(
                id: url.path, name: url.deletingPathExtension().lastPathComponent,
                url: url, bundleID: Bundle(url: url)?.bundleIdentifier, bytes: 0)
            let result = await UninstallEngine.uninstall(app: entry, files: files, removeData: removeData)
            if result.appTrashed {
                return "Moved to Trash\(removeData ? " with \(result.removedFiles.count - 1) related files" : "")."
            }
            throw ToolError(message: "failed: \(result.failed.first?.1 ?? "unknown")")
        })

        // ---- Optimize ----
        list.append(Tool(
            name: "optimize_catalog",
            description: "List available system maintenance tasks. Some require an admin password prompt.",
            params: [], destructive: false
        ) { _, _ in
            OptimizeEngine.catalog.map { "· \($0.id) — \($0.title)\($0.requiresAdmin ? " (admin)" : "")" }
                .joined(separator: "\n")
        })

        list.append(Tool(
            name: "run_optimize",
            description: "Run a maintenance task by id. Admin-requiring tasks must be run from the app UI (password prompt) — the AI can only run non-admin tasks.",
            params: [Param("task_id", "string", "Task id from optimize_catalog", required: true)],
            destructive: true   // restarts Finder/Dock etc.
        ) { args, _ in
            guard let taskID = str(args, "task_id") else { throw ToolError(message: "task_id required") }
            guard let task = OptimizeEngine.catalog.first(where: { $0.id == taskID }) else {
                throw ToolError(message: "unknown task")
            }
            guard !task.requiresAdmin else {
                throw ToolError(message: "\(task.title) needs an admin password prompt — ask the user to run it from the Optimize screen in the app.")
            }
            return try await OptimizeEngine.run(taskID: taskID)
        })

        // ---- History ----
        list.append(Tool(
            name: "clean_history",
            description: "Recent clean runs with freed bytes and per-run summaries.",
            params: [Param("limit", "number", "Max runs (default 5)")],
            destructive: false
        ) { args, _ in
            // Model-controlled number: clamp before it reaches suffix() —
            // a negative limit is a precondition trap, not an error.
            let limit = max(0, min(Int(num(args, "limit") ?? 5), 200))
            let records = Array(HistoryStore.load().suffix(limit).reversed())
            if records.isEmpty { return "No runs recorded." }
            return records.map {
                "· \($0.date.formatted(date: .abbreviated, time: .shortened)): freed \($0.freedBytes.bytesFormatted) in \($0.itemCount) paths [\($0.sectionTitles.joined(separator: ", "))]"
            }.joined(separator: "\n")
        })

        // ---- Whitelist ----
        list.append(Tool(
            name: "whitelist_list",
            description: "List user whitelist glob patterns (paths that must never be touched).",
            params: [], destructive: false
        ) { _, _ in
            let patterns = SafetyGuard.loadWhitelistPatterns()
            return patterns.isEmpty ? "Whitelist is empty." : patterns.joined(separator: "\n")
        })

        list.append(Tool(
            name: "whitelist_add",
            description: "Add a glob pattern to the user whitelist, e.g. ~/Library/Caches/ImportantApp/*",
            params: [Param("pattern", "string", "Glob pattern", required: true)],
            // The whitelist is the "never touch" contract itself — rewriting it
            // is at least as destructive as any deletion it guards.
            destructive: true
        ) { args, _ in
            guard let pattern = str(args, "pattern"), !pattern.isEmpty else {
                throw ToolError(message: "pattern required")
            }
            var patterns = SafetyGuard.loadWhitelistPatterns()
            guard !patterns.contains(pattern) else { return "Already whitelisted." }
            patterns.append(pattern)
            try SafetyGuard.saveWhitelistPatterns(patterns)
            return "Added \(pattern) to whitelist."
        })

        list.append(Tool(
            name: "whitelist_remove",
            description: "Remove a glob pattern from the user whitelist.",
            params: [Param("pattern", "string", "Glob pattern to remove", required: true)],
            destructive: true
        ) { args, _ in
            guard let pattern = str(args, "pattern") else { throw ToolError(message: "pattern required") }
            var patterns = SafetyGuard.loadWhitelistPatterns()
            guard let idx = patterns.firstIndex(of: pattern) else { return "Not in whitelist." }
            patterns.remove(at: idx)
            try SafetyGuard.saveWhitelistPatterns(patterns)
            return "Removed \(pattern)."
        })

        // ---- Safety ----
        list.append(Tool(
            name: "safety_check",
            description: "Check whether a path would be allowed to be deleted by the safety layer (protected prefixes, categories, whitelist).",
            params: [Param("path", "string", "Absolute path", required: true)],
            destructive: false
        ) { args, _ in
            guard let path = str(args, "path") else { throw ToolError(message: "path required") }
            let verdict = SafetyGuard.checkDeletable(URL(fileURLWithPath: path))
            return verdict.allowed ? "ALLOWED" : "DENIED — \(verdict.reason ?? "?")"
        })

        // ---- Startup items (LaunchAgents / LaunchDaemons) ----
        list.append(Tool(
            name: "scan_launch_items",
            description: "List third-party launch items (user/global LaunchAgents and LaunchDaemons) with their disabled/loaded state. Apple com.apple.* system items are excluded. Read-only.",
            params: [], destructive: false
        ) { _, _ in
            let (items, hidden) = await LaunchItemsEngine.scan()
            guard !items.isEmpty else {
                return "No third-party launch items found\(hidden > 0 ? " (\(hidden) Apple system items hidden)" : "")."
            }
            return items.map { item in
                "· \(item.label) [\(item.scope.rawValue)\(item.disabled ? ", disabled" : ", enabled")\(item.loaded ? ", loaded" : "")] — \(item.path)"
            }.joined(separator: "\n") + "\n(\(hidden) Apple system items hidden)"
        })

        list.append(Tool(
            name: "set_launch_item_enabled",
            description: "Enable or disable one launch item by its exact label or path (from scan_launch_items). Disabling sets Disabled=true and unloads it NOW (stops background running); enabling clears the flag for the next login. DESTRUCTIVE: show the scan result and get the user's consent first. Global items need an administrator password.",
            params: [
                Param("item", "string", "Exact launch item label or absolute plist path", required: true),
                Param("enabled", "boolean", "true = enable, false = disable (required)", required: true),
                Param("dry_run", "boolean", "Report what would happen without changing anything"),
            ],
            destructive: true
        ) { args, _ in
            guard let identifier = str(args, "item"), !identifier.isEmpty else {
                throw ToolError(message: "item required — run scan_launch_items and pass the exact label or path")
            }
            guard let enabled = bool(args, "enabled") else {
                throw ToolError(message: "enabled (true/false) required")
            }
            let outcome = await LaunchItemsEngine.setEnabled(
                identifier, enabled: enabled, dryRun: bool(args, "dry_run") ?? false)
            let mark = outcome.success ? "✓" : "✗"
            return "\(mark) \(outcome.label) → \(enabled ? "enabled" : "disabled"): \(outcome.message)"
        })

        // ---- Universal-binary slimming (mo slim) ----
        list.append(Tool(
            name: "scan_slim",
            description: "Scan installed apps for universal binaries carrying Intel code (x86_64/i386 slices) on Apple Silicon. Read-only; returns each app's path and the bytes its Intel slices occupy.",
            params: [], destructive: false
        ) { _, _ in
            let candidates = await SlimEngine.scan()
            guard !candidates.isEmpty else {
                return "No universal apps with Intel code found (Intel Macs and App Store/Apple/running apps are skipped)."
            }
            let total = candidates.reduce(0) { $0 + $1.intelBytes }
            return candidates.map {
                "· \($0.name) — \($0.intelBytes.bytesFormatted) Intel code in \($0.binaries.count) binaries (\($0.path))"
            }.joined(separator: "\n") + "\nTotal reclaimable: \(total.bytesFormatted)"
        })

        list.append(Tool(
            name: "slim_apps",
            description: "Remove Intel code from selected universal apps (verified copy → re-sign → original to Trash). DESTRUCTIVE: run scan_slim first, show the list to the user, and pass the exact app paths they approved.",
            params: [
                Param("apps", "array", "App bundle paths to slim, exactly as returned by scan_slim", required: true),
                Param("dry_run", "boolean", "Report what would happen without changing anything"),
            ],
            destructive: true
        ) { args, _ in
            guard let requested = strArray(args, "apps"), !requested.isEmpty else {
                throw ToolError(message: "apps required — run scan_slim and pass the exact paths")
            }
            let available = await SlimEngine.scan()
            // Scope params never silently widen (HANDOFF §6.22): unknown paths
            // are an error listing what IS available.
            var picks: [SlimEngine.Candidate] = []
            var unknown: [String] = []
            for path in requested {
                if let match = available.first(where: { $0.path == path }) {
                    picks.append(match)
                } else {
                    unknown.append(path)
                }
            }
            if !unknown.isEmpty {
                throw ToolError(message: """
                not slimmable (not universal, protected, or already slim): \(unknown.joined(separator: ", ")).
                Available: \(available.map(\.path).joined(separator: "\n"))
                """)
            }
            let dryRun = bool(args, "dry_run") ?? false
            let outcomes = await SlimEngine.slim(picks, dryRun: dryRun)
            let saved = outcomes.filter(\.success).reduce(0) { $0 + $1.savedBytes }
            var report = "slim scope: \(picks.map(\.path).joined(separator: ", "))"
            report += "\n" + outcomes.map { "\($0.success ? "✓" : "✗") \($0.name): \($0.message)" }
                .joined(separator: "\n")
            report += "\nreclaimed ~\(saved.bytesFormatted)"
            return report
        })

        // ---- Space hogs (snapshots / Docker / Homebrew / read-only reports) ----
        list.append(Tool(
            name: "scan_space_hogs",
            description: "Report the big system-level space consumers a file scan can't see: APFS/Time Machine local snapshots, Docker disk usage, Homebrew old-version preview, and read-only sizes of iOS backups / Mail / Messages (never deleted). Read-only.",
            params: [], destructive: false
        ) { _, _ in
            var text = ""
            let snapshots = await SnapshotEngine.list()
            text += "APFS local snapshots: \(snapshots.count)\n"
            text += snapshots.prefix(10).map { "  · \($0.id)" }.joined(separator: "\n")
            text += "\n"
            if DockerEngine.installed {
                if let usage = await DockerEngine.usage() {
                    text += "Docker: \(usage.totalBytes.bytesFormatted) total (images \(usage.imagesBytes.bytesFormatted), containers \(usage.containersBytes.bytesFormatted), volumes \(usage.volumesBytes.bytesFormatted), build cache \(usage.cacheBytes.bytesFormatted))\n"
                } else {
                    text += "Docker: installed, daemon not running\n"
                }
            } else {
                text += "Docker: not installed\n"
            }
            if HomebrewEngine.installed {
                if let preview = await HomebrewEngine.preview(), !preview.isEmpty {
                    text += "Homebrew: \(preview.totalBytes.bytesFormatted) reclaimable in \(preview.lines.count) items (brew cleanup)\n"
                } else {
                    text += "Homebrew: nothing to clean\n"
                }
            } else {
                text += "Homebrew: not installed\n"
            }
            for report in SystemHogs.reports() {
                let name = report.kind.rawValue
                if report.needsFullDiskAccess {
                    text += "\(name): needs Full Disk Access to measure (read-only, never deleted)\n"
                } else {
                    text += "\(name): \(report.bytes.bytesFormatted) (read-only, never deleted)\n"
                }
            }
            return text
        })

        list.append(Tool(
            name: "delete_local_snapshots",
            description: "Delete APFS/Time Machine LOCAL snapshots by their exact date tokens from scan_space_hogs (e.g. 2026-10-27-123456). IRREVERSIBLE — removes those restore points. Confirm with the user first.",
            params: [
                Param("dates", "array", "Exact snapshot date tokens, e.g. [\"2026-10-27-123456\"]", required: true),
            ],
            destructive: true
        ) { args, _ in
            guard let dates = strArray(args, "dates"), !dates.isEmpty else {
                throw ToolError(message: "dates required — run scan_space_hogs first and pass exact tokens")
            }
            var removed = 0
            var failures: [String] = []
            for date in dates {
                do {
                    _ = try await SnapshotEngine.delete(date)
                    removed += 1
                } catch {
                    failures.append("\(date): \(error.localizedDescription)")
                }
            }
            HistoryStore.append(CleanRecord(
                date: Date(), sectionTitles: ["Space Hogs"],
                requestedBytes: 0, freedBytes: 0, itemCount: dates.count,
                items: dates.map { date in
                    // Failure strings are "date: message" — prefix match
                    // recovers the per-date success flag for the audit row.
                    let failure = failures.first { $0.hasPrefix(date) }
                    return CleanRecordItem(path: "tmutil deletelocalsnapshots \(date)", bytes: 0,
                                           mode: .permanent, success: failure == nil,
                                           error: failure)
                }, source: .hogs))
            var text = "Deleted \(removed) of \(dates.count) snapshots."
            if !failures.isEmpty { text += "\nFailures:\n" + failures.joined(separator: "\n") }
            return text
        })

        list.append(Tool(
            name: "docker_prune",
            description: "Run `docker system prune -f`: removes STOPPED containers, unused networks, dangling images and build cache. Running containers and volumes are never touched. Confirm with the user first.",
            params: [], destructive: true
        ) { _, _ in
            let output = try await DockerEngine.prune()
            HistoryStore.append(CleanRecord(
                date: Date(), sectionTitles: ["Space Hogs"],
                requestedBytes: 0, freedBytes: 0, itemCount: 1,
                items: [CleanRecordItem(path: "docker system prune", bytes: 0,
                                        mode: .permanent, success: true, error: nil)],
                source: .hogs))
            return output.isEmpty ? "Prune finished — nothing to remove." : output
        })

        list.append(Tool(
            name: "brew_cleanup",
            description: "Run `brew cleanup`: removes old Cellar versions and expired downloads. Rollback means reinstalling. Confirm with the user first.",
            params: [], destructive: true
        ) { _, _ in
            let output = try await HomebrewEngine.run()
            HistoryStore.append(CleanRecord(
                date: Date(), sectionTitles: ["Space Hogs"],
                requestedBytes: 0, freedBytes: 0, itemCount: 1,
                items: [CleanRecordItem(path: "brew cleanup", bytes: 0,
                                        mode: .permanent, success: true, error: nil)],
                source: .hogs))
            return output.isEmpty ? "brew cleanup finished." : output
        })

        // ---- Orphan residue ----
        list.append(Tool(
            name: "scan_orphans",
            description: "Find Library leftovers (caches, preferences, containers…) of apps that are NO LONGER installed. Conservative: Apple items, vendor helpers of installed apps, and anything touched in the last 30 days are excluded. Read-only.",
            params: [], destructive: false
        ) { _, _ in
            let orphans = await OrphanResidueEngine.scan()
            guard !orphans.isEmpty else { return "No orphan residue found." }
            let total = orphans.reduce(0) { $0 + $1.bytes }
            return orphans.map {
                "· [\($0.kind)] \($0.bundleID) — \($0.bytes.bytesFormatted) @ \($0.url.path)"
            }.joined(separator: "\n") + "\nTotal: \(total.bytesFormatted)"
        })

        list.append(Tool(
            name: "clean_orphans",
            description: "Move orphan residue (from scan_orphans) to the Trash by exact path. Recoverable. Confirm with the user first.",
            params: [
                Param("paths", "array", "Exact orphan paths from scan_orphans", required: true),
            ],
            destructive: true
        ) { args, _ in
            guard let requested = strArray(args, "paths"), !requested.isEmpty else {
                throw ToolError(message: "paths required — run scan_orphans and pass the exact paths")
            }
            // Scope params never silently widen (HANDOFF §6.22): unknown
            // paths are an error listing what IS available.
            let available = await OrphanResidueEngine.scan()
            var picks: [OrphanResidueEngine.Candidate] = []
            var unknown: [String] = []
            for path in requested {
                if let match = available.first(where: { $0.url.path == path }) {
                    picks.append(match)
                } else {
                    unknown.append(path)
                }
            }
            if !unknown.isEmpty {
                throw ToolError(message: """
                not orphan residue (still installed, whitelisted, or recently active): \(unknown.joined(separator: ", ")).
                Available: \(available.map { $0.url.path }.joined(separator: "\n"))
                """)
            }
            guard !picks.isEmpty else { return "Nothing left to clean." }
            let outcomes = await OrphanResidueEngine.trash(picks)
            let ok = outcomes.filter(\.success)
            let freed = picks.filter { candidate in
                ok.contains { $0.path == candidate.url.path }
            }.reduce(0) { $0 + $1.bytes }
            HistoryStore.append(CleanRecord(
                date: Date(), sectionTitles: ["Orphan Residue"],
                requestedBytes: picks.reduce(0) { $0 + $1.bytes },
                freedBytes: freed, itemCount: picks.count,
                items: picks.map { candidate in
                    let outcome = outcomes.first { $0.path == candidate.url.path }
                    return CleanRecordItem(path: candidate.url.path, bytes: candidate.bytes,
                                           mode: .trash, success: outcome?.success == true,
                                           error: outcome?.error)
                }, source: .orphans))
            return "Moved \(ok.count) of \(picks.count) orphan items to the Trash (\(freed.bytesFormatted))."
                + (outcomes.count == ok.count ? "" : " \(outcomes.count - ok.count) failed.")
        })

        return list
    }

    /// Scope resolution for scan_clean. Fuzzy on purpose: models pass
    /// near-miss ids ("browser" vs "browsers", display titles, partial
    /// names) and a silent miss used to fall through to a FULL scan.
    /// Matching is case-insensitive with substring containment both ways,
    /// against section ids, section titles, item ids and item names.
    static func resolveItems(sections: [String]?, items: [String]?) -> [CleanItem] {
        if let items, !items.isEmpty {
            return RuleLibrary.sections.flatMap(\.items).filter { item in
                items.contains { matches($0, [item.id, item.name]) }
            }
        }
        if let sections, !sections.isEmpty {
            return RuleLibrary.sections.filter { section in
                sections.contains { matches($0, [section.id, section.title]) }
            }.flatMap(\.items)
        }
        // No explicit scope: honor the user's Clean-page selection (it is
        // persisted now). Only a user who never touched the checkboxes falls
        // back to the rule defaults.
        if CleanSelectionStore.hasCustomSelection {
            return CleanSelectionStore.selectedItems()
        }
        return RuleLibrary.sections.flatMap(\.items).filter(\.defaultSelected)
    }

    private static func matches(_ query: String, _ targets: [String]) -> Bool {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return false }
        return targets.contains { target in
            let t = target.lowercased()
            return t == q || t.contains(q) || q.contains(t)
        }
    }
}
