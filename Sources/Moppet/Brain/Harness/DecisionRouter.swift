import Foundation

/// The decision ladder (design doc §5.11).
///
/// §5.11 answers a narrow question — *can a small model save money here?* — and
/// the answer is **no**: the cost is elsewhere (§6.4), and the decisions that
/// look expensive are the ones that must never leave deterministic code. What
/// the ladder is actually for is the long tail (D1/D5/D6) and offline latency.
///
/// The one rule that matters, and the only one this file enforces at runtime:
///
/// > 规则先答，答不了才升级；`risk == .high` 的决策**永不**进入小模型。
///
/// D2 (verdict), D7 (distil), D8 (propose) and D9/D10 (promote / rollback) are
/// high risk because a wrong answer writes into persistent state — the library,
/// the harness, the user's experience of the pet. For those, a probabilistic
/// model is not a cheaper implementation, it is a **wrong** implementation:
/// it cannot be audited ("why was my turn bad?"), cannot be asserted in
/// `--brain-smoke`, and cannot run at zero latency inside `runLoop`'s exit.
enum DecisionRisk: String, Sendable {
    case low, high
}

enum DecisionKind: String, CaseIterable, Sendable {
    case intent      // D1
    case verdict     // D2
    case reflect     // D3
    case retrieval   // D4
    case reask       // D5
    case promise     // D6
    case distill     // D7
    case propose     // D8
    case promote     // D9
    case rollback    // D10

    /// The §5.11.1 table, encoded. High risk = "该由谁做：只能规则/只能主模型".
    var risk: DecisionRisk {
        switch self {
        case .verdict, .distill, .propose, .promote, .rollback: return .high
        case .intent, .reflect, .retrieval, .reask, .promise: return .low
        }
    }
}

struct DecisionQuery: Equatable, Sendable {
    var kind: DecisionKind
    var text: String = ""
    /// Overrides the kind's default only when the caller knows better — a
    /// caller must never be able to *lower* a high-risk kind by accident.
    var riskOverride: DecisionRisk? = nil

    var risk: DecisionRisk {
        if let riskOverride { return max(riskOverride, kind.risk) }
        return kind.risk
    }
}

extension DecisionRisk: Comparable {
    private var rank: Int { self == .low ? 0 : 1 }
    static func < (lhs: DecisionRisk, rhs: DecisionRisk) -> Bool { lhs.rank < rhs.rank }
}

protocol DecisionMaker: Sendable {
    /// Returns nil for "I cannot decide" — never a guess.
    func decide(_ query: DecisionQuery) async -> String?
}

/// Tier 1: zero tokens, deterministic, unit-testable.
struct RuleDecider: DecisionMaker {

    func decide(_ query: DecisionQuery) async -> String? {
        switch query.kind {
        case .intent:
            // Only answer when the words actually match. Defaulting to `.chat`
            // here would starve the small model of exactly the cases it exists
            // for (D1's "模糊时").
            return IntentClass.keywordMatch(query.text)?.rawValue
        case .verdict:
            return nil   // the caller owns the TurnOutcome; never re-derived here
        default:
            return nil
        }
    }
}

/// Tier 2: a local Ollama or a flash-class cloud model.
///
/// **Auto-disabled when it is the same vendor+model as the main model** — that
/// configuration is strictly worse than calling the main model directly (same
/// latency budget, an extra hop, no accuracy gain). §9.4 #6: default to
/// "follow the main model's config", which means this tier stays off until the
/// user deliberately configures something smaller.
final class SmallModelDecider: DecisionMaker, @unchecked Sendable {

    let provider: String
    let model: String
    let mainProvider: String
    let mainModel: String
    private let backend: (@Sendable (DecisionQuery) async -> String?)?

    init(provider: String, model: String,
         mainProvider: String, mainModel: String,
         backend: (@Sendable (DecisionQuery) async -> String?)? = nil) {
        self.provider = provider
        self.model = model
        self.mainProvider = mainProvider
        self.mainModel = mainModel
        self.backend = backend
    }

    /// "A slower main model" — the failure mode §5.11.3 calls out.
    var isEnabled: Bool {
        guard !provider.isEmpty, !model.isEmpty else { return false }
        return !(provider.lowercased() == mainProvider.lowercased()
                 && model.lowercased() == mainModel.lowercased())
    }

    func decide(_ query: DecisionQuery) async -> String? {
        guard isEnabled, let backend else { return nil }
        return await backend(query)
    }
}

/// Tier 3: the model the pet is already talking to.
struct MainModelDecider: DecisionMaker {
    let backend: (@Sendable (DecisionQuery) async -> String?)?

    func decide(_ query: DecisionQuery) async -> String? {
        guard let backend else { return nil }
        return await backend(query)
    }
}

/// The router itself. Deliberately not an actor: every tier is already safe to
/// call concurrently, and a hop would put an await between `runLoop`'s exit and
/// the verdict — the one place §5.11.3 requires zero latency.
final class DecisionRouter: @unchecked Sendable {

    static let shared = DecisionRouter()

    var rule: any DecisionMaker = RuleDecider()
    var small: (any DecisionMaker)?
    var main: (any DecisionMaker)?

    func decide(_ query: DecisionQuery) async -> String? {
        if let answer = await rule.decide(query) { return answer }
        // High risk stops here — not because the small model is bad, but
        // because these decisions must be auditable and assertable.
        guard query.risk == .low else { return nil }
        if let small, let answer = await small.decide(query) { return answer }
        return await main?.decide(query)
    }
}
