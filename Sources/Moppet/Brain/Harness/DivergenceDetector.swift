import Foundation

/// Cross-session divergence: the one idea from Harness² that changes *what* the
/// evolver fixes (design doc §1.6b / §6.5).
///
/// Behaviour that is identical across sessions is already determined by the
/// harness. Behaviour that **split** is a decision the harness left to chance —
/// and that split, repeated across sessions, is stronger and less overfittable
/// evidence than any single failure.
enum DivergenceDetector {

    /// One route-level action, with its argument *shape* (values erased).
    struct RouteStep: Equatable {
        let line: Int
        let tool: String
        let shape: String
        let failed: Bool
    }

    struct Branch: Equatable {
        let shape: String
        let sessions: [String]
        let badSessions: [String]
        var badRatio: Double {
            sessions.isEmpty ? 0 : Double(badSessions.count) / Double(sessions.count)
        }
    }

    struct Divergence: Equatable {
        let prefix: String
        let branches: [Branch]
        let weight: Double
    }

    /// Tools that choose a *route*. Reads and image views are observations, not
    /// decisions, and would drown the signal in noise.
    static let routeTools: Set<String> = [
        "scan_clean", "execute_clean", "uninstall_app", "app_related_files",
        "scan_slim", "slim_apps", "scan_launch_items", "set_launch_item_enabled",
        "find_project_artifacts", "purge_artifacts", "request_user_input",
        "apply_patch", "shell", "exec_command", "clean_orphans", "docker_prune",
        "brew_cleanup", "whitelist_add",
    ]

    /// `scan_clean` + `{"sections":[...],"items":[...]}` → `scan_clean{sections,items}`.
    /// Values are erased on purpose: we compare *shapes*, not arguments.
    static func shape(tool: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return tool
        }
        let keys = object.keys.sorted().joined(separator: ",")
        return keys.isEmpty ? tool : "\(tool){\(keys)}"
    }

    static func steps(sessionID: String) -> [RouteStep] {
        let records = BrainRollout.records(sessionID: sessionID)
        var out: [RouteStep] = []
        for (index, entry) in records.enumerated() {
            guard case .responseItem(.functionCall(_, let name, let arguments)) = entry.record,
                  routeTools.contains(name) else { continue }
            // A failure is the next output for this call starting with "error:".
            var failed = false
            if index + 1 < records.count,
               case .responseItem(.functionCallOutput(_, let output)) = records[index + 1].record {
                failed = output.hasPrefix("error:")
            }
            out.append(RouteStep(
                line: entry.line, tool: name,
                shape: shape(tool: name, arguments: arguments), failed: failed))
        }
        return out
    }

    /// Compare the first `depth` steps of every session; wherever two sessions
    /// take a different next step from the same prefix, that is a divergence.
    ///
    /// **A split needs corroboration on both sides.** A lone session that went
    /// off-script is not a divergence, it is an outlier — and reporting it as
    /// one is exactly the overfitting §1.3(c) forbids ("one failure in one
    /// session" is the weak evidence this whole mechanism exists to replace).
    /// So every branch must be carried by at least `minBranchSessions`.
    static func detect(
        sessions: [String],
        badSessions: Set<String> = [],
        depth: Int = 4,
        limit: Int = 3,
        minBranchSessions: Int = 2
    ) -> [Divergence] {
        let perSession = sessions.map { (id: $0, steps: steps(sessionID: $0)) }
            .filter { !$0.steps.isEmpty }
        guard perSession.count >= 3 else { return [] }

        var found: [String: (branches: [Branch], total: Int)] = [:]
        for level in 0..<depth {
            var groups: [String: [(session: String, next: RouteStep)]] = [:]
            for entry in perSession where entry.steps.count > level {
                let prefix = entry.steps.prefix(level).map(\.shape).joined(separator: " → ")
                groups[prefix, default: []].append((entry.id, entry.steps[level]))
            }
            for (prefix, items) in groups {
                guard items.count >= 3 else { continue }
                var byShape: [String: [(String, Bool)]] = [:]
                for item in items {
                    byShape[item.next.shape, default: []].append((item.session, badSessions.contains(item.session)))
                }
                guard byShape.count >= 2 else { continue }
                // Both sides must be corroborated — one outlier is not a route.
                guard byShape.values.allSatisfy({ $0.count >= minBranchSessions }) else { continue }
                let branches = byShape.map { shape, members in
                    Branch(
                        shape: shape,
                        sessions: members.map(\.0),
                        badSessions: members.filter(\.1).map(\.0))
                }.sorted { $0.sessions.count > $1.sessions.count }
                found[prefix] = (branches, items.count)
            }
        }

        return found.map { prefix, value -> Divergence in
            let bad = Set(value.branches.flatMap(\.badSessions)).count
            let badRatio = Double(bad) / Double(value.total)
            // §6.5: w = 会话数 × (bad 占比 + 0.3 × 混合占比). A branch that
            // contains BOTH good and bad sessions is "mixed" — the split itself
            // is not yet decisive there, so it adds a smaller bonus than a
            // uniformly-bad side.
            let mixed = value.branches
                .filter { !$0.badSessions.isEmpty && $0.badSessions.count < $0.sessions.count }
                .reduce(0) { $0 + $1.sessions.count }
            let mixedRatio = Double(mixed) / Double(value.total)
            // A split whose losing side is entirely bad sessions is stronger:
            // the evidence has already falsified one branch.
            let falsified = value.branches.contains { branch in
                !branch.badSessions.isEmpty && branch.badSessions.count == branch.sessions.count
            }
            var weight = Double(value.total) * (badRatio + 0.3 * mixedRatio)
            if falsified { weight *= 2 }
            return Divergence(prefix: prefix, branches: value.branches, weight: weight)
        }
        .sorted { $0.weight > $1.weight }
        .prefix(limit)
        .map { $0 }
    }

    /// One-line-per-branch rendering for the editor's evidence block.
    static func render(_ divergences: [Divergence]) -> String {
        guard !divergences.isEmpty else { return "（没有检出跨会话分歧。）" }
        var lines: [String] = []
        for divergence in divergences {
            lines.append("- 分歧点 `\(divergence.prefix.isEmpty ? "(会话起点)" : divergence.prefix)` "
                + "（权重 \(String(format: "%.1f", divergence.weight))）：")
            for branch in divergence.branches {
                let bad = branch.badSessions.isEmpty ? "" : "，其中 \(branch.badSessions.count) 个会话是 bad"
                lines.append("    · \(branch.shape) — \(branch.sessions.count) 个会话\(bad)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
