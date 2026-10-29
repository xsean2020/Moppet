import Foundation

/// The harness as DATA — the Swift port of `harness2/core/tree.py`.
///
/// P0 scope (design doc §9): the tree model, the seed, the composer and the
/// degradation contract. Skills / memory / lessons arrive in P1+; the surface
/// already accepts their paths so adding them needs no change here.
///
/// The seed is the current hard-coded `BrainInstructions.systemPrompt` text,
/// migrated **verbatim** with exactly two deliberate edits (design doc §14):
///   1. the duplicated rule number `7` becomes `7 / 8 / 9`;
///   2. the environment block becomes the `{{environment}}` placeholder, so the
///      dynamic part (cwd / sandbox / approval) is injected at runtime and never
///      lives on the editable surface.
enum PetHarness {

    typealias Tree = HarnessSurface.Tree

    static let namePlaceholder = "{{name}}"
    static let environmentPlaceholder = "{{environment}}"
    static let skillsPlaceholder = HarnessSeeds.skillsPlaceholder

    // MARK: - Seed (the compiled-in truth; degradation never returns empty)

    static let seedSystemPrompt = """
    You are \(namePlaceholder) — a desktop pet with a coding & system agent brain built after OpenAI Codex, living inside a macOS desktop-cleaning app. You can run shell commands (one-shot or resumable exec sessions), read and edit files with apply_patch, view images, make plans, ask the user structured questions, call the app's built-in cleaning/analysis tools, and use connected MCP servers.

    \(environmentPlaceholder)
    """

    static let seedGuardrails = """
    Operating rules:
    1. Inspect before you act: read files / run read-only commands first.
    2. Use apply_patch for file edits — never shell heredocs for writing files.
    3. Network is available (curl, web checks) and non-delete shell commands run freely: if one fails on a sandbox violation it is auto-escalated and rerun without the sandbox — no user prompt needed.
    4. Deleting (rm family, find -delete, git clean, trash) ALWAYS asks the user first — never try to work around that with other commands.
    5. For cleaning tasks prefer the built-in tools (scan_clean first, show results, then execute_clean after the user approves).
    6. scan_clean MUST honor the user's scope: if they name a category, app or vendor (e.g. "only browser"), pass sections/items accordingly and never omit both arguments — omitting means a FULL sweep. Report the scanned scope back to the user.
    7. Long-running commands: use exec_command (resumable) and poll with write_stdin instead of blocking the turn with huge timeouts.
    8. request_user_input is for genuine decisions only — never quiz the user about things you can determine yourself.
    9. Keep responses concise. Answer in the user's language. Stay in character.
    """

    /// P0's two files carry the legacy text verbatim; P1 adds the tool guidance,
    /// the memory index and five skills (design doc §5.4). `compose` renders the
    /// `{{skills}}` placeholder from whatever skills the tree actually holds, so
    /// the advertisement can never go stale.
    static let seed: Tree = {
        var out: Tree = [
            "systemprompt.md": seedSystemPrompt,
            "guardrails.md": seedGuardrails,
        ]
        out.merge(HarnessSeeds.tree) { _, new in new }
        return out
    }()

    // MARK: - Compose

    /// Assemble the system prompt from the tree.
    ///
    /// Order (design doc §5.1): persona → always-on files in `HarnessSurface.alwaysOn`
    /// order → nothing else. The environment block is injected here, at the
    /// placeholder, so the editable files stay free of machine state.
    static func compose(
        tree: Tree,
        cwd: String,
        sandboxMode: BrainSandboxMode,
        approvalPolicy: BrainApprovalPolicy,
        networkAccess: Bool,
        name: String = PetIdentity.name,
        persona: String? = PetIdentity.persona
    ) -> String {
        let env = environmentBlock(
            cwd: cwd, sandboxMode: sandboxMode,
            approvalPolicy: approvalPolicy, networkAccess: networkAccess)

        var parts: [String] = []
        if let persona, !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("# Persona (user-defined soul)\n\(persona)")
        }
        let skillList = SkillCatalog.advertisement(tree: tree)
        for path in HarnessSurface.alwaysOn {
            guard let raw = tree[path]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            let body = raw
                .replacingOccurrences(of: namePlaceholder, with: name)
                .replacingOccurrences(of: environmentPlaceholder, with: env)
                .replacingOccurrences(of: skillsPlaceholder, with: skillList)
            parts.append(body)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The dynamic block: identical byte-for-byte to the legacy interpolation.
    static func environmentBlock(
        cwd: String,
        sandboxMode: BrainSandboxMode,
        approvalPolicy: BrainApprovalPolicy,
        networkAccess: Bool
    ) -> String {
        let network = sandboxMode == .workspaceWrite
            ? " (network \(networkAccess ? "allowed" : "denied"))"
            : ""
        return """
        Environment:
        - cwd: \(cwd)
        - sandbox: \(sandboxMode.rawValue)\(network)
        - approval policy: \(approvalPolicy.rawValue)
        """
    }

    /// The concatenated always-on text, placeholders intact — what the
    /// validator reasons about (rendering would hide a missing `{{skills}}`).
    static func alwaysOnText(_ tree: Tree) -> String {
        HarnessSurface.alwaysOn.compactMap { tree[$0] }.joined(separator: "\n\n")
    }

    /// Per-file degradation: a missing or emptied always-on file falls back to
    /// its seed body, so deleting one file degrades that file — not the prompt.
    static func effectiveTree(_ tree: Tree) -> Tree {
        var out = tree
        for path in HarnessSurface.alwaysOn {
            let body = out[path]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.isEmpty, let seeded = seed[path] {
                out[path] = seeded
            }
        }
        return out
    }

    // MARK: - Disk

    /// Read every file on the surface under `dir`. Off-surface files are ignored
    /// (never loaded, never rewritten) — the same boundary `read_tree` enforces.
    static func read(from dir: URL) -> Tree {
        var out: Tree = [:]
        guard FileManager.default.fileExists(atPath: dir.path) else { return out }
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return out }

        let root = dir.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root) else { continue }
            var rel = String(full.dropFirst(root.count))
            while rel.hasPrefix("/") { rel.removeFirst() }
            guard HarnessSurface.isAllowed(rel) else { continue }
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out[rel] = body
        }
        return out
    }

    /// Materialise a tree exactly: surface files not in `tree` are removed,
    /// off-surface files are preserved (port of `tree.write_tree`).
    static func write(_ tree: Tree, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            let root = dir.standardizedFileURL.path
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path
                var rel = String(full.dropFirst(root.count))
                while rel.hasPrefix("/") { rel.removeFirst() }
                if HarnessSurface.isAllowed(rel) { try? fm.removeItem(at: url) }
            }
        }

        for (rel, body) in tree {
            let target = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try body.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Census

    struct Census {
        let files: Int
        let alwaysOnChars: Int
        let skills: Int
        let facts: Int
    }

    static func census(_ tree: Tree) -> Census {
        Census(
            files: tree.count,
            alwaysOnChars: HarnessSurface.alwaysOnChars(tree),
            skills: HarnessSurface.skillNames(in: tree).count,
            facts: HarnessSurface.factSlugs(in: tree).count
        )
    }
}
