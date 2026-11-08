import Foundation
import Observation

/// 一个并行任务 = 一次独立的子 BrainAgent 生命周期（设计文档 §5.1，dsh 的
/// Ticket/Assignment 合并体）。`stage` 是派生表（dsh stage.ts:9-21 直译）：
/// 从事实自上而下第一条命中，canRetry 同样派生——派生而非存储枚举，杜绝
/// 状态漂移与事件乱序问题。
struct BrainTask: Identifiable, Equatable {
    /// 存储态（Assignment 语义：独立 pending→running→ended）。
    enum RunState: String, Codable { case queued, running, ended }
    enum Outcome: String, Codable { case none, completed, failed, cancelled }
    /// 展示态：纯派生，不落存储。
    enum Stage: String { case queued, running, awaitingUser, completed, failed, cancelled }

    let id: String            // "task-" + UUID 前缀
    /// prompt 首行 ≤48 chars
    let title: String
    let prompt: String
    let images: [String]
    let createdAt: Date
    var runState: RunState = .queued
    var outcome: Outcome = .none
    var lastError: String?
    /// 子 agent onEvent(.toolStarted) 驱动（§5.4：任务卡进度读 scheduler 记录，
    /// 不需要 .taskProgress 事件）。
    var lastToolName: String?
    var usage: BrainUsage?
    var retried: Int = 0

    /// stage.ts:9-21 直译。hasPendingAsk 由调度器从 Approval/UserInput 中心
    /// **查询**派生（§5.7），不依赖事件到达顺序。
    func stage(hasPendingAsk: Bool) -> Stage {
        if runState == .ended {
            return outcome == .completed ? .completed
                 : outcome == .failed ? .failed : .cancelled
        }
        if runState == .running, hasPendingAsk { return .awaitingUser }
        return runState == .running ? .running : .queued
    }
    var canRetry: Bool { runState == .ended && outcome != .completed }
}

/// Brain 并行任务调度器（设计文档 §3/§5.2）——三条并发车道里的任务车道
/// （K = maxConcurrent 个 slot，排队溢出）+ 人车道（人消息与任务应答永不
/// 排队成任务、永不被任务挤占）。单飞 pump（dsh passes.ts:56-62 直译），
/// 事件驱动、无定时器。整个类 @MainActor：runState 迁移全部在
/// finishTask/pump 单点发生。
@MainActor
@Observable
final class BrainTaskScheduler {
    static let defaultMaxConcurrent = 2
    /// UserDefaults 持久化（§5.2）。
    var maxConcurrent: Int = {
        let stored = UserDefaults.standard.integer(forKey: "brain.task.maxConcurrent")
        return stored > 0 ? min(stored, 8) : BrainTaskScheduler.defaultMaxConcurrent
    }() {
        didSet {
            let clamped = max(1, min(maxConcurrent, 8))
            if clamped != maxConcurrent { maxConcurrent = clamped; return }
            guard maxConcurrent != oldValue else { return }
            UserDefaults.standard.set(maxConcurrent, forKey: "brain.task.maxConcurrent")
            pump()
        }
    }

    /// 只含未结束任务（queued/running）。ended 的结果以 transcript 的
    /// taskResult 行呈现。
    private(set) var tasks: [BrainTask] = []
    /// 最近结束任务的提示记录（cap 10）——transcript 结果行的「重试」按钮
    /// 据此重发同 prompt。
    private(set) var recentEnded: [BrainTask] = []
    /// 人车道队列：主 agent 忙时排队，`.turnSettled` 续发（§5.3）。
    private(set) var pendingPerson: [PendingPersonMessage] = []

    struct PendingPersonMessage: Identifiable {
        let id = UUID()
        let text: String
        let images: [String]
        /// flush 已为本消息发起 trySubmit（占位竞速中，占位成功即已开跑）：
        /// 行渲染为「发送中」、✕ 不可撤回；占位失败时复位回「待发送」。
        /// 同步标记（早于 Task 内的 trySubmit），杜绝 turn 结束的
        /// .turnSettled 抢在本 Task 恢复之前把同一条消息二次提交。
        var claimed = false
    }

    struct ChildRun {
        let agent: BrainAgent
        /// 任务启动时快照的结果投递目标（= 当时 store.brain）。会话切换后
        /// 收尾仍投回原会话。weak：生命周期由 taskTargets 强引用负责。
        weak var targetMainAgent: BrainAgent?
        var runTask: Task<Void, Never>?
    }

    /// 结账后即移除的账本。
    @ObservationIgnored private var children: [String: ChildRun] = [:]
    /// 投递目标账本：submitTask 时快照 mainAgent（强引用，结账/清理时移除）。
    /// 排队任务被取消时同样需要目标来 ingest 结果行（rev.3 #4/#17）。
    @ObservationIgnored private var taskTargets: [String: BrainAgent] = [:]
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pumpAgain = false
    /// store 每次 swap 后重绑。
    @ObservationIgnored weak var mainAgent: BrainAgent?

    /// 任务车道事件外发钩子（§5.4 新 case 的观察点）。PetBus 聚合公告在公告
    /// 点直发（§5.8），不经过主 agent 的 onEvent——无环、不双播。
    @ObservationIgnored var onTaskEvent: ((BrainEvent) -> Void)?
    /// 排队人消息成功发出后回调（ChatView 挂 store.syncCurrentSession）。
    @ObservationIgnored var onPersonSubmitted: (() -> Void)?

    var hasActive: Bool { !tasks.isEmpty || !pendingPerson.isEmpty }

    // MARK: - 任务车道

    /// 入队即落盘 prompt 行（§5.2）：writer 惰性建（ingestUserMessage 内），
    /// 用户立刻看到自己发了什么；纯任务会话重启后历史不丢；与排队取消的
    /// cancelled 结果行首尾呼应。
    @discardableResult
    func submitTask(_ text: String, images: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return "" }
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        let task = BrainTask(
            id: "task-" + UUID().uuidString.prefix(8).lowercased(),
            title: String(firstLine.trimmingCharacters(in: .whitespaces).prefix(48)),
            prompt: text,
            images: images,
            createdAt: Date())
        tasks.append(task)
        taskTargets[task.id] = mainAgent
        mainAgent?.ingestUserMessage(text: text, images: images)
        onTaskEvent?(.taskQueued(taskID: task.id, title: task.title))
        pump()
        return task.id
    }

    /// 单飞调度（passes.ts:56-62 直译）：并发请求合并；无定时器。
    /// slot 在 pump 的判断之后同步占用——两个 start 不可能抢同一槽
    /// （dsh reserve 的同步预留语义）。
    private func pump() {
        if pumping {
            pumpAgain = true
            return
        }
        pumping = true
        while true {
            let running = tasks.filter { $0.runState == .running }.count
            guard running < maxConcurrent,
                  let next = tasks.first(where: { $0.runState == .queued }) else { break }
            startChild(next)
        }
        pumping = false
        if pumpAgain {
            pumpAgain = false
            pump()
        }
    }

    private func startChild(_ task: BrainTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }),
              tasks[index].runState == .queued else { return }
        tasks[index].runState = .running
        let target = taskTargets[task.id] ?? mainAgent
        let child = target?.makeTaskChild(taskID: task.id)
            ?? BrainAgent.makeDefaultChild(taskID: task.id)
        child.announcesToPet = false    // §5.8：子 agent 静音，公告由 scheduler 聚合
        child.onEvent = { [weak self, taskID = task.id] event in
            Task { @MainActor in self?.handleChildEvent(taskID, event) }
        }
        onTaskEvent?(.taskStarted(taskID: task.id, title: task.title))
        refreshTaskSummary(event: L("Starting task:") + " \(task.title)")
        let run = Task { [weak self, child, task] in
            var prompt = task.prompt
            var images = task.images
            var attempt = 0
            while !Task.isCancelled {
                _ = await child.trySubmit(prompt, images: images)   // 原子占位（§5.3）
                if Task.isCancelled { break }                       // 取消点：先于 lastError 分类复查——cancelTask 标记本 Task 后不再续发
                if child.lastError == nil { break }                 // 成功
                if child.lastError == "cancelled" { break }         // 取消 → 结账为 cancelled
                guard !Task.isCancelled, Self.isTransient(child.lastError ?? ""), attempt < 3 else { break }
                attempt += 1
                try? await Task.sleep(for: .seconds(5 * pow(2, Double(attempt - 1))))  // 取消点：立即退出
                guard !Task.isCancelled else { break }
                prompt = "继续"                                     // dsh resumeAfter 直译
                images = []                                         // 子 agent 历史完整保留
            }
            await MainActor.run {
                self?.finishTask(task.id, child: child, target: self?.taskTargets[task.id])
            }
        }
        children[task.id] = ChildRun(agent: child, targetMainAgent: target, runTask: run)
    }

    /// 子 agent 事件接线（§5.2/§5.8）：lastToolName 直接写；审批公告带任务名；
    /// 事件乱序只影响显示，不影响状态机（runState 迁移全在 finishTask/pump）。
    private func handleChildEvent(_ taskID: String, _ event: BrainEvent) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        switch event {
        case .toolStarted(let name, _):
            tasks[index].lastToolName = name
        case .approvalRequested(let name, _):
            PetBus.shared.say(L("Needs your approval:") + " \(name) · \(tasks[index].title)",
                              state: .talking)
        default:
            break
        }
    }

    /// 唯一结账点，幂等，child 可空（rev.3 #17）：排队任务取消走
    /// child: nil 路径（无并发写者，幂等 guard 覆盖其余竞态）。
    private func finishTask(_ id: String, child: BrainAgent?, target: BrainAgent?) {
        guard var task = tasks.first(where: { $0.id == id }), task.runState != .ended else { return }
        // 分类：child==nil（排队中直接取消）→ .cancelled；
        //       child.lastError == "cancelled" → .cancelled；非 nil → .failed；否则 .completed
        if child == nil || child?.lastError == "cancelled" {
            task.outcome = .cancelled
        } else if child?.lastError != nil {
            task.outcome = .failed
        } else {
            task.outcome = .completed
        }
        task.runState = .ended
        task.lastError = child?.lastError
        task.usage = child?.lastUsage
        tasks.removeAll { $0.id == id }
        recentEnded.append(task)
        if recentEnded.count > 10 { recentEnded.removeFirst() }
        children[id] = nil                       // 释放子 agent（deinit stopAll）与账本
        taskTargets[id] = nil                    // 释放目标快照
        let summary = Self.summarize(child, outcome: task.outcome)
        target?.ingestTaskResult(taskID: task.id, title: task.title,
                                 status: task.outcome.rawValue, summary: summary,
                                 usage: task.usage)
        // PetBus 聚合公告（§5.8 显示优化）：不再逐条 say() 抢占气泡——
        // 计数 + 最近事件一行，经 announceTask 的呈现纪律（不打断流式/审批、
        // 一批事件只弹一次、点掉后安静）。子 agent 自身静音。
        switch task.outcome {
        case .completed:
            if tasks.isEmpty {
                // 批次收尾：突破点掉状态庆祝一次，气泡随后自动隐藏
                refreshTaskSummary(event: L("Task done:") + " \(task.title)",
                                   state: .celebrating, force: true)
            } else {
                refreshTaskSummary(event: "✓ " + task.title)
            }
        case .failed:
            var failedLine = "✗ " + task.title
            if let error = task.lastError { failedLine += " — " + String(error.prefix(60)) }
            refreshTaskSummary(event: failedLine, state: .sad, force: true)
        case .cancelled:
            refreshTaskSummary(event: "– " + task.title)
        case .none:
            break
        }
        onTaskEvent?(.taskEnded(taskID: task.id, title: task.title, status: task.outcome.rawValue))
        pump()
    }

    /// 任务车道气泡摘要（并行任务显示优化）：组装「计数 · 最近事件」一行
    /// 交 PetBus.announceTask——呈现纪律（不打断流式/审批、合并弹窗、点掉
    /// 后安静、force 突破）都在 PetBus，这里只提供真相（tasks 计数 +
    /// ApprovalCenter 派生的等待数）。
    private func refreshTaskSummary(event: String? = nil,
                                    state: PetState? = nil,
                                    force: Bool = false) {
        guard !tasks.isEmpty else {
            if let event { PetBus.shared.announceTask(event, state: state, force: force) }
            return
        }
        let running = tasks.filter { $0.runState == .running }.count
        let awaiting = tasks.filter {
            $0.runState == .running && ApprovalCenter.shared.hasRequest(source: $0.id)
        }.count
        let queued = tasks.count - running
        var parts: [String] = []
        if running > 0 { parts.append("\(running) " + L("Running")) }
        if awaiting > 0 { parts.append("\(awaiting) " + L("Waiting for you")) }
        if queued > 0 { parts.append("\(queued) " + L("Queued")) }
        var line = L("Tasks") + " · " + parts.joined(separator: " · ")
        if let event { line += "\n" + event }
        PetBus.shared.announceTask(line, state: state, force: force)
    }

    /// 结账摘要：最后一条 assistant message / lastError；排队未开始另有措辞。
    private static func summarize(_ child: BrainAgent?, outcome: BrainTask.Outcome) -> String {
        guard let child else { return L("Task was cancelled while queued (never started).") }
        if let error = child.lastError {
            return L("Task failed:") + " \(error)"
        }
        let last = child.items.last { item in
            if case .message("assistant", _) = item { return true }
            return false
        }
        if case .message(_, let text)? = last, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return L("Task finished without a text answer.")
    }

    /// 瞬时错误分类（§4 #7）：dsh.ts:44-55 判定集的字符串等价物——
    /// 408/429/500-599/timed out/timeout/connection/reset/refused/network。
    static func isTransient(_ error: String) -> Bool {
        let lowered = error.lowercased()
        let markers = ["408", "429", "timed out", "timeout", "connection",
                       "reset", "refused", "network"]
        if markers.contains(where: { lowered.contains($0) }) { return true }
        return (500...599).contains { lowered.contains(String($0)) }
    }

    /// 取消单个任务（§6）：运行中——先按 source deny 在途审批/提问（子
    /// agent 可能停在不可取消的 continuation 上，runTask.cancel/agent.cancel
    /// 都到不了它——不 deny 则任务卡与审批卡滞留、僵尸审批仍可被批准执行
    /// 破坏性动作），continuation 返回后 runLoop 在下一检查点展开、经唯一
    /// finishTask 结账；排队中——直接 child:nil 结账。不存在第二条结账路径。
    func cancelTask(id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if tasks[index].runState == .queued {
            finishTask(id, child: nil, target: taskTargets[id])
            return
        }
        ApprovalCenter.shared.dismissForSource(id)
        UserInputCenter.shared.dismissForSource(id)
        children[id]?.runTask?.cancel()
        children[id]?.agent.cancel()
    }

    /// 「重试」按钮（§4 #7 等价 dsh Retry）：重发同 prompt。
    @discardableResult
    func retry(taskID: String) -> String? {
        guard let ended = recentEnded.first(where: { $0.id == taskID }), ended.canRetry else {
            return nil
        }
        return submitTask(ended.prompt, images: ended.images)
    }

    /// Stop 按钮语义（§5.2/rev.3 #6）：cancelAll + pendingPerson.removeAll——
    /// 用户表达"全部停止"，排队人消息一并放弃（否则 brain.cancel() 的
    /// .turnSettled 会立即续发，违背意图）。cancelAll 本身不清队列，
    /// 两种语义分离。
    func stopEverything() {
        cancelAll()
        pendingPerson.removeAll()
    }

    /// 只取消排队+运行中任务，不触碰对话车道（§4 #9）。运行中任务与
    /// cancelTask 同样先 deny 在途审批/提问（切会话/关窗路径的僵尸清理——
    /// 否则滞留审批跨会话渲染、slot 被占）。
    private func cancelAll() {
        for task in tasks.filter({ $0.runState == .queued }) {
            finishTask(task.id, child: nil, target: taskTargets[task.id])
        }
        for task in tasks.filter({ $0.runState == .running }) {
            ApprovalCenter.shared.dismissForSource(task.id)
            UserInputCenter.shared.dismissForSource(task.id)
            children[task.id]?.runTask?.cancel()
            children[task.id]?.agent.cancel()
        }
    }

    /// 会话删除（ChatSessionStore.deleteAll）：把该会话仍在账本里的目标主
    /// agent（taskTargets 快照，强持有至异步结账完成）与子 agent（children
    /// 账本）的 Writer 失效——文件删除后的 append 会用 Writer 兜底分支重建
    /// 无 sessionMeta 头的孤儿文件。账本恰是删除时唯一能触达这些实例的点
    /// （store 已换新 agent、异步结账尚未发生）。
    func invalidateWriters(parentSessionID: String) {
        for target in taskTargets.values where target.sessionID == parentSessionID {
            target.invalidateRollout()
        }
        for run in children.values
        where run.agent.sessionID.hasPrefix("\(parentSessionID)-t") {
            run.agent.invalidateRollout()
        }
    }

    /// 会话切换/新建前调用（§5.10）：stopEverything，运行中任务的账本由其
    /// 异步结账自清（目标快照保留到结账完成——被取消任务的结果投回旧会话，
    /// 不写进新会话；原 agent 实例被快照持有至结账完成）。
    func resetForSessionChange() {
        stopEverything()
    }

    /// 窗口关闭（onDisappear）调用：stopEverything；brain.cancel 由 store 编排
    /// （§5.10 shutdownForClose）。
    func shutdown() {
        stopEverything()
    }

    // MARK: - 人车道（§5.3）

    /// 人车道唯一入口：主 agent 空闲即发，忙即排队——不吞消息。
    func submitPerson(_ text: String, images: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        pendingPerson.append(PendingPersonMessage(text: text, images: images))
        flushPerson()
    }

    /// flush 语义：每次触发只认领队头一条（同步标 claimed，单飞——已 claim
    /// 的消息不重复发起，避免 .turnSettled 时序下的二次提交）；trySubmit 的
    /// 原子占位仍是唯一仲裁。占位失败（并发抢占）→ 复位 claimed 留在队列，
    /// 由下一个 .turnSettled 续发——不吞消息、保持 FIFO。占位成功即已开跑，
    /// 行随真实气泡转入「发送中」态。
    private func flushPerson() {
        guard let agent = mainAgent, let first = pendingPerson.first else { return }
        guard !first.claimed else { return }   // 已有在途 flush，不重复发起
        pendingPerson[0].claimed = true
        Task { [weak self] in
            guard let self else { return }
            let ok = await agent.trySubmit(first.text, images: first.images)
            guard ok else {
                // 占位失败：留在队列，复位回「待发送」，等待下一次 .turnSettled。
                if let index = self.pendingPerson.firstIndex(where: { $0.id == first.id }) {
                    self.pendingPerson[index].claimed = false
                }
                return
            }
            self.pendingPerson.removeAll { $0.id == first.id }
            self.onPersonSubmitted?()
            // .turnSettled 在 trySubmit 返回之前 emit（runTask 内、清 flag 后），
            // 先于本 Task 恢复到达且撞上 claimed 早退——续发必须在这里补一刀，
            // 否则下一条排队消息滞留到无关事件。
            self.flushPerson()
        }
    }

    /// 待发送行 ✕ 撤回（§5.3）：只对仍在排队的消息有效——已 claim 的消息
    /// 占位成功即已开跑，撤回行不取消执行（无法撤回，故入口直接拒绝）。
    func recallPendingPerson(id: UUID) {
        guard let index = pendingPerson.firstIndex(where: { $0.id == id }),
              !pendingPerson[index].claimed else { return }
        pendingPerson.remove(at: index)
    }

    /// 主 agent 事件入站（§5.10：makeAgent 的 onEvent 转发，含 .turnSettled）。
    /// 任务车道事件由子 agent 的 onEvent 单独进来，不经此处（无环）。
    func handleMainEvent(_ event: BrainEvent) {
        switch event {
        case .turnSettled:
            // 可靠空闲信号（清 flag 后同步 emit）：续发排队人消息 + 事件驱动补位。
            flushPerson()
            pump()
        default:
            break
        }
    }

    /// 「等待你」派生（§5.7）：从 Approval/UserInput 中心按 source 查询——
    /// 单一代码评审点，无事件乱序问题。视图在 body 里调用本方法即可随
    /// 两中心的 @Observable 状态联动。
    func stage(of task: BrainTask) -> BrainTask.Stage {
        let hasPendingAsk = ApprovalCenter.shared.hasRequest(source: task.id)
            || UserInputCenter.shared.hasRequest(source: task.id)
        return task.stage(hasPendingAsk: hasPendingAsk)
    }

    /// 审批/提问卡片的来源徽标（§5.7）：source=taskID → 「任务：标题」；
    /// 主 agent（nil）由调用方显示「对话」。查不到任务（已切会话）退化为
    /// 泛化的「任务」。
    func sourceLabel(for source: String?) -> String? {
        guard let source else { return nil }
        let title = tasks.first { $0.id == source }?.title
            ?? recentEnded.first { $0.id == source }?.title
        return title.map { L("Task") + ": " + $0 } ?? L("Task")
    }
}
