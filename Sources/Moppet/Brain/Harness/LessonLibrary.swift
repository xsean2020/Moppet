import Foundation

/// A transferable lesson, stored per intent (design doc §5.5).
///
/// Four fields are mandatory and three of them are load-bearing:
/// `cue` decides *when* it fires, `lesson` says what to do, `evidence` says why
/// we believe it. A lesson without evidence is a guess, and guesses poison the
/// library for every later task — so `write` refuses them.
struct Lesson: Equatable {
    var id: String
    var intent: IntentClass
    var cue: String
    var lesson: String
    var evidence: String
    var confidence: String
    var aliases: [String] = []
    var createdAt: Date = Date()
    /// The `<edits>` verdict this lesson rests on (§5.7): helped / hurt /
    /// no observed effect / confounded. **`confounded` never enters the
    /// library** — "a lesson resting only on confounded rows is a guess",
    /// and a guess poisons every later task that retrieves it.
    var verdict: String = "helped"

    var directory: URL { GrowthPaths.library.appendingPathComponent(intent.rawValue).appendingPathComponent(id) }
    var file: URL { directory.appendingPathComponent("LESSON.md") }

    var candidate: CueMatcher.Candidate {
        CueMatcher.Candidate(
            id: id, cue: cue, aliases: aliases,
            confidence: confidence, updated: createdAt)
    }
}

enum LessonLibrary {

    static let confidences: Set<String> = ["high", "medium", "low"]

    // MARK: - Read

    static func entries(intent: IntentClass) -> [Lesson] {
        let dir = GrowthPaths.library.appendingPathComponent(intent.rawValue)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard let text = GrowthPaths.read(dir.appendingPathComponent(name).appendingPathComponent("LESSON.md"))
            else { return nil }
            return parse(id: name, intent: intent, text: text)
        }
    }

    static func all() -> [Lesson] {
        IntentClass.allCases.flatMap { entries(intent: $0) }
    }

    static func parse(id: String, intent: IntentClass, text: String) -> Lesson? {
        let parsed = Frontmatter.parse(text)
        let cue = parsed.fields["cue"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let lesson = parsed.fields["lesson"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let evidence = parsed.fields["evidence"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !cue.isEmpty, !lesson.isEmpty, !evidence.isEmpty else { return nil }
        return Lesson(
            id: id,
            intent: intent,
            cue: cue,
            lesson: lesson,
            evidence: evidence,
            confidence: parsed.fields["confidence"] ?? "medium",
            aliases: MemoryBank.splitAliases(parsed.fields["aliases"] ?? ""),
            createdAt: Frontmatter.date(parsed.fields["created"] ?? "") ?? Date(),
            verdict: parsed.fields["verdict"] ?? "helped")
    }

    // MARK: - Write

    enum WriteError: LocalizedError {
        case emptyField(String)
        case taskFact(String, String)
        case badConfidence(String)
        case confounded
        case ioFailed

        var errorDescription: String? {
            switch self {
            case .emptyField(let name):
                return "lesson rejected: `\(name)` is empty (all of cue/lesson/evidence are required)"
            case .taskFact(let field, let snippet):
                return "lesson rejected: `\(field)` contains this session's facts (\(snippet)) — it would not transfer"
            case .badConfidence(let value):
                return "lesson rejected: confidence '\(value)' is not one of high|medium|low"
            case .confounded:
                return "lesson rejected: verdict is `confounded` — a change that could not be isolated "
                    + "cannot support a rule; it is logged for audit only"
            case .ioFailed:
                return "lesson rejected: could not write to disk"
            }
        }
    }

    /// The only way a lesson enters the library.
    @discardableResult
    static func write(_ lesson: Lesson, now: Date = Date()) throws -> Lesson {
        guard !lesson.cue.trimmingCharacters(in: .whitespaces).isEmpty else { throw WriteError.emptyField("cue") }
        guard !lesson.lesson.trimmingCharacters(in: .whitespaces).isEmpty else { throw WriteError.emptyField("lesson") }
        guard !lesson.evidence.trimmingCharacters(in: .whitespaces).isEmpty else { throw WriteError.emptyField("evidence") }
        guard confidences.contains(lesson.confidence.lowercased()) else {
            throw WriteError.badConfidence(lesson.confidence)
        }
        // §5.7: an unisolatable change is a guess, and a guess in the library
        // is worse than a gap. The caller keeps it in the audit log instead.
        guard lesson.verdict.lowercased() != "confounded" else { throw WriteError.confounded }

        // V7 — a cue/lesson that carries this session's numbers or paths is
        // overfitting; evidence may cite them, the rule may not.
        for (field, text) in [("cue", lesson.cue), ("lesson", lesson.lesson)] {
            if let snippet = HarnessValidator.taskFact(in: text) {
                throw WriteError.taskFact(field, snippet)
            }
        }

        var stored = lesson
        if stored.id.isEmpty { stored.id = defaultID(for: lesson, now: now) }
        stored.createdAt = now

        let body = Frontmatter.render(fields: [
            ("intent", stored.intent.rawValue),
            ("cue", stored.cue),
            ("aliases", stored.aliases.joined(separator: ", ")),
            ("lesson", stored.lesson),
            ("evidence", stored.evidence),
            ("confidence", stored.confidence.lowercased()),
            ("verdict", stored.verdict.lowercased()),
            ("created", Frontmatter.iso(now)),
        ], body: stored.evidence)

        GrowthPaths.write(body, to: stored.file)
        guard FileManager.default.fileExists(atPath: stored.file.path) else { throw WriteError.ioFailed }
        rebuildIndex(intent: stored.intent)
        return stored
    }

    static func defaultID(for lesson: Lesson, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: now)
        let slug = lesson.cue
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "-")
        return "\(stamp)-\(slug.isEmpty ? "lesson" : String(slug.prefix(24)))"
    }

    @discardableResult
    static func remove(_ lesson: Lesson) -> Bool {
        do {
            try FileManager.default.removeItem(at: lesson.directory)
            rebuildIndex(intent: lesson.intent)
            return true
        } catch { return false }
    }

    /// Derived data, rebuilt from the entries on disk (design doc §5.12, I3).
    static func rebuildIndex(intent: IntentClass) {
        let entries = self.entries(intent: intent)
        var lines = ["# 经验库 — \(intent.rawValue)", ""]
        if entries.isEmpty {
            lines.append("（暂无经验。）")
        } else {
            for lesson in entries {
                lines.append("## `\(lesson.id)/`")
                lines.append("- cue: \(lesson.cue)")
                lines.append("- confidence: \(lesson.confidence)")
                lines.append("")
            }
        }
        GrowthPaths.write(
            lines.joined(separator: "\n") + "\n",
            to: GrowthPaths.library.appendingPathComponent(intent.rawValue).appendingPathComponent("INDEX.md"))
    }

    // MARK: - Retrieval (L1, zero model calls)

    static func retrieve(intent: IntentClass, query: String, limit: Int = 3) -> [Lesson] {
        let byID = Dictionary(uniqueKeysWithValues: entries(intent: intent).map { ($0.id, $0) })
        let candidates = byID.values.map(\.candidate)
        return CueMatcher.top(candidates, query: query, limit: limit)
            .compactMap { byID[$0.id] }
    }

    /// The developer-message block. Empty when nothing matches — an empty
    /// section would be pure noise on every turn.
    static func injectedBlock(intent: IntentClass, query: String) -> String {
        let hits = retrieve(intent: intent, query: query)
        guard !hits.isEmpty else { return "" }
        let lines = hits.map { "- [\(intent.rawValue)] \($0.cue)：\($0.lesson)" }
        return "## 相关经验（本类任务）\n" + lines.joined(separator: "\n")
    }
}
