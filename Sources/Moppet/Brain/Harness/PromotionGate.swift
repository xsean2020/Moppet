import Foundation

/// One harness version. Snapshots live under `growth/versions/v<N>/` and the
/// manifest is append-only, so "which change made it worse" is answerable
/// (design doc §5.9).
struct HarnessVersion: Codable, Equatable {
    var version: Int
    var parent: Int
    var kind: String        // seed | promote | rollback
    var domain: String
    var summary: String
    var fingerprint: String
    var createdAt: Date
}

/// The three gates (design doc §5.9), plus the version store that makes a bad
/// promotion reversible.
enum PromotionGate {

    enum Decision: Equatable {
        case promote
        case holdForUser(reason: String)
        case reject(reason: String)

        var isPromote: Bool { if case .promote = self { return true }; return false }
    }

    /// Gates: enough samples, actually fewer mistakes, meaningfully better, and
    /// invariant changes need the user's explicit yes.
    static func decide(
        candidate: ShadowProber.Result,
        base: ShadowProber.Result,
        isInvariant: Bool,
        userApproved: Bool,
        minSamples: Int = 6,
        margin: Int = 1
    ) -> Decision {
        guard candidate.samples >= minSamples else {
            return .reject(reason: "证据不足（\(candidate.samples)/\(minSamples) 个决策点）——KEEP_BASE 是合法答案")
        }
        guard candidate.mistakeReproduced < base.mistakeReproduced else {
            return .reject(reason: "重犯次数没有下降（\(candidate.mistakeReproduced) vs 基线 \(base.mistakeReproduced)）")
        }
        guard candidate.score >= base.score + margin else {
            return .reject(reason: "改善不显著（score \(candidate.score) vs 基线 \(base.score)，需要 +\(margin)）")
        }
        if isInvariant && !userApproved {
            return .holdForUser(reason: "改动了全局常驻文本，需要用户确认")
        }
        return .promote
    }

    /// A change that touches any always-on file is INV (affects every turn);
    /// skills, facts and lessons are DOM (scoped, reversible).
    static func isInvariantChange(from: HarnessSurface.Tree, to: HarnessSurface.Tree) -> Bool {
        for path in HarnessSurface.alwaysOn where from[path] != to[path] { return true }
        return false
    }

    // MARK: - Versions

    private static var manifestURL: URL { GrowthPaths.versions.appendingPathComponent("manifest.json") }

    static func versions() -> [HarnessVersion] {
        guard let text = GrowthPaths.read(manifestURL),
              let data = text.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HarnessVersion].self, from: data)) ?? []
    }

    private static func save(_ list: [HarnessVersion]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        GrowthPaths.write(String(decoding: data, as: UTF8.self), to: manifestURL)
    }

    static var current: HarnessVersion? { versions().last }

    static func snapshotDir(_ version: Int) -> URL {
        GrowthPaths.versions.appendingPathComponent("v\(version)", isDirectory: true)
    }

    /// Snapshot + promote. The live tree is written LAST, so a crash mid-way
    /// leaves the old tree running with an extra (harmless) snapshot on disk.
    @discardableResult
    static func promote(
        _ tree: HarnessSurface.Tree,
        domain: IntentClass,
        summary: String,
        kind: String = "promote"
    ) throws -> HarnessVersion {
        var list = versions()
        let next = (list.last?.version ?? 0) + 1
        let dir = snapshotDir(next)
        try PetHarness.write(tree, to: dir)

        let version = HarnessVersion(
            version: next,
            parent: list.last?.version ?? 0,
            kind: kind,
            domain: domain.rawValue,
            summary: summary,
            fingerprint: GrowthLedger.shared.fingerprint(tree),
            createdAt: Date())
        list.append(version)
        save(list)

        // Live tree: replace only surface files, preserving anything off-surface.
        try PetHarness.write(tree, to: HarnessStore.directory)
        return version
    }

    /// Restore the version before the last promotion and record the rollback.
    @discardableResult
    static func rollback() throws -> HarnessVersion {
        let list = versions()
        guard let last = list.last, last.kind == "promote" else {
            throw PromotionError.nothingToRollBack
        }
        let target = last.parent
        let tree: HarnessSurface.Tree
        if target == 0 {
            tree = PetHarness.seed
        } else {
            tree = PetHarness.read(from: snapshotDir(target))
        }
        guard !tree.isEmpty else { throw PromotionError.missingSnapshot(target) }

        let version = HarnessVersion(
            version: (list.last?.version ?? 0) + 1,
            parent: target,
            kind: "rollback",
            domain: last.domain,
            summary: "rollback to v\(target)",
            fingerprint: GrowthLedger.shared.fingerprint(tree),
            createdAt: Date())
        var updated = list
        updated.append(version)
        save(updated)

        // A rollback version MUST carry its own snapshot: a later promotion
        // records this version as its parent, and rolling that promotion back
        // would otherwise try to restore from a directory that was never
        // written (found by the canary smoke — the second rollback silently
        // failed with `missingSnapshot`).
        try PetHarness.write(tree, to: snapshotDir(version.version))
        try PetHarness.write(tree, to: HarnessStore.directory)
        return version
    }

    enum PromotionError: LocalizedError {
        case nothingToRollBack
        case missingSnapshot(Int)

        var errorDescription: String? {
            switch self {
            case .nothingToRollBack: return "no promotion to roll back"
            case .missingSnapshot(let version): return "snapshot v\(version) is missing"
            }
        }
    }
}
