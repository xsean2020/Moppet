import Foundation

/// The editable surface of the pet harness — the Swift port of
/// `harness2/core/tree.py:SurfaceSpec` + `is_allowed`.
///
/// One rule, stated once: **a path is on the surface or it is not**, and the
/// answer is a pure predicate (`isAllowed` never throws, never touches disk).
/// Everything the model may rewrite goes through here; everything that decides
/// what the pet is *allowed to do* (SafetyGuard / BrainSandbox / ToolRegistry)
/// is deliberately absent from this list — that is the constitution in §3.3 of
/// `docs/BRAIN-HARNESS-DESIGN.md`.
enum HarnessSurface {

    /// The tree the harness is made of. `[relative path: file body]`.
    typealias Tree = [String: String]

    // MARK: - Always-on files (paid for on EVERY turn)

    /// Order matters: this is the assembly order in `PetHarness.compose`.
    /// `systemprompt.md` carries the role and the `{{environment}}` placeholder;
    /// `guardrails.md` carries the standing rules.
    static let alwaysOn: [String] = [
        "systemprompt.md",
        "guardrails.md",
        "tool_guidance.md",
        "memory/INDEX.md",
    ]

    /// Per-file character caps. Over cap == validation failure (V1), never a
    /// silent truncation: the whole point is that the budget is visible.
    static let caps: [String: Int] = [
        "systemprompt.md": 2_400,
        "guardrails.md": 1_800,
        "tool_guidance.md": 1_200,
        "memory/INDEX.md": 1_200,
    ]

    /// Total always-on budget (~1,650 tokens). See design doc §5.1.
    static let totalCap = 6_600

    static let skillDir = "skills"
    static let factDir = "memory/facts"
    static let scriptDir = "scripts"

    // MARK: - Path rules

    /// `[a-z0-9][a-z0-9_-]*` — same shape as `tree.py:_NAME`.
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase || first.isNumber else {
            return false
        }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLowercase || ch.isNumber || ch == "_" || ch == "-")
        }
    }

    /// Normalise a relative path, rejecting escapes BEFORE it is joined to a
    /// directory (port of `tree.normalize_rel`).
    static func normalize(_ rel: String) throws -> String {
        var r = rel.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        if r.hasPrefix("/") || r.split(separator: "/").contains(where: { $0 == ".." }) {
            throw HarnessPathError.escapes(rel)
        }
        while r.hasPrefix("./") { r.removeFirst(2) }
        while r.hasSuffix("/") { r.removeLast() }
        return r
    }

    /// Whether this path may be read into / written from the harness tree.
    /// A predicate: it never raises (port of `tree.is_allowed`).
    static func isAllowed(_ rel: String) -> Bool {
        guard let r = try? normalize(rel), !r.isEmpty else { return false }
        if alwaysOn.contains(r) { return true }

        // skills/<name>/SKILL.md  and  skills/<name>/scripts/<file>.sh
        if r.hasPrefix("\(skillDir)/") {
            let rest = String(r.dropFirst(skillDir.count + 1))
            if let name = rest.split(separator: "/").first.map(String.init),
               isValidName(name) {
                if rest == "\(name)/SKILL.md" { return true }
                if rest.hasPrefix("\(name)/scripts/") {
                    let file = String(rest.dropFirst("\(name)/scripts/".count))
                    return !file.isEmpty && !file.contains("/") && file.hasSuffix(".sh")
                }
            }
            return false
        }

        // memory/facts/<slug>.md
        if r.hasPrefix("\(factDir)/") {
            let file = String(r.dropFirst(factDir.count + 1))
            guard file.hasSuffix(".md"), !file.contains("/") else { return false }
            return isValidName(String(file.dropLast(3)))
        }

        // scripts/<name>.sh — human-written only (§3.3: the model never ships code)
        if r.hasPrefix("\(scriptDir)/") {
            let file = String(r.dropFirst(scriptDir.count + 1))
            guard file.hasSuffix(".sh"), !file.contains("/") else { return false }
            return isValidName(String(file.dropLast(3)))
        }

        return false
    }

    // MARK: - Census helpers

    static func skillNames(in tree: Tree) -> [String] {
        let prefix = "\(skillDir)/"
        return Set(tree.keys.compactMap { path -> String? in
            guard path.hasPrefix(prefix), path.hasSuffix("/SKILL.md") else { return nil }
            let rest = path.dropFirst(prefix.count).dropLast("/SKILL.md".count)
            return rest.contains("/") ? nil : String(rest)
        }).sorted()
    }

    static func factSlugs(in tree: Tree) -> [String] {
        let prefix = "\(factDir)/"
        return Set(tree.keys.compactMap { path -> String? in
            guard path.hasPrefix(prefix), path.hasSuffix(".md") else { return nil }
            let slug = String(path.dropFirst(prefix.count).dropLast(3))
            return slug.contains("/") ? nil : slug
        }).sorted()
    }

    static func alwaysOnChars(_ tree: Tree) -> Int {
        alwaysOn.reduce(0) { sum, path in
            sum + (tree[path]?.count ?? 0)
        }
    }
}

enum HarnessPathError: LocalizedError {
    case escapes(String)

    var errorDescription: String? {
        switch self {
        case .escapes(let path):
            return "path escapes the harness: \(path)"
        }
    }
}
