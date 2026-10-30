import Foundation
import Observation

/// Pet visual state, driven by engine events (airi's stage states analogue).
enum PetState: Equatable {
    case idle
    case thinking
    case talking
    case scanning
    case cleaning
    case celebrating
    case sleeping
    /// Brief "oops" pose after an error announcement (drooped ears/tail);
    /// auto-settles to idle like celebrating does.
    case sad
}

/// Shared event bus: engines post progress here, the desktop pet and the
/// chat window observe it. Keeps Core decoupled from UI.
@Observable
final class PetBus {
    static let shared = PetBus()

    var state: PetState = .idle
    var message = ""
    var messageID = UUID()
    /// Seconds the bubble stays visible after a say(); 0 = keep until replaced.
    var autoHideInterval: TimeInterval = 6
    /// Per-message override consumed by the bubble view (0 = keep until
    /// replaced, e.g. streaming answers). Nil = use `autoHideInterval`.
    var messageHideInterval: TimeInterval?
    /// True between `beginStreamingTurn()` and `endStreamingTurn()`: the
    /// quick bar's answer is streaming into the bubble.
    private(set) var streamingTurnActive = false
    /// True when the user tapped the bubble away while its streaming turn
    /// is still running. Further deltas AND the turn's final result stay
    /// hidden — the answer lives on in the chat window — until something
    /// genuinely new speaks (a regular say() or the next turn). Without
    /// this, every token re-opened a bubble the user had just closed.
    private(set) var streamingDismissed = false
    /// Pending auto-settle for one-shot states (celebration loops forever
    /// otherwise — the completion announcement has nothing downstream to
    /// call settle()). Lock-guarded: `say` is called from task-group threads
    /// AND the main thread; an unguarded Task var is a data race.
    private let settleLock = NSLock()
    private var settleTask: Task<Void, Never>?

    /// The bubble is the quick bar's ONLY surface, so a blank message must
    /// never reach it: an empty card reads as a broken bubble. Callers that
    /// genuinely have nothing to say (model returned no text, error without
    /// detail) get this hint instead.
    static let emptyAnswerHint = L("The model returned no text — open the chat window for details.")

    /// Streaming bubble placeholder, shown from `beginStreamingTurn()` until
    /// the first non-blank delta arrives (a slow first token used to sit as
    /// an empty card).
    static let streamingPlaceholder = "…"

    private static func nonBlank(_ text: String, fallback: String = emptyAnswerHint) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : text
    }

    func say(_ text: String, state: PetState? = nil, hideAfter: TimeInterval? = nil) {
        let body = Self.nonBlank(text)
        applyOnMain {
            self.streamingDismissed = false
            self.message = body
            self.messageID = UUID()
            self.messageHideInterval = hideAfter
            if let state { self.state = state }
        }
        if state == .celebrating {
            // Celebrate ~two full loops (hop+spin cycle is 1.6s) then fall
            // back to idle.
            scheduleSettle(after: 3.2)
        } else if state == .sad {
            // Sad is a moment, not a mood: droop, hold, recover.
            scheduleSettle(after: 4.0)
        } else if state != nil {
            // Any new activity cancels a pending celebration settle.
            cancelSettle()
        }
    }

    private func cancelSettle() {
        settleLock.lock()
        let task = settleTask
        settleTask = nil
        settleLock.unlock()
        task?.cancel()
    }

    private func scheduleSettle(after seconds: TimeInterval) {
        cancelSettle()
        settleLock.lock()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
        settleLock.unlock()
    }

    func setState(_ newState: PetState) {
        applyOnMain { self.state = newState }
    }

    // MARK: Streaming turns (quick bar answer → pet bubble)

    /// Opens a streaming turn: shows the bubble once and keeps it on screen;
    /// the deltas that follow update the text only. The bubble opens with a
    /// placeholder rather than "" — a slow first token (or a turn that never
    /// produces text) must not leave an empty card hanging over the pet.
    func beginStreamingTurn(placeholder: String = PetBus.streamingPlaceholder) {
        let body = Self.nonBlank(placeholder, fallback: PetBus.streamingPlaceholder)
        applyOnMain {
            self.streamingTurnActive = true
            self.streamingDismissed = false
            self.message = body
            self.messageID = UUID()
            self.messageHideInterval = 0
            self.state = .talking
        }
    }

    /// One streaming delta. Text-only on purpose: the bubble content
    /// updates if visible, but messageID does NOT move — re-announcing
    /// every token would re-open a bubble the user just tapped away.
    /// Whitespace-only deltas are ignored: they would blank the bubble while
    /// keeping it on screen.
    func sayStreaming(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        applyOnMain {
            if let body { self.message = body }
            guard !self.streamingDismissed else { return }
            if self.state != .talking { self.state = .talking }
        }
    }

    /// The user tapped the bubble away mid-turn: everything this turn
    /// still says stays hidden. No-op outside a streaming turn, so the
    /// regular tap-to-dismiss of engine messages is unaffected.
    func dismissStreaming() {
        applyOnMain {
            guard self.streamingTurnActive else { return }
            self.streamingDismissed = true
        }
    }

    /// The streaming turn finished. An undismissed turn presents the final
    /// text like a regular say() (persistent bubble, final pose). A turn
    /// the user dismissed ends silently back at idle — unless `breakThrough`
    /// (errors must be seen even if the answer stream was closed).
    /// A blank `final` (model returned nothing / tool-only turn with no
    /// summary) shows the hint instead of an empty bubble, and never poses
    /// as a celebration.
    func endStreamingTurn(final: String, finalState: PetState = .celebrating,
                          breakThrough: Bool = false) {
        let blank = final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let body = Self.nonBlank(final)
        let pose: PetState = (blank && finalState == .celebrating) ? .idle : finalState
        applyOnMain {
            let dismissed = self.streamingDismissed
            self.streamingTurnActive = false
            self.streamingDismissed = false
            guard !dismissed || breakThrough else {
                if self.state == .talking { self.state = .idle }
                return
            }
            self.message = body
            self.messageID = UUID()
            self.messageHideInterval = 0
            self.state = pose
        }
        if pose == .celebrating {
            scheduleSettle(after: 3.2)
        } else if pose == .sad {
            scheduleSettle(after: 4.0)
        }
    }

    /// End transient activity states — called by the auto-settle timer or a
    /// user tap ("I saw it"). Talking/thinking/sleeping are left alone.
    func settle() {
        applyOnMain {
            switch self.state {
            case .celebrating, .scanning, .cleaning, .sad:
                self.state = .idle
            default:
                break
            }
        }
    }

    /// Tools run on background executors; @Observable state must change on main.
    private func applyOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

/// One pending destructive-action approval request.
struct ApprovalRequest: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var respond: (Bool) -> Void = { _ in }
}

/// User-approval gate for destructive tools called by the in-app AI agent.
/// The chat window / main window present a dialog bound to `pending`.
/// Requests QUEUE: tool calls run in parallel, and a second request used to
/// overwrite `pending` — the first continuation never resumed and its whole
/// turn hung forever. Extra requests present one-by-one as each is answered.
@Observable
final class ApprovalCenter {
    static let shared = ApprovalCenter()
    private(set) var pending: ApprovalRequest?
    private var queued: [ApprovalRequest] = []

    /// Headless auto-approval (`--brain-exec --yes`): checked BEFORE the
    /// MainActor request path — in headless modes the main thread is blocked
    /// in App.init, so an @MainActor hop (and the old polling Task) would
    /// never run and a destructive tool would deadlock the whole exec.
    static var headlessAutoApprove = false
    /// Headless WITHOUT --yes: same blocked-main-thread situation, so the
    /// request can never be shown — decline inline instead of hanging.
    static var headlessDeny = false

    /// One-shot wrapper: the pet's inline card and the chat sheet both render
    /// buttons for the same request, and a fast double-click (or a click on
    /// the fading-out surface) can invoke `respond` twice — resuming a
    /// checked continuation twice traps the process.
    private final class OnceContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resumeOnce(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    @MainActor
    func request(title: String, detail: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            var request = ApprovalRequest(title: title, detail: detail)
            request.respond = { [weak self] approved in
                once.resumeOnce(approved)
                self?.presentNext()
            }
            if pending == nil {
                pending = request
            } else {
                queued.append(request)
            }
            // Last-resort timeout: with the pet hidden and the chat window
            // closed no surface can ever answer — deny instead of parking
            // the turn forever (aligned with UserInputCenter's timeout).
            let requestID = request.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.pending?.id == requestID {
                    self.pending?.respond(false)
                }
            }
        }
    }

    @MainActor
    private func presentNext() {
        pending = nil
        if !queued.isEmpty {
            pending = queued.removeFirst()
        }
    }

    /// Sheet-dismiss binding path (Esc on the chat approval sheet = deny):
    /// `pending` is private(set) now that requests queue.
    @MainActor
    func dismissPendingAsDenied() {
        guard let current = pending else { return }
        // Same once-only discipline as a button: respond(false) drives
        // resume + presentNext exactly once.
        current.respond(false)
    }
}
