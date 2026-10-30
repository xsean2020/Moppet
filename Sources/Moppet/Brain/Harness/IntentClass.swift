import Foundation

/// The pet's task domains — the "domain directory" of Harness² (`library.py`),
/// replaced by a rule classifier so retrieval costs zero model calls
/// (design doc §5.5 / §6.1).
///
/// Two call sites, two evidence sources, one enum:
/// - **before** a turn, from the user's words (approximate, cheap);
/// - **after** a turn, from the tools actually called (exact).
enum IntentClass: String, Codable, CaseIterable {
    case cleanup, uninstall, analyze, slim, startup, optimize, status, dev, chat

    /// Tools that identify a domain by what the pet actually did.
    /// Names verified against `Core/ToolRegistry.swift`.
    static let toolDomains: [String: IntentClass] = [
        "scan_clean": .cleanup,
        "execute_clean": .cleanup,
        "list_clean_rules": .cleanup,
        "clean_history": .cleanup,
        "scan_orphans": .cleanup,
        "clean_orphans": .cleanup,
        "docker_prune": .cleanup,
        "brew_cleanup": .cleanup,
        "whitelist_list": .cleanup,
        "whitelist_add": .cleanup,
        "whitelist_remove": .cleanup,
        "uninstall_app": .uninstall,
        "list_apps": .uninstall,
        "app_related_files": .uninstall,
        "analyze_disk": .analyze,
        "find_large_files": .analyze,
        "scan_space_hogs": .analyze,
        "scan_slim": .slim,
        "slim_apps": .slim,
        "scan_launch_items": .startup,
        "set_launch_item_enabled": .startup,
        "optimize_catalog": .optimize,
        "run_optimize": .optimize,
        "disk_status": .status,
        "system_status": .status,
        "safety_check": .status,
        "find_project_artifacts": .dev,
        "purge_artifacts": .dev,
    ]

    /// Generic tools that *can* mean dev work but also appear inside every
    /// other domain (a cleanup turn reads files too). Weighted half so one
    /// `read_file` never outvotes a real domain tool, and never outvotes the
    /// user's own words.
    ///
    /// **`use_skill` / `recall` are deliberately absent**: they are meta-tools
    /// — the pet reading its own harness — and say nothing about what the user
    /// wanted. Counting them as `.chat` made every turn that consulted a skill
    /// classify as chit-chat, which silently mis-filed the outcomes that the
    /// whole learning loop is built on (found by the end-to-end smoke).
    static let genericToolDomains: [String: IntentClass] = [
        "shell": .dev,
        "apply_patch": .dev,
        "exec_command": .dev,
        "write_stdin": .dev,
    ]

    /// Keyword table — deliberately small and bilingual. Order matters: the
    /// first class whose keyword appears wins, so specific beats generic.
    static let keywords: [(IntentClass, [String])] = [
        (.uninstall, ["卸载", "uninstall", "残留", "residue", "删掉应用", "remove app"]),
        (.cleanup, ["清理", "清一下", "清掉", "缓存", "垃圾", "clean", "cache", "junk", "storage"]),
        (.slim, ["瘦身", "slim", "压缩", "strip", "裁掉", "binary"]),
        (.startup, ["启动项", "开机", "自启", "login item", "launch agent", "startup"]),
        (.analyze, ["分析", "看看哪里占", "磁盘占用", "analyze", "disk usage", "大文件", "largest"]),
        (.optimize, ["优化", "内存", "optimize", "memory", "ram"]),
        (.status, ["状态", "健康", "status", "health", "cpu"]),
        (.dev, ["代码", "编译", "build", "git", "脚本", "script", "工程", "repo"]),
    ]

    /// The user's words alone, or nil when nothing matches. Exposed because
    /// `DecisionRouter` needs to know whether the rule tier is *confident*
    /// (a keyword hit) or merely defaulting (§5.11 D1: "规则，模糊时小模型").
    static func keywordMatch(_ text: String) -> IntentClass? {
        let lowered = text.lowercased()
        for (intent, words) in keywords where words.contains(where: { lowered.contains($0) }) {
            return intent
        }
        return nil
    }

    /// Classify from the user's text, optionally biased by the tools already
    /// called this session (a mid-conversation "then delete it" inherits the
    /// domain of the turn before it).
    static func classify(
        text: String,
        tools: [String] = [],
        previous: IntentClass? = nil
    ) -> IntentClass {
        // 1. Tools win: what it DID is stronger evidence than what it said.
        var counts: [IntentClass: Int] = [:]
        for tool in tools {
            if let domain = toolDomains[tool] { counts[domain, default: 0] += 2 }
        }
        for tool in tools {
            if let domain = genericToolDomains[tool] { counts[domain, default: 0] += 1 }
        }
        // Ties resolve by `CaseIterable` order so the answer is deterministic
        // — `max(by:)` alone returns an arbitrary one of the maxima.
        let ranked = counts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value
                : order(of: lhs.key) > order(of: rhs.key)
        }
        if let best = ranked, best.value >= 2 { return best.key }

        // 2. The user's words.
        if let matched = keywordMatch(text) { return matched }

        // 3. Continue the session's domain, else chat.
        return previous ?? .chat
    }

    /// Stable tie-breaker order (declaration order, most specific first).
    private static func order(of intent: IntentClass) -> Int {
        allCases.firstIndex(of: intent) ?? allCases.count
    }
}
