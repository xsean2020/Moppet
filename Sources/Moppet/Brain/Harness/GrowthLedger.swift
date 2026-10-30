import Foundation

/// User-facing knobs. Every default here is the §9.4 recommendation:
/// evolution **off** until the user opts in, 150k tokens/day, at most two
/// promotions a week (a pet that changes daily reads as unstable).
struct GrowthSettings {
    static let enabledKey = "brain.growth.enabled"
    static let dailyTokensKey = "brain.growth.dailyTokens"
    static let reflectCapKey = "brain.growth.reflectDailyCap"

    /// Test seam. `--brain-smoke` must not behave differently on a machine
    /// where the developer has already opted in — otherwise the run either
    /// spends real tokens or silently skips the very paths it is testing.
    static var enabledOverride: Bool?
    static var evolveOverride: Bool?

    static var enabled: Bool {
        get { enabledOverride ?? UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            enabledOverride = nil
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static var dailyTokens: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: dailyTokensKey)
            return value > 0 ? value : 150_000
        }
        set { UserDefaults.standard.set(newValue, forKey: dailyTokensKey) }
    }

    static var reflectDailyCap: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: reflectCapKey)
            return value > 0 ? value : 8
        }
        set { UserDefaults.standard.set(newValue, forKey: reflectCapKey) }
    }

    /// `evolve` defaults to off independently of `enabled`: P2 (reflection) is
    /// safe to turn on; P3 (self-modification) must be a separate, deliberate yes.
    static let evolveKey = "brain.growth.evolve"
    static var evolveEnabled: Bool {
        get { evolveOverride ?? UserDefaults.standard.bool(forKey: evolveKey) }
        set {
            evolveOverride = nil
            UserDefaults.standard.set(newValue, forKey: evolveKey)
        }
    }
}

struct GrowthBudget: Codable, Equatable {
    var maxTokensPerDay: Int = 150_000
    var maxProbesPerDay: Int = 30
    var maxPromotionsPerWeek: Int = 2

    static var current: GrowthBudget {
        GrowthBudget(maxTokensPerDay: GrowthSettings.dailyTokens)
    }
}

/// Budget and fingerprints — `ledger.py` + `runmark.py` (design doc §5.10).
///
/// The budget is a hard gate, not advice: `canSpend` is checked before every
/// model call the growth loop makes. The fingerprint cache stops the loop from
/// re-deriving a conclusion it already reached.
final class GrowthLedger {

    static let shared = GrowthLedger()

    struct Entry: Codable, Equatable {
        var kind: String       // reflect | propose | probe | promote
        var label: String
        var tokens: Int
        var usd: Double
        var at: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var loadedDay = ""

    private static var dayStamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var ledgerURL: URL {
        GrowthPaths.root.appendingPathComponent("ledger-\(Self.dayStamp).json")
    }

    // MARK: - Load / persist

    private func loadIfNeeded() {
        guard loadedDay != Self.dayStamp else { return }
        loadedDay = Self.dayStamp
        entries = []
        guard let text = GrowthPaths.read(ledgerURL),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        GrowthPaths.write(String(decoding: data, as: UTF8.self), to: ledgerURL)
    }

    // MARK: - Accounting

    func record(kind: String, label: String, tokens: Int, usd: Double = 0) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        entries.append(Entry(kind: kind, label: label, tokens: max(0, tokens), usd: usd, at: Date()))
        persist()
    }

    func spentToday() -> Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries.reduce(0) { $0 + $1.tokens }
    }

    func remaining(_ budget: GrowthBudget = .current) -> Int {
        max(0, budget.maxTokensPerDay - spentToday())
    }

    /// Reserve before spending: a call whose estimated input already exceeds
    /// what is left is skipped rather than run and overrun.
    func canSpend(_ estimatedTokens: Int, budget: GrowthBudget = .current) -> Bool {
        remaining(budget) >= max(0, estimatedTokens)
    }

    func entriesToday() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries
    }

    /// Daily reconciliation (design doc §1.6f): the recorded entries must not
    /// contain a duplicate label, because a duplicate means two stages wrote the
    /// same run id and one silently overwrote the other.
    func reconcile() throws {
        let labels = entriesToday().map(\.label)
        let duplicates = Set(labels.filter { label in labels.filter { $0 == label }.count > 1 })
        if !duplicates.isEmpty {
            throw LedgerError.duplicateLabels(duplicates.sorted())
        }
    }

    enum LedgerError: LocalizedError {
        case duplicateLabels([String])

        var errorDescription: String? {
            switch self {
            case .duplicateLabels(let labels):
                return "ledger: duplicate label(s) \(labels.joined(separator: ", ")) — "
                    + "two stages wrote the same id and one silently overwrote the other"
            }
        }
    }

    // MARK: - Fingerprints

    /// `sha1` over sorted (path, body) — the identity of a harness tree.
    func fingerprint(_ tree: HarnessSurface.Tree) -> String {
        var hasher = StableHasher()
        for path in tree.keys.sorted() {
            hasher.combine(path)
            hasher.combine(tree[path] ?? "")
        }
        return hasher.finalHex(prefix: 16)
    }

    /// The cache key must include the evidence, not just the tree: the same
    /// harness proposed against different evidence is a different proposal
    /// (`proposer._call_fingerprint`, design doc §5.10).
    func cacheKey(tree: HarnessSurface.Tree, mission: String, evidence: String) -> String {
        var hasher = StableHasher()
        hasher.combine(fingerprint(tree))
        hasher.combine(mission)
        hasher.combine(evidence)
        return hasher.finalHex(prefix: 20)
    }

    private var cacheURL: URL { GrowthPaths.root.appendingPathComponent("proposal-cache.json") }

    func cachedProposal(key: String) -> String? {
        guard let text = GrowthPaths.read(cacheURL),
              let data = text.data(using: .utf8),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return table[key]
    }

    func storeProposal(key: String, value: String) {
        var table: [String: String] = [:]
        if let text = GrowthPaths.read(cacheURL),
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            table = decoded
        }
        table[key] = value
        if let data = try? JSONEncoder().encode(table) {
            GrowthPaths.write(String(decoding: data, as: UTF8.self), to: cacheURL)
        }
    }

    /// Test seam.
    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        entries = []
        loadedDay = Self.dayStamp
        try? FileManager.default.removeItem(at: ledgerURL)
    }
}

/// A tiny deterministic hasher (FNV-1a over UTF-8). `Hasher` in the standard
/// library is randomly seeded per process, which would make every fingerprint
/// change between launches — useless for a cache.
struct StableHasher {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ text: String) {
        for byte in text.utf8 {
            state ^= UInt64(byte)
            state = state &* 0x0000_0100_0000_01b3
        }
        state ^= 0x1f
    }

    func finalHex(prefix: Int) -> String {
        let hex = String(state, radix: 16)
        return String(hex.prefix(prefix))
    }
}
