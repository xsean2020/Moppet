import Foundation

/// One turn's observable signals — the pet's proxy for a reward
/// (design doc §5.6). Every field is read off code that already exists; no new
/// instrumentation cost, no user rating, no grader.
struct TurnOutcome: Codable, Equatable, Sendable {
    let sessionID: String
    let turnIndex: Int
    /// Refined once the turn ends: words first, then the tools it actually
    /// called (a "then delete it" inherits the domain of what came before).
    var intent: IntentClass
    let startedAt: Date

    var toolCalls: Int = 0
    var toolErrors: Int = 0
    var approvalDenied: Bool = false
    var userCancelled: Bool = false
    var maxTurnsHit: Bool = false
    /// Said it would act, then called nothing that changes anything.
    var promisedButNoAction: Bool = false
    /// The user repeated themselves within two minutes — the last turn did not land.
    var reAskedWithin120s: Bool = false
    /// The user said the pet got it wrong ("不对，我说的是…"). §5.7 trigger ③:
    /// this is the cheapest and most reliable signal there is — the user
    /// already did the judgement for us, so no reflection trigger needs to
    /// infer anything.
    var userCorrected: Bool = false

    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var wallSeconds: Double = 0

    /// Headless runs (`--brain-exec`, `--brain-smoke`) have no user to be
    /// right or wrong for, so their verdict is `unknown` and they are excluded
    /// from every statistic (§11 item 18). Counting them would let CI runs
    /// drag the domain bad-ratios around.
    var headless: Bool = false

    /// Which harness produced this turn — attribution without guesswork (§5.10).
    var harnessFingerprint: String = "seed"
    var toolNames: [String] = []

    var totalTokens: Int { inputTokens + outputTokens }
}

enum TurnVerdict: String, Codable {
    case good, neutral, bad, unknown
}

extension TurnOutcome {

    /// Tools that change state. Their absence is what makes a "I'll clean that
    /// up" reply a broken promise rather than a plan.
    static let mutatingTools: Set<String> = [
        "apply_patch", "shell", "exec_command", "write_stdin",
        "execute_clean", "purge_artifacts", "uninstall_app", "slim_apps",
        "clean_orphans", "docker_prune", "brew_cleanup", "clean_history",
        "set_launch_item_enabled", "run_optimize", "delete_local_snapshots",
        "whitelist_add", "whitelist_remove",
    ]

    /// Three states plus unknown — never a 0–100 score (design doc §5.6).
    /// `bad` has several independent triggers and any one of them is enough:
    /// the downside is weighted far more heavily than the upside.
    var verdict: TurnVerdict {
        // A headless turn has no user verdict to earn — never `.bad`, or CI
        // would teach the pet that its own test runs are failures.
        if headless { return .unknown }
        if userCancelled || approvalDenied || maxTurnsHit { return .bad }
        if promisedButNoAction { return .bad }
        if reAskedWithin120s { return .bad }
        if toolCalls > 0 && toolErrors * 2 >= toolCalls { return .bad }
        if toolCalls == 0 && intent != .chat { return .neutral }
        if toolErrors == 0 { return .good }
        return .neutral
    }

    /// Only `bad` turns — or a turn the user had to correct — are worth a
    /// reflection call (design doc §5.7).
    var deservesReflection: Bool { verdict == .bad || userCorrected }
}

/// A user decision on one approval request — the signal `approvalDenied` needs,
/// and the only place the pet can learn what the user refused (§5.12, G2).
struct ApprovalEvent: Codable, Equatable, Sendable {
    let callID: String
    let name: String
    let detail: String
    let approved: Bool
    let at: Date
}

/// Per-day outcome log, one JSONL file per day. Separate from the rollout so
/// statistics never have to parse transcripts, and so the log stays small.
enum TurnOutcomeLog {

    private static var dayStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func append(_ outcome: TurnOutcome, at date: Date = Date()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(outcome),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = GrowthPaths.outcomes.appendingPathComponent("\(dayStamp).jsonl")
        let existing = GrowthPaths.read(url) ?? ""
        GrowthPaths.write(existing + line + "\n", to: url)
    }

    static func load(days: Int = 7) -> [TurnOutcome] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var out: [TurnOutcome] = []
        for offset in 0..<max(1, days) {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let url = GrowthPaths.outcomes.appendingPathComponent("\(formatter.string(from: day)).jsonl")
            guard let text = GrowthPaths.read(url) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let outcome = try? decoder.decode(TurnOutcome.self, from: Data(line.utf8)) {
                    out.append(outcome)
                }
            }
        }
        return out
    }

    /// Domain statistics for `pickWorstDomain`: bad ratio with a minimum sample.
    static func badRatios(days: Int = 7, minSamples: Int = 5) -> [(intent: IntentClass, ratio: Double, samples: Int)] {
        let all = load(days: days)
        var buckets: [IntentClass: (bad: Int, total: Int)] = [:]
        for outcome in all {
            // `unknown` (headless) is not evidence either way.
            guard outcome.verdict != .unknown else { continue }
            var bucket = buckets[outcome.intent] ?? (0, 0)
            bucket.total += 1
            if outcome.verdict == .bad { bucket.bad += 1 }
            buckets[outcome.intent] = bucket
        }
        return buckets
            .filter { $0.value.total >= minSamples }
            .map { (intent: $0.key, ratio: Double($0.value.bad) / Double($0.value.total), samples: $0.value.total) }
            .sorted { $0.ratio > $1.ratio }
    }

    /// Sessions in a domain whose verdict was bad — the probe's evidence pool.
    static func badSessions(intent: IntentClass, days: Int = 7) -> Set<String> {
        Set(load(days: days)
            .filter { $0.intent == intent && $0.verdict == .bad }
            .map(\.sessionID))
    }

    static func recentSessions(intent: IntentClass, days: Int = 7, limit: Int = 8) -> [String] {
        var seen: [String] = []
        for outcome in load(days: days) where outcome.intent == intent {
            if !seen.contains(outcome.sessionID) { seen.append(outcome.sessionID) }
        }
        return Array(seen.suffix(limit))
    }
}
