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
    /// 任务车道聚合摘要当前是否占着气泡（并行任务显示优化）：scheduler 的
    /// 任务事件据此决定「原地更新文本」还是「重新弹出」。任何非任务内容
    /// （普通 say / 流式回合）接管气泡时复位；气泡被隐藏（计时 / 点掉）
    /// 时由 PetView 经 noteBubbleHidden() 复位。
    private(set) var taskSummaryOnBubble = false
    /// 用户点掉过任务摘要：普通任务进度不再重开气泡（聊天窗口的任务条
    /// 才是常驻视图），失败与批次收尾仍各突破一次。
    private var taskSummaryDismissed = false

    /// 任务结果队列（并行任务显示优化）：每个任务完成时入队一条，气泡一次
    /// 只显示一条；多条结果用 next/prev 翻看，避免后到的结果把前一条顶掉。
    struct TaskAnswer: Identifiable, Equatable {
        let id: String          // taskID
        let title: String
        let text: String
        let status: String      // completed / failed / cancelled
    }
    private(set) var taskAnswers: [TaskAnswer] = []
    private(set) var taskAnswerIndex = 0
    /// True when the bubble currently shows a task RESULT (not the aggregate
    /// progress line from announceTask).
    private(set) var showingTaskAnswer = false

    var taskAnswerCount: Int { taskAnswers.count }
    var currentTaskAnswer: TaskAnswer? {
        taskAnswers.indices.contains(taskAnswerIndex) ? taskAnswers[taskAnswerIndex] : nil
    }
    var canGoPreviousTaskAnswer: Bool { taskAnswerIndex > 0 }
    var canGoNextTaskAnswer: Bool { taskAnswerIndex + 1 < taskAnswers.count }
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
            self.resetTaskAnswers()
            self.streamingDismissed = false
            self.taskSummaryOnBubble = false   // 非任务内容接管气泡
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
            self.resetTaskAnswers()
            self.streamingTurnActive = true
            self.streamingDismissed = false
            self.taskSummaryOnBubble = false   // 流式回答接管气泡
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
            self.taskSummaryOnBubble = false   // 回合结果接管气泡
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

    // MARK: 任务车道聚合气泡（并行任务显示优化）

    /// 任务事件（启动/完成/失败/取消）统一走这里，替代逐条 say() 抢占气泡：
    /// - 气泡正忙（流式回答中 / 有审批待答）→ 完全不打断，人正在看的内容优先；
    /// - 气泡已在显示任务摘要且非 force → 原地更新文本：messageID 不动，
    ///   不重弹、不重置隐藏计时——一批任务事件只弹一次气泡；
    /// - 用户点掉过摘要 → 普通进度保持安静（聊天窗口的任务条才是常驻
    ///   视图）；force（失败 / 批次收尾）突破一次。
    /// 摘要行由 scheduler 组装（计数 + 最近事件），这里只管呈现纪律。
    func announceTask(_ line: String, state: PetState? = nil, force: Bool = false) {
        let pose = state ?? .scanning
        applyOnMain {
            guard !self.streamingTurnActive, ApprovalCenter.shared.pending == nil else { return }
            // 正在看某条任务结果时，进度行让位——结果不能被后到的运行状态顶掉。
            if self.showingTaskAnswer, !force { return }
            if self.taskSummaryOnBubble, !force {
                self.message = line          // 原地更新：气泡不重弹、计时器不重置
                return
            }
            if self.taskSummaryDismissed, !force { return }
            self.showingTaskAnswer = false
            self.taskSummaryOnBubble = true
            self.taskSummaryDismissed = false
            self.streamingDismissed = false
            self.message = line
            self.messageID = UUID()
            self.messageHideInterval = 6
            self.state = pose
        }
        switch pose {
        case .celebrating: scheduleSettle(after: 3.2)
        case .sad: scheduleSettle(after: 4.0)
        default: cancelSettle()
        }
    }

    /// 任务完成：结果单独入队，气泡一次显示一条。
    ///
    /// - 已在看某条结果：新结果只追加到队列尾部，不抢走当前阅读位置；
    /// - 气泡空闲/已被点掉：显示最新一条，`next/prev` 可回看队列里的其他结果。
    func enqueueTaskAnswer(taskID: String, title: String, text: String, status: String) {
        let body = Self.nonBlank(text)
        applyOnMain {
            let wasShowing = self.showingTaskAnswer
            let answer = TaskAnswer(id: taskID, title: title, text: body, status: status)
            if let index = self.taskAnswers.firstIndex(where: { $0.id == taskID }) {
                self.taskAnswers[index] = answer
                if wasShowing { self.taskAnswerIndex = index }
            } else {
                self.taskAnswers.append(answer)
                if self.taskAnswers.count > 20 {
                    let dropped = self.taskAnswers.count - 20
                    self.taskAnswers.removeFirst(dropped)
                    self.taskAnswerIndex = max(0, self.taskAnswerIndex - dropped)
                }
                if !wasShowing { self.taskAnswerIndex = self.taskAnswers.count - 1 }
            }
            guard !wasShowing else { return }
            self.showCurrentTaskAnswer()
        }
    }

    /// 气泡上的任务结果往前翻。
    func previousTaskAnswer() {
        applyOnMain {
            guard self.taskAnswerIndex > 0 else { return }
            self.taskAnswerIndex -= 1
            self.showCurrentTaskAnswer()
        }
    }

    /// 气泡上的任务结果往后翻。
    func nextTaskAnswer() {
        applyOnMain {
            guard self.taskAnswerIndex + 1 < self.taskAnswers.count else { return }
            self.taskAnswerIndex += 1
            self.showCurrentTaskAnswer()
        }
    }

    private func showCurrentTaskAnswer() {
        guard let answer = currentTaskAnswer else { return }
        // 流式回答 / 审批优先；结果留在队列里，等下一次任务事件或用户翻页再显示。
        guard !streamingTurnActive, ApprovalCenter.shared.pending == nil else {
            showingTaskAnswer = false
            return
        }
        showingTaskAnswer = true
        taskSummaryOnBubble = true
        taskSummaryDismissed = false
        streamingDismissed = false
        message = "**\(answer.title)**\n\n\(answer.text)"
        messageID = UUID()
        // 任务结果不自动消失：用户要逐条翻看，消失时机由「点掉」决定。
        messageHideInterval = 0
        if answer.status == "failed" {
            state = .sad
            scheduleSettle(after: 4.0)
        } else if answer.status == "cancelled" {
            state = .idle
            cancelSettle()
        } else {
            state = .celebrating
            scheduleSettle(after: 3.2)
        }
    }

    private func resetTaskAnswers() {
        guard !taskAnswers.isEmpty || showingTaskAnswer else { return }
        taskAnswers.removeAll()
        taskAnswerIndex = 0
        showingTaskAnswer = false
    }

    /// 气泡被隐藏（自动计时 / 用户点掉）时由 PetView 调用：正在显示的若是
    /// 任务摘要，记为「已点掉」——后续普通任务进度不再重开气泡。
    func noteBubbleHidden() {
        applyOnMain {
            if self.taskSummaryOnBubble { self.taskSummaryDismissed = true }
            self.taskSummaryOnBubble = false
            self.showingTaskAnswer = false
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
    /// 归属标签（设计文档 §5.7）：任务子 agent 传 taskID——「等待你」卡片
    /// 徽标与 scheduler 的 awaitingUser 派生据此查询；主 agent nil。
    var source: String? = nil
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
    /// 呈现时武装的单一定时器（rev.3 #16）：pending 安装与 presentNext 出队时
    /// armTimeout()（先 cancel 旧 Task），15 分钟从成为 pending 起算——每个
    /// 请求恰好一个生效计时器，排队请求不再永不超时、也不再双计时器并存。
    private var timeoutTask: Task<Void, Never>?
    /// Test seam（--brain-smoke 排队超时用例）：生产默认 15 分钟。
    static var timeoutInterval: TimeInterval = 15 * 60

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
    func request(title: String, detail: String, source: String? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            var request = ApprovalRequest(title: title, detail: detail, source: source)
            request.respond = { [weak self, requestID = request.id] approved in
                once.resumeOnce(approved)
                // 仅当响应的正是当前 pending 时才推进队列：dismissForSource 对
                // queued 项的 deny 不得顶掉无关 pending——否则那张卡片的
                // continuation 被搁浅、对应 turn 永久挂起。
                self?.presentNext(ifCurrent: requestID)
            }
            if pending == nil {
                pending = request
                armTimeout()   // 15 分钟从成为 pending 起算（rev.3 #16）
            } else {
                queued.append(request)
            }
        }
    }

    /// 呈现时武装单一定时器（§5.7 / rev.3 #16）：请求级计时 Task 已删除——
    /// 它只对当前 pending 生效（排队请求永不超时），且与 presentNext 重设
    /// 并存时会让排队后呈示的审批实际预算 < 15 分钟。pending 安装与出队时
    /// 各武装一次（先 cancel 旧 Task）。
    @MainActor
    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutInterval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Last-resort timeout: with the pet hidden and the chat window
            // closed no surface can ever answer — deny instead of parking
            // the turn forever (aligned with UserInputCenter's timeout).
            self.pending?.respond(false)
        }
    }

    /// 「等待你」派生查询（§5.7）：扫描 pending+queued 的 source。
    @MainActor
    func hasRequest(source: String) -> Bool {
        if pending?.source == source { return true }
        return queued.contains { $0.source == source }
    }

    @MainActor
    private func presentNext(ifCurrent id: UUID) {
        // 队列推进只由「当前呈示项被响应」驱动；dismissForSource 摘除的排队
        // 项也走 respond(false) 恢复 continuation，但 id 不匹配 → 不推进、
        // 不动无关 pending。
        guard pending?.id == id else { return }
        pending = nil
        if !queued.isEmpty {
            pending = queued.removeFirst()
            armTimeout()   // 出队即呈现：预算从现在起算，单一生效计时器
        }
    }

    /// 任务取消时按 source 清理在途审批（§6 修复）：runLoop 停在不可取消的
    /// 审批 continuation 上时，runTask.cancel/agent.cancel 都到不了它——按
    /// source（任务子 agent 传 taskID）deny 全部 pending+queued 匹配项，让
    /// 挂起的 continuation 以 false 立即返回 → runLoop 下一检查点展开 →
    /// finishTask 结账；僵尸审批不再可被批准执行破坏性动作。
    @MainActor
    func dismissForSource(_ source: String) {
        while pending?.source == source {
            pending?.respond(false)   // 恢复 + presentNext 提升下一个（可能仍是本任务 → 循环）
        }
        while let index = queued.firstIndex(where: { $0.source == source }) {
            let request = queued.remove(at: index)
            request.respond(false)   // 恢复；ifCurrent 守卫跳过推进，不动无关 pending
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
