import Foundation

/// Shadow Replay Probe — the core invention (design doc §5.8).
///
/// We cannot say "this harness is better". We *can* say "at this decision point
/// where the record shows a failure, does the new harness still make the same
/// mistake?" That question needs no grader, no re-execution and no user.
///
/// The asymmetry is deliberate: reproducing a known mistake costs 2, preserving
/// a good action earns 1, and **divergence scores nothing** — otherwise a
/// candidate that changes behaviour at random would outrank a real fix.
enum ShadowProber {

    struct Point {
        let sessionID: String
        let itemIndex: Int
        let tool: String
        let shape: String
        let isFailure: Bool
        let line: Int
    }

    struct Result: Equatable {
        var mistakeReproduced = 0
        var goodReproduced = 0
        var diverged = 0
        var samples = 0
        var score: Int { goodReproduced - 2 * mistakeReproduced }
    }

    struct Report {
        var candidate: Result
        var base: Result
        var points: [Point]
    }

    /// Decision points = every route-level tool call, with whether the record
    /// shows it failed. Failures are sampled first: they are the free "known bad"
    /// moments the whole method depends on.
    static func points(sessionID: String, limit: Int = 3) -> [Point] {
        let records = BrainRollout.records(sessionID: sessionID)
        var items: [BrainResponseItem] = []
        var out: [Point] = []

        for (index, entry) in records.enumerated() {
            guard case .responseItem(let item) = entry.record else { continue }
            items.append(item)
            guard case .functionCall(_, let name, let arguments) = item,
                  DivergenceDetector.routeTools.contains(name) else { continue }
            var failed = false
            if index + 1 < records.count,
               case .responseItem(.functionCallOutput(_, let output)) = records[index + 1].record {
                failed = output.hasPrefix("error:")
            }
            out.append(Point(
                sessionID: sessionID,
                itemIndex: items.count - 1,
                tool: name,
                shape: DivergenceDetector.shape(tool: name, arguments: arguments),
                isFailure: failed,
                line: entry.line))
        }

        let failures = out.filter(\.isFailure)
        let successes = out.filter { !$0.isFailure }
        return Array((failures + successes).prefix(limit))
    }

    /// Replay one point: same history, different system prompt, **no tools run**.
    /// The returned shape is the model's first tool call, or "" when it declined
    /// to call anything (which counts as divergence, never as a fix).
    static func replay(
        point: Point,
        tree: HarnessSurface.Tree,
        model: BrainModel,
        cwd: String
    ) async -> String {
        let records = BrainRollout.records(sessionID: point.sessionID)
        var items: [BrainResponseItem] = []
        for entry in records {
            guard case .responseItem(let item) = entry.record else { continue }
            if items.count == point.itemIndex { break }
            items.append(item)
        }

        let system = PetHarness.compose(
            tree: tree, cwd: cwd, sandboxMode: .workspaceWrite,
            approvalPolicy: .onRequest, networkAccess: false)
        let specs = BrainTools.allSpecs(mcpTools: [], mcpConnected: false)

        do {
            let stream = try await model.streamTurn(
                system: system, developer: "", history: items, specs: specs)
            for try await event in stream {
                switch event {
                case .toolCall(let call):
                    // NEVER dispatched: we read the intent and stop (§5.8 硬约束).
                    return DivergenceDetector.shape(tool: call.name, arguments: call.argumentsJSON)
                case .completed:
                    return ""
                case .textDelta:
                    continue
                }
            }
        } catch {
            return ""
        }
        return ""
    }

    /// Screen one candidate against the same points, and the base for contrast.
    static func screen(
        candidate: HarnessSurface.Tree,
        base: HarnessSurface.Tree,
        sessions: [String],
        model: BrainModel,
        maxPoints: Int = 3,
        cwd: String = NSHomeDirectory()
    ) async -> Report {
        var allPoints: [Point] = []
        for session in sessions {
            allPoints.append(contentsOf: points(sessionID: session, limit: maxPoints))
        }
        // Failures across all sessions first, then successes, capped.
        let failures = allPoints.filter(\.isFailure)
        let successes = allPoints.filter { !$0.isFailure }
        let chosen = Array((failures + successes).prefix(max(6, maxPoints * 2)))

        var candidateResult = Result()
        var baseResult = Result()

        for point in chosen {
            let estimate = 800
            guard GrowthLedger.shared.canSpend(estimate) else { break }

            let candidateShape = await replay(
                point: point, tree: candidate, model: model, cwd: cwd)
            let baseShape = await replay(point: point, tree: base, model: model, cwd: cwd)
            GrowthLedger.shared.record(
                kind: "probe", label: "probe.\(point.sessionID).\(point.line)", tokens: estimate * 2)

            classify(recorded: point, observed: candidateShape, into: &candidateResult)
            classify(recorded: point, observed: baseShape, into: &baseResult)
        }

        return Report(candidate: candidateResult, base: baseResult, points: chosen)
    }

    /// The scoring rule, in one place so the asymmetry cannot drift.
    static func classify(recorded: Point, observed: String, into result: inout Result) {
        result.samples += 1
        let same = observed == recorded.shape
        if recorded.isFailure {
            if same { result.mistakeReproduced += 1 } else { result.diverged += 1 }
        } else {
            if same { result.goodReproduced += 1 } else { result.diverged += 1 }
        }
    }
}
