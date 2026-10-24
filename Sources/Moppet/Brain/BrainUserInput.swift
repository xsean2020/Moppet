import Foundation
import Observation

/// Native counterpart of codex's `request_user_input` tool: the model may ask
/// the user 1–3 structured questions (each with 2–3 options + free-text
/// "Other"), rendered as a chat sheet and a pet inline card. Same once-only
/// discipline as ApprovalCenter — both surfaces answer the same request, and
/// a 5-minute timeout resumes the continuation instead of leaking it
/// (idle-continuation deadlock, see HANDOFF §6.36).
struct UserInputQuestion: Identifiable, Equatable {
    struct Option: Equatable {
        let label: String
        let description: String
    }

    let id: String
    /// ≤12 chars, shown as a chip above the question (codex `header`).
    let header: String
    let question: String
    let options: [Option]
}

struct UserInputRequest: Identifiable {
    let id = UUID()
    let questions: [UserInputQuestion]
    private let responder: @Sendable ([String: String]?) -> Void

    init(questions: [UserInputQuestion], responder: @escaping @Sendable ([String: String]?) -> Void) {
        self.questions = questions
        self.responder = responder
    }

    /// answers keyed by question id; nil = dismissed/timeout.
    func respond(_ answers: [String: String]?) {
        responder(answers)
    }
}

@Observable
final class UserInputCenter {
    static let shared = UserInputCenter()

    private(set) var pending: UserInputRequest?
    /// When the current request surfaced — lets the cards show the remaining
    /// budget instead of silently dying after 5 minutes.
    private(set) var requestedAt: Date?

    /// A surface exists only while one is actually on screen: the pet panel
    /// can be hidden and the chat window closed. The old single
    /// "set true once" flag left the tool waiting 5 minutes on a UI that was
    /// not there — and ApprovalCenter parked forever.
    static var chatSurfaceVisible = false
    static var petSurfaceVisible = false
    static var uiAvailable: Bool { chatSurfaceVisible || petSurfaceVisible }

    static let timeout: TimeInterval = 300

        /// One shared answer channel for a request: the user answer, the timeout
        /// and cancellation all funnel through finish(); only the first wins.
        /// Returns whether THIS call was the winner (drove the resume).
        private final class Channel: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<[String: String]?, Never>?
            var requestID: UUID?
            var requestInstalled = false
            private var finished = false

            @discardableResult
            func finish(_ answers: [String: String]?,
                        beforeResume: (UUID?) -> Void = { _ in }) -> Bool {
                lock.lock()
                let first = !finished
                finished = true
                let cont = continuation
                continuation = nil
                let requestID = self.requestID
                lock.unlock()
                guard first else { return false }
                beforeResume(requestID)
                cont?.resume(returning: answers)
                return true
            }

            var isFinished: Bool {
                lock.lock()
                defer { lock.unlock() }
                return finished
            }
        }

    func request(questions: [UserInputQuestion]) async -> [String: String]? {
        guard Self.uiAvailable, !questions.isEmpty else { return nil }
        let channel = Channel()
        return await withTaskGroup(
            of: [String: String]?.self
        ) { [weak self] group in
            // Strong local binding: the @Sendable child tasks below capture
            // `self` — a weak binding is a var, which Swift flags as a
            // concurrently-captured var. Guarded once here, children see let.
            guard let self else {
                channel.finish(nil)
                return nil
            }
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<[String: String]?, Never>) in
                    channel.lock.lock()
                    channel.continuation = continuation
                    channel.lock.unlock()
                    let request = UserInputRequest(questions: questions) { answers in
                        channel.finish(answers) { requestID in
                            self.clearPending(id: requestID)
                        }
                    }
                    channel.lock.lock()
                    channel.requestID = request.id
                    channel.requestInstalled = true
                    channel.lock.unlock()
                    // Timeout may have won the race before installation —
                    // never park a card for a finished channel, and never
                    // strand the continuation either.
                    guard !channel.isFinished else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.applyPending(request)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                let timedOut = channel.finish(nil) { requestID in
                    self.clearPending(id: requestID)
                }
                // The sleep child is cancelled the moment the user answers —
                // only a REAL timeout gets announced (the old code said
                // "timed out" after every normal answer too).
                if timedOut {
                    PetBus.shared.say(L("Question timed out — no answer was sent."), state: .idle)
                }
                return nil
            }
            let first = await group.next() ?? nil
            // Belt-and-braces: if the group ended without anyone finishing
            // the channel (cancellation between the two awaits), un-park now.
            channel.finish(nil)
            group.cancelAll()
            _ = await group.next()   // drain (sleep child cancels immediately)
            return first
        }
    }

    private func applyPending(_ request: UserInputRequest) {
        // @Observable state must change on main; fire-and-forget is safe
        // (PetBus pattern). Headless callers never reach here (uiAvailable).
        let install = { [weak self] in
            self?.pending = request
            self?.requestedAt = Date()
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    private func clearPending(id: UUID?) {
        if Thread.isMainThread {
            clearPendingOnMain(id: id)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.clearPendingOnMain(id: id)
            }
        }
    }

    private func clearPendingOnMain(id: UUID?) {
        if let id, pending?.id != id { return }   // a newer request owns the slot
        pending = nil
        requestedAt = nil
    }
}
