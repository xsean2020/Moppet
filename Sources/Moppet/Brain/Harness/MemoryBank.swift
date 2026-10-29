import Foundation

/// One durable fact about this user or this machine (design doc §5.3).
///
/// Facts are the "remembered" layer: index always-on, body on demand. The
/// discipline that keeps them from poisoning the pet lives in `MemoryBank.write`
/// — source required, one file per slug, hard cap with LRU eviction.
struct MemoryFact: Equatable {
    var slug: String
    var cue: String
    var fact: String
    var aliases: [String] = []
    var source: String
    var confidence: String = "medium"
    var updated: Date = Date()

    var path: String { "\(HarnessSurface.factDir)/\(slug).md" }

    var candidate: CueMatcher.Candidate {
        CueMatcher.Candidate(
            id: slug, cue: cue, aliases: aliases,
            confidence: confidence, updated: updated)
    }
}

enum MemoryBank {

    /// Hard cap on facts. Beyond this the index alone would eat the always-on
    /// budget, and retrieval precision collapses (design doc §5.3).
    static let cap = 40

    // MARK: - Read

    static func facts(tree: HarnessSurface.Tree? = nil) -> [MemoryFact] {
        let loaded = tree ?? HarnessStore.load()
        return HarnessSurface.factSlugs(in: loaded).compactMap { slug in
            guard let body = loaded["\(HarnessSurface.factDir)/\(slug).md"] else { return nil }
            return parse(slug: slug, text: body)
        }.sorted { $0.updated > $1.updated }
    }

    static func parse(slug: String, text: String) -> MemoryFact? {
        let parsed = Frontmatter.parse(text)
        let cue = parsed.fields["cue"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !cue.isEmpty, !parsed.body.isEmpty else { return nil }
        return MemoryFact(
            slug: slug,
            cue: cue,
            fact: parsed.body,
            aliases: splitAliases(parsed.fields["aliases"] ?? ""),
            source: parsed.fields["source"] ?? "",
            confidence: parsed.fields["confidence"] ?? "medium",
            updated: Frontmatter.date(parsed.fields["updated"] ?? "") ?? Date()
        )
    }

    static func splitAliases(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Write

    /// Write one fact. Returns false when the input breaks a discipline:
    /// no source, no cue, or a slug that is not a valid component name.
    @discardableResult
    static func write(_ fact: MemoryFact, evict: Bool = true) -> Bool {
        guard HarnessSurface.isValidName(fact.slug),
              !fact.cue.trimmingCharacters(in: .whitespaces).isEmpty,
              !fact.source.trimmingCharacters(in: .whitespaces).isEmpty,
              !fact.fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let body = Frontmatter.render(fields: [
            ("cue", fact.cue),
            ("aliases", fact.aliases.joined(separator: ", ")),
            ("source", fact.source),
            ("confidence", fact.confidence),
            ("updated", Frontmatter.iso(fact.updated)),
        ], body: fact.fact)

        guard HarnessStore.writeFile(fact.path, body) else { return false }
        rebuildIndex()
        if evict { evictIfNeeded() }
        return true
    }

    static func remove(slug: String) -> Bool {
        let removed = HarnessStore.deleteFile("\(HarnessSurface.factDir)/\(slug).md")
        rebuildIndex()
        return removed
    }

    /// The index is derived data: it can always be rebuilt from the facts
    /// (design doc §5.12, I3 — `library.rebuild_index`).
    @discardableResult
    static func rebuildIndex() -> String {
        let text = indexText()
        HarnessStore.writeFile("memory/INDEX.md", text)
        return text
    }

    static func indexText(facts: [MemoryFact]? = nil) -> String {
        let entries = facts ?? self.facts()
        var lines = ["# 记忆索引", ""]
        if entries.isEmpty {
            lines.append("（暂无记忆。需要时用 recall 查询。）")
        } else {
            for fact in entries {
                let cue = fact.cue.count > 28 ? String(fact.cue.prefix(28)) + "…" : fact.cue
                lines.append("- \(cue) → \(fact.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Retrieval (L1, zero model calls)

    static func recall(query: String, limit: Int = 2) -> String {
        let candidates = facts().map(\.candidate)
        let hits = CueMatcher.top(candidates, query: query, limit: limit)
        guard !hits.isEmpty else { return "没有相关记忆。" }
        let byID = Dictionary(uniqueKeysWithValues: facts().map { ($0.slug, $0) })
        let lines = hits.compactMap { candidate -> String? in
            guard let fact = byID[candidate.id] else { return nil }
            recordHit(candidate.id)
            let source = fact.source.isEmpty ? "" : "（来源：\(fact.source)）"
            return "【\(fact.cue)】\(fact.fact)\(source)"
        }
        return lines.isEmpty ? "没有相关记忆。" : lines.joined(separator: "\n")
    }

    // MARK: - LRU

    private static var hitsURL: URL { GrowthPaths.root.appendingPathComponent("memory-hits.json") }

    static func hits() -> [String: Int] {
        guard let text = GrowthPaths.read(hitsURL),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func recordHit(_ slug: String) {
        var table = hits()
        table[slug, default: 0] += 1
        if let data = try? JSONEncoder().encode(table) {
            GrowthPaths.write(String(decoding: data, as: UTF8.self), to: hitsURL)
        }
    }

    /// Evict least-recently-recalled, then oldest. Called after every write.
    static func evictIfNeeded() {
        let all = facts()
        guard all.count > cap else { return }
        let table = hits()
        let victims = all
            .sorted { lhs, rhs in
                let lh = table[lhs.slug] ?? 0, rh = table[rhs.slug] ?? 0
                if lh != rh { return lh < rh }
                return lhs.updated < rhs.updated
            }
            .prefix(all.count - cap)
        for victim in victims { _ = HarnessStore.deleteFile(victim.path) }
        rebuildIndex()
    }
}
