import Foundation

/// Validation is a gate, not a suggestion (design doc §5.2, port of `tree.validate`):
/// collect **every** problem, describe each in prose the editor can act on, and
/// never silently repair. `autotrigger` is the one exception — it makes "every
/// skill must be named" an invariant instead of a rule you can forget.
enum HarnessValidator {

    struct Census: Equatable {
        let files: Int
        let alwaysOnChars: Int
        let skills: Int
        let facts: Int
    }

    struct Violation: LocalizedError {
        let problems: [String]
        var errorDescription: String? {
            problems.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
    }

    // MARK: - Autotrigger (repair before validate)

    /// Give every skill a trigger line in the always-on text; return the names
    /// repaired. A line that would push the body over the cap is skipped, not
    /// forced — over-cap is a failure the editor must resolve.
    @discardableResult
    static func autotrigger(_ tree: inout HarnessSurface.Tree) -> [String] {
        // A `{{skills}}` placeholder already names every skill; nothing to do.
        let body = PetHarness.alwaysOnText(tree)
        guard !body.contains(PetHarness.skillsPlaceholder) else { return [] }

        var repaired: [String] = []
        for skill in SkillCatalog.skills(tree: tree) {
            if body.contains(skill.name) { continue }
            let line = "当匹配「\(skill.description)」的情形时，加载 \(skill.name) 技能。"
            let current = tree["systemprompt.md"] ?? ""
            let candidate = current.isEmpty ? line : current + "\n" + line
            if HarnessSurface.alwaysOnChars(tree) + line.count + 1 > HarnessSurface.totalCap {
                continue
            }
            tree["systemprompt.md"] = candidate
            repaired.append(skill.name)
        }
        return repaired
    }

    // MARK: - Validate

    static func validate(_ tree: HarnessSurface.Tree) throws -> Census {
        var problems: [String] = []

        // V1 — always-on budget (per file, then total).
        for (path, cap) in HarnessSurface.caps {
            let size = tree[path]?.count ?? 0
            if size > cap {
                problems.append(
                    "\(path) 有 \(size) 字符，超过 \(cap) 上限。常驻文本每一轮都在抢输出预算——"
                    + "要加内容就得先砍掉别的内容（TRIM，不要清空）。")
            }
        }
        let total = HarnessSurface.alwaysOnChars(tree)
        if total > HarnessSurface.totalCap {
            problems.append(
                "常驻总量 \(total) 字符，超过 \(HarnessSurface.totalCap) 上限；"
                + "优先把内容移到技能（按需加载，常驻成本近零）。")
        }

        // V9 — an empty always-on file is a harness that does not exist.
        for path in HarnessSurface.alwaysOn {
            let body = tree[path]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.isEmpty {
                problems.append(
                    "\(path) 是空的。常驻文件不得为空——要付账就 TRIM，永远不要清空"
                    + "（空常驻等于没有 harness）。")
            }
        }

        // V2/V3/V4 — skills.
        let body = PetHarness.alwaysOnText(tree)
        let hasSkillPlaceholder = body.contains(PetHarness.skillsPlaceholder)
        for name in HarnessSurface.skillNames(in: tree) {
            let path = "\(HarnessSurface.skillDir)/\(name)/SKILL.md"
            let text = tree[path] ?? ""
            let parsed = Frontmatter.parse(text)
            if (parsed.fields["description"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append(
                    "\(path) 缺少 frontmatter `description:`——没有描述的技能会在加载时被静默丢弃。")
            }
            if !hasSkillPlaceholder, !body.contains(name) {
                problems.append(
                    "技能 '\(name)' 从未在常驻文本里被点名，模型永远不会打开它（死重）。"
                    + "在 systemprompt.md 里加一行触发语，或恢复 tool_guidance.md 的 \(PetHarness.skillsPlaceholder) 占位符。")
            }
            // V4 — a skill may not invoke a helper it does not ship.
            for ref in scriptReferences(in: text) {
                let own = "\(HarnessSurface.skillDir)/\(name)/scripts/\(ref)"
                let loose = "\(HarnessSurface.scriptDir)/\(ref)"
                if tree[own] == nil && tree[loose] == nil {
                    problems.append("\(path) 调用了 `scripts/\(ref)`，但该脚本不在 harness 里。")
                }
            }
        }

        // V5 — path escape (the surface already rejects, this is the tripwire).
        for path in tree.keys {
            if (try? HarnessSurface.normalize(path)) == nil || !HarnessSurface.isAllowed(path) {
                problems.append("`\(path)` 不在可编辑面上：路径逃逸或组件名不合规，写入会被丢弃。")
            }
        }

        // V6 — a fact without a cue is unreachable.
        for slug in HarnessSurface.factSlugs(in: tree) {
            let text = tree["\(HarnessSurface.factDir)/\(slug).md"] ?? ""
            let cue = Frontmatter.parse(text).fields["cue"]?.trimmingCharacters(in: .whitespaces) ?? ""
            if cue.isEmpty {
                problems.append(
                    "memory/facts/\(slug).md 缺少 `cue:`——没有 cue 就检索不到，等于没记。")
            }
        }

        // V7 is enforced where lessons are written (`LessonLibrary.write`), and
        // V8 (version monotonicity) lives in the versions manifest — the tree
        // itself carries no version file, by design.

        if !problems.isEmpty { throw Violation(problems: problems) }

        let census = PetHarness.census(tree)
        return Census(
            files: census.files,
            alwaysOnChars: census.alwaysOnChars,
            skills: census.skills,
            facts: census.facts)
    }

    /// `scripts/foo.sh` mentions inside a skill body.
    static func scriptReferences(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"scripts/([A-Za-z0-9_.\-]+\.sh)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    // MARK: - V7 helper

    /// A lesson must generalise: a cue or lesson containing this session's
    /// numbers, paths or ids is overfitting (design doc §5.6).
    /// Returns the offending snippet, or nil when clean.
    static func taskFact(in text: String) -> String? {
        let patterns = [
            #"\d+(\.\d+)?\s*(GB|MB|KB|TB|gb|mb|kb|tb)"#,
            #"/Users/[^\s，。）)]+"#,
            #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}"#,
            #"session \d{4}-\d{2}-\d{2}T"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return String(text[range])
            }
        }
        return nil
    }
}
