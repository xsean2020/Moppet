import Foundation

/// A reusable workflow, loaded on demand — the harness component with the best
/// cost/benefit ratio (design doc §5.4). Only `name` + `description` are
/// always visible; the body costs nothing until `use_skill` reads it.
struct Skill: Equatable {
    var name: String
    var description: String
    var body: String
    var path: String { "\(HarnessSurface.skillDir)/\(name)/SKILL.md" }
}

enum SkillCatalog {

    static func skills(tree: HarnessSurface.Tree? = nil) -> [Skill] {
        let loaded = tree ?? HarnessStore.load()
        return HarnessSurface.skillNames(in: loaded).compactMap { name in
            guard let text = loaded["\(HarnessSurface.skillDir)/\(name)/SKILL.md"] else { return nil }
            return parse(name: name, text: text)
        }
    }

    static func parse(name: String, text: String) -> Skill? {
        let parsed = Frontmatter.parse(text)
        let description = parsed.fields["description"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !description.isEmpty, !parsed.body.isEmpty else { return nil }
        // `name:` is optional but overrides the directory at load time; a
        // mismatch silently breaks every trigger line, so trust the directory.
        return Skill(name: name, description: description, body: parsed.body)
    }

    /// The always-on advertisement: one line per skill, rendered into
    /// `tool_guidance.md`'s `{{skills}}` placeholder at compose time, so the
    /// list can never go stale (design doc §5.4).
    static func advertisement(tree: HarnessSurface.Tree) -> String {
        let all = skills(tree: tree)
        guard !all.isEmpty else { return "（暂无技能。）" }
        return all
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }

    /// `use_skill` backend. Returns the body, or an actionable error.
    static func load(name: String) -> String {
        guard let skill = skills().first(where: { $0.name == name }) else {
            let available = skills().map(\.name).joined(separator: ", ")
            return "error: no skill named '\(name)'. Available: \(available.isEmpty ? "(none)" : available)"
        }
        return "# \(skill.name)\n\n\(skill.body)"
    }

    /// Install or replace a skill. Human- or evolver-authored; the caller is
    /// responsible for validation before this is allowed to land in `active/`.
    @discardableResult
    static func install(_ skill: Skill) -> Bool {
        guard HarnessSurface.isValidName(skill.name),
              !skill.description.trimmingCharacters(in: .whitespaces).isEmpty,
              !skill.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let text = Frontmatter.render(fields: [
            ("name", skill.name),
            ("description", skill.description),
        ], body: skill.body)
        return HarnessStore.writeFile(skill.path, text)
    }

    static func remove(name: String) -> Bool {
        HarnessStore.deleteFile("\(HarnessSurface.skillDir)/\(name)/SKILL.md")
    }
}
