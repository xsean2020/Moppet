import Foundation

/// The only thing that ever calls `Evolver.tick` on a timer.
///
/// Two design constraints shape this file:
///
/// 1. **The pet must never feel busy.** `tick` is a *poll*, not a job: it
///    returns in microseconds unless every guard passes, and every guard is
///    cheap (settings flag, idle clock, budget counter). The expensive path
///    only starts after ten minutes of silence.
/// 2. **Nothing here may block launch.** The loop is a detached task; if the
///    app quits mid-reflection the partial evidence on disk is still valid,
///    because every write is a whole-file atomic write.
enum BrainGrowthScheduler {

    /// Ten minutes of silence is the design-doc threshold (§5.9): shorter and
    /// the pet competes with the user's own reading time, longer and a
    /// once-a-day user never reaches it.
    static let idleSeconds: TimeInterval = 600
    static let pollSeconds: TimeInterval = 300

    private static let lock = NSLock()
    private static var task: Task<Void, Never>?

    /// Idempotent: called once from the app's launch path.
    static func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Read the flags first: an opted-out user must cost zero
                // work, not "a tick that decides to do nothing".
                guard GrowthSettings.enabled else { continue }
                // Gate ③ runs BEFORE the evolve gate on purpose: even a user
                // who turns self-modification off afterwards still deserves
                // the auto-rollback for a change already promoted.
                CanaryWatcher.enforce()
                guard GrowthSettings.evolveEnabled else { continue }
                guard BrainActivity.isIdle(for: idleSeconds) else { continue }
                // Built inside the loop so nothing non-Sendable crosses the
                // task boundary, and so a settings change takes effect on the
                // next poll without a restart.
                let model = BrainAgent.defaultModel(AISettings.load())
                await Evolver.shared.tick(model: model)
            }
        }
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
        Evolver.shared.cancel()
    }

    /// Test seam — the loop itself must not run under `--brain-smoke`.
    static var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return task != nil
    }
}
