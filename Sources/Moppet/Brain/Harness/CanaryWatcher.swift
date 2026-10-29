import Foundation

/// Gate ③ — the canary — and decision D10 (design doc §5.9 / §5.11).
///
/// D10 is marked **"只能规则"** in the §5.11 decision table: a rollback that
/// "feels right" is worse than one that never fires, because the wrong
/// direction costs either user data (false rollback) or user trust (missed
/// rollback). So both triggers are arithmetic over `TurnOutcomeLog`, never a
/// model call:
///
///   a. the last **two** outcomes in the domain were both bad; or
///   b. ≥5 domain outcomes since the canary opened and the bad rate exceeds
///      the pre-promotion baseline by more than 20%.
///
/// A canary that survives 48h is concluded OK and cleared. Everything here is
/// cheap (one small JSONL read) so the scheduler can poll it every cycle.
enum CanaryWatcher {

    struct State: Codable, Equatable {
        var version: Int
        var domain: String
        var baselineBadRate: Double
        var startedAt: Date
    }

    static var stateURL: URL { GrowthPaths.root.appendingPathComponent("canary.json") }
    static var auditURL: URL { GrowthPaths.root.appendingPathComponent("canary-last.txt") }

    /// How long a canary runs before it is declared passed (§5.9: 24h window
    /// for the rate trigger; 48h total before the canary is retired).
    static let maxAgeSeconds: TimeInterval = 48 * 3600
    static let rateTriggerSamples = 5
    static let rateTriggerMargin = 0.20

    /// Test seam.
    static var now: () -> Date = { Date() }

    static func state() -> State? {
        guard let text = GrowthPaths.read(stateURL),
              let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Open a canary for a freshly promoted version. The baseline is the
    /// domain's bad ratio over the **week before** the promotion — the number
    /// gate ③ compares against must be measured before the change took effect.
    static func begin(version: Int, domain: IntentClass) {
        let baseline = TurnOutcomeLog.badRatios(days: 7)
            .first { $0.intent == domain }?.ratio ?? 0
        let state = State(
            version: version, domain: domain.rawValue,
            baselineBadRate: baseline, startedAt: now())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            GrowthPaths.write(String(decoding: data, as: UTF8.self), to: stateURL)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// The rollback reason, or nil when the canary is healthy / absent.
    static func evaluate(at date: Date? = nil) -> String? {
        let moment = date ?? now()
        guard let canary = state() else { return nil }
        if moment.timeIntervalSince(canary.startedAt) > maxAgeSeconds {
            clear()
            return nil
        }
        guard let domain = IntentClass(rawValue: canary.domain) else {
            clear()
            return nil
        }
        let outcomes = TurnOutcomeLog.load(days: 3)
            .filter { $0.intent == domain && $0.startedAt >= canary.startedAt }
            .sorted { $0.startedAt < $1.startedAt }
        guard !outcomes.isEmpty else { return nil }

        // (a) two bad in a row — the sharpest, least arguable signal.
        if outcomes.count >= 2,
           outcomes.suffix(2).allSatisfy({ $0.verdict == .bad }) {
            return "连续 2 次 bad"
        }
        // (b) rate regression over a real sample.
        if outcomes.count >= rateTriggerSamples {
            let bad = outcomes.filter { $0.verdict == .bad }.count
            let rate = Double(bad) / Double(outcomes.count)
            if rate > canary.baselineBadRate + rateTriggerMargin {
                return String(format: "bad 率 %.0f%% 超过基线 %.0f%% + 20%%",
                              rate * 100, canary.baselineBadRate * 100)
            }
        }
        return nil
    }

    /// Evaluate and roll back when a trigger fires. Idempotent: after a
    /// rollback the state is cleared, so the next poll is a no-op.
    @discardableResult
    static func enforce() -> HarnessVersion? {
        guard let reason = evaluate() else { return nil }
        guard let rolled = try? PromotionGate.rollback() else {
            clear()
            return nil
        }
        clear()
        GrowthPaths.write(
            "\(Frontmatter.iso(Date())) canary v\(rolled.parent + 1) \(reason) → 回滚到 v\(rolled.parent)\n",
            to: auditURL)
        return rolled
    }
}
