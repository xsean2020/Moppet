import Foundation

/// Thread-safe single-shot gate: the first caller wins, everyone else is a
/// no-op. Shared by the network probes' async bridges.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}