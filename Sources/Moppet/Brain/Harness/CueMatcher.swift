import Foundation

/// Zero-dependency retrieval: explicit aliases + character bigrams.
///
/// Design doc §5.11.4 measured the two system embeddings on this machine and
/// both were unusable for Chinese ("只清一下浏览器缓存" scored 0.96 against a
/// poem and 0.95 against the matching cue). Since we author every cue, the
/// honest solution is to hang the synonyms on it and match deterministically.
enum CueMatcher {

    /// One retrievable thing: a memory fact or a lesson.
    struct Candidate {
        let id: String
        let cue: String
        var aliases: [String] = []
        var confidence: String = "medium"
        var updated: Date?
    }

    static func confidenceBonus(_ value: String) -> Double {
        switch value.lowercased() {
        case "high": return 2
        case "low": return 0
        default: return 1
        }
    }

    /// Lowercase, strip punctuation and whitespace: "只清一下，别动 Docker！"
    /// → "只清一下别动docker".
    static func normalize(_ text: String) -> String {
        let dropped = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        let scalars = text.lowercased().unicodeScalars.filter { !dropped.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Character bigrams. One-character input degrades to the character itself
    /// so short Chinese queries still produce a signal.
    static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(normalize(text))
        guard chars.count > 1 else { return chars.isEmpty ? [] : [String(chars)] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...i + 1]))
        }
        return out
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }

    /// Alias hits: an alias counts when the query contains it (aliases are
    /// written short and literal: "别动", "只清", "docker").
    static func aliasHits(query: String, aliases: [String]) -> Int {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        return aliases.reduce(0) { sum, alias in
            let a = normalize(alias)
            return a.isEmpty ? sum : sum + (q.contains(a) ? 1 : 0)
        }
    }

    /// `3 × alias hits + 2 × bigram Jaccard + confidence + 0.1 × recency`
    /// (design doc §6.2 v2). Threshold 3 means "one alias hit, or a very close
    /// cue", so an empty query retrieves nothing rather than everything.
    static func score(query: String, candidate: Candidate) -> Double {
        let hits = Double(aliasHits(query: query, aliases: candidate.aliases))
        let overlap = 2 * jaccard(bigrams(query), bigrams(candidate.cue))
        var recency = 0.0
        if let updated = candidate.updated {
            let days = max(0, Date().timeIntervalSince(updated) / 86_400)
            recency = 0.1 / (1 + days / 30)
        }
        return 3 * hits + overlap + confidenceBonus(candidate.confidence) + recency
    }

    static func top(
        _ candidates: [Candidate],
        query: String,
        limit: Int = 3,
        threshold: Double = 3
    ) -> [Candidate] {
        candidates
            .map { ($0, score(query: query, candidate: $0)) }
            .filter { $0.1 >= threshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
