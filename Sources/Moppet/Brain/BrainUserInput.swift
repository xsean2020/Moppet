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
    /// 归属标签（设计文档 §5.7）：任务子 agent 传 taskID；主 agent nil。
    let source: String?
    private let responder: @Sendable ([String: String]?) -> Void

    init(questions: [UserInputQuestion], source: String? = nil,
         responder: @escaping @Sendable ([String: String]?) -> Void) {
        self.questions = questions
        self.source = source
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
    /// pending+queued 队列（§5.7，镜像 ApprovalCenter 的 presentNext 模式）：
    /// 并发第二个请求排队呈示，不再覆盖第一个卡片。
    private struct PendingEntry {
        let request: UserInputRequest
        let channel: Channel
    }
    private var queued: [PendingEntry] = []
    /// 当前呈示请求的答案通道——超时计时按通道绑定（见 armTimeout）。
    private var activeChannel: Channel?
    /// 呈现时武装的单一定时器（rev.3 #14）：300s 计时从成为 pending 起算，
    /// 排队请求到点不再抢跑；先 cancel 旧计时再武装新的。
    private var timeoutTask: Task<Void, Never>?

    /// A surface exists only while one is actually on screen: the pet panel
    /// can be hidden and the chat window closed. The old single
    /// "set true once" flag left the tool waiting 5 minutes on a UI that was
    /// not there — and ApprovalCenter parked forever.
    static var chatSurfaceVisible = false
    static var petSurfaceVisible = false
    static var uiAvailable: Bool { chatSurfaceVisible || petSurfaceVisible }

    /// Test seam（headless 缩短等待用）：生产默认 300s。
    static var timeout: TimeInterval = 300

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

    func request(questions: [UserInputQuestion], source: String? = nil) async -> [String: String]? {
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
                    let request = UserInputRequest(questions: questions, source: source) { answers in
                        channel.finish(answers) { requestID in
                            self.clearPending(id: requestID)
                        }
                    }
                    channel.lock.lock()
                    channel.requestID = request.id
                    channel.requestInstalled = true
                    channel.lock.unlock()
                    // A concurrent answer/cancel may have won before
                    // installation — never park a card for a finished
                    // channel, and never strand the continuation either.
                    guard !channel.isFinished else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.enqueue(PendingEntry(request: request, channel: channel))
                }
            }
            let first = await group.next() ?? nil
            // Belt-and-braces: if the group ended without anyone finishing
            // the channel (cancellation between the two awaits), un-park now.
            channel.finish(nil)
            group.cancelAll()
            _ = await group.next()   // drain
            return first
        }
    }

    /// 入 pending 或 queued（主线程串行）。成为 pending 时武装 300s 计时。
    private func enqueue(_ entry: PendingEntry) {
        let op = { [weak self] in
            guard let self else { return }
            if self.pending == nil {
                self.present(entry)
            } else {
                self.queued.append(entry)
            }
        }
        if Thread.isMainThread {
            op()
        } else {
            DispatchQueue.main.async(execute: op)
        }
    }

    private func present(_ entry: PendingEntry) {
        // @Observable state must change on main; fire-and-forget is safe
        // (PetBus pattern). Headless callers never reach here (uiAvailable).
        let install = { [weak self] in
            self?.pending = entry.request
            self?.requestedAt = Date()
            self?.activeChannel = entry.channel
            self?.armTimeout()
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    /// 呈现时武装单一定时器（rev.3 #14，与 ApprovalCenter 同构）：计时按通道
    /// 绑定——即使呈示期间切换了 pending，迟到的旧计时只会 finish 已完结的
    /// 旧通道（单赢语义下 no-op），不会误杀新请求。
    private func armTimeout() {
        timeoutTask?.cancel()
        guard let channel = activeChannel else { return }
        let source = pending?.source   // 与通道同源：present 时二者一起安装
        timeoutTask = Task { [weak self, channel, source] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.timeoutFired(channel: channel, source: source)
        }
    }

    private func timeoutFired(channel: Channel, source: String?) {
        let timedOut = channel.finish(nil) { [weak self] requestID in
            self?.clearPending(id: requestID)
        }
        // Only a REAL timeout gets announced (the winner check — the old
        // code said "timed out" after every normal answer too).
        // §5.8 静音原则：任务子 agent（source=taskID）的提问超时静默——
        // say 的副作用（streamingDismissed=false 顶掉主对话流式气泡、重弹
        // 已点掉的 QuickChat 气泡）只允许主 agent 触发；任务公告由
        // scheduler 聚合（§5.8），子 agent 自身静音。
        if timedOut, source == nil {
            PetBus.shared.say(L("Question timed out — no answer was sent."), state: .idle)
        }
    }

    /// 「等待你」派生查询（§5.7）：扫描 pending+queued 的 source。
    func hasRequest(source: String) -> Bool {
        if pending?.source == source { return true }
        return queued.contains { $0.request.source == source }
    }

    /// 任务取消时按 source 清理在途提问（§6 修复，镜像 ApprovalCenter 的
    /// dismissForSource）：pending 项走超时同构的 finish(nil)→clearPending→
    /// presentNext（连续多个匹配则循环到非匹配为止）；queued 项摘除后直接
    /// finish（不触碰呈示状态）。通道单赢语义保证迟到的用户答案/超时为 no-op。
    func dismissForSource(_ source: String) {
        let op = { [weak self] in
            guard let self else { return }
            while let current = self.pending, current.source == source,
                  let channel = self.activeChannel {
                channel.finish(nil) { [weak self] requestID in
                    self?.clearPending(id: requestID)
                }
            }
            while let index = self.queued.firstIndex(where: { $0.request.source == source }) {
                let entry = self.queued.remove(at: index)
                entry.channel.finish(nil)
            }
        }
        if Thread.isMainThread {
            op()
        } else {
            DispatchQueue.main.async(execute: op)
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
        presentNext()
    }

    /// 镜像 ApprovalCenter.presentNext（§5.7）：清当前呈示 → 出队下一个并
    /// 重新武装计时。
    private func presentNext() {
        pending = nil
        requestedAt = nil
        activeChannel = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !queued.isEmpty else { return }
        present(queued.removeFirst())
    }
}
