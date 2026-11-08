import Foundation
import Observation

/// Chat window session management — one Brain session per chat, backed by
/// the rollout store: list / new / switch (resume) / delete. Plus the
/// parallel-task scheduler (设计文档 §5.10): the conversation lane keeps the
/// single live `brain`; the task lane spawns child agents per task.
/// @MainActor（§5.12）：scheduler 是 @MainActor，store 的状态本就只在主线程
/// 变更（refresh 的 MainActor.run），唯一构造点是 ChatView 的 @State。
@MainActor
@Observable
final class ChatSessionStore {

    struct SessionInfo: Identifiable, Equatable {
        let id: String
        var title: String
        var date: Date
        var itemCount: Int
        var isBrain: Bool = true
    }

    private(set) var sessions: [SessionInfo] = []
    /// True count of on-disk sessions with content — the list above is the
    /// capped recent window, NOT the total (with 60+ rollouts the footer
    /// read as "delete doesn't work" because it never moved off the cap).
    private(set) var totalSessions = 0
    /// The live agent for the active conversation. Swapped on switch/new.
    private(set) var brain: BrainAgent
    private(set) var currentSessionID: String?
    /// 并行任务调度器（§5.10）：任务车道 + 人车道。mainAgent 在每次 swap 后
    /// 由本 store 重绑。
    private(set) var scheduler = BrainTaskScheduler()

    init() {
        brain = ChatSessionStore.makeAgent()
        wireAgent(brain)
        scheduler.mainAgent = brain
        // §5.6：人消息成功发出后同步侧栏（恢复旧 send() 逐轮
        // syncCurrentSession 的时序——新会话首条人消息落盘建会话后，
        // 会话出现在列表、标题/条数更新，不再滞留到下一次无关 refresh）。
        scheduler.onPersonSubmitted = { [weak self] in self?.syncCurrentSession() }
        refresh()
    }

    private static func makeAgent(resuming sessionID: String? = nil) -> BrainAgent {
        let agent = BrainAgent()
        if let sessionID {
            agent.resume(sessionID: sessionID)
        }
        return agent
    }

    /// 宠物公告接线（原 makeAgent 内联闭包，语义原样）+ 调度器转发（§5.10）：
    /// onEvent 在现有 switch 后追加转发给 scheduler（含 .turnSettled）——
    /// 接线跟随 agent 而不是视图，切换/新建不丢公告。
    private func wireAgent(_ agent: BrainAgent) {
        agent.onEvent = { [weak self] event in
            // §5.12：emit 在非隔离上下文同步调用本闭包（.turnSettled 从非隔离
            // runTask、全局执行器发出）——必须显式跳回主线程再碰 scheduler /
            // PetBus，否则 pendingPerson/tasks/pumping 在后台线程被读写，与
            // SwiftUI 渲染、submitPerson/cancelTask 并发。与 startChild 的
            // 子 agent 接线（Task { @MainActor in … }）同构。
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .error(let message):
                    // Sad pose, not idle — a failure used to look like nothing
                    // happened (the sad sticker was dead code until now).
                    PetBus.shared.say(L("Oops, error:") + " \(message.prefix(60))", state: .sad)
                case .approvalRequested(let name, _):
                    PetBus.shared.say(L("Needs your approval:") + " \(name)", state: .talking)
                default:
                    break
                }
                self.scheduler.handleMainEvent(event)
            }
        }
    }

    // MARK: - Session list

    func refresh() {
        // Rollout enumeration reads every session file (some carry base64
        // images) — that walk used to run synchronously on the main thread
        // on every window open / send / delete.
        Task.detached {
            let (rollouts, total) = BrainRollout.listSessions(limit: 50)
            let infos = rollouts.map { entry in
                SessionInfo(
                    id: entry.id,
                    title: BrainRollout.titleForSession(sessionID: entry.id)
                        ?? "Session \(L10n.date(entry.date))",
                    date: entry.date,
                    itemCount: entry.itemCount
                )
            }
            await MainActor.run {
                self.totalSessions = total
                self.sessions = infos
            }
        }
    }

    // MARK: - Actions

    /// Start a brand-new conversation. The rollout file is created lazily by
    /// the first submit (BrainAgent.submit begins the session) — an abandoned
    /// "+" click leaves zero junk on disk.
    func newSession() {
        // §5.10 顺序：先 resetForSessionChange（stopEverything：cancelAll +
        // pendingPerson 清空）再 cancel/换 agent——顺序保证被取消任务的目标
        // 快照仍指旧 agent，且人队列不会把旧对话的话发进新对话（评审 #11）。
        scheduler.resetForSessionChange()
        if brain.isRunning { brain.cancel() }
        brain = ChatSessionStore.makeAgent()
        wireAgent(brain)
        scheduler.mainAgent = brain
        currentSessionID = brain.sessionID
        refresh()
    }

    /// Switch to (resume) an existing rollout session.
    func resume(_ info: SessionInfo) {
        scheduler.resetForSessionChange()
        if brain.isRunning { brain.cancel() }
        brain = ChatSessionStore.makeAgent(resuming: info.id)
        wireAgent(brain)
        scheduler.mainAgent = brain
        currentSessionID = info.id
    }

    /// Delete a rollout from disk; if it is the active session start a new one.
    func delete(_ info: SessionInfo) {
        deleteAll([info.id])
    }

    /// Batch-delete rollouts from disk; if the active session is among them
    /// start a new one (single-delete shares this path).
    func deleteAll(_ ids: [String]) {
        // 先取消、后删文件（顺序即修复）：newSession 内 resetForSessionChange
        // 会 cancelAll + 清人队列并换上新 agent。反序（先删后换）时，仍在跑
        // 的旧主 agent/子 agent 会在文件删除后继续 append——Writer 兜底分支
        // 用单条记录重建无 sessionMeta 头的孤儿 JSONL（load() 读到即 nil、
        // listSessions 跳过、侧栏不可见、无删除入口）。
        if let current = currentSessionID, ids.contains(current) {
            let retiredBrain = brain
            newSession()
            // 无任务快照持有时调度器账本触达不了旧 agent——主 turn 取消后
            // 展开中的 append 仍会发生，需单独失效。
            retiredBrain.invalidateRollout()
        }
        // 全量先失效、再删除（顺序即修复之二）：失效必须先于子文件删除——
        // 否则被取消子 agent 异步展开中的 append（dismissForSource 恢复
        // continuation → runLoop 下一检查点展开 → 收尾的 writer.append）会
        // 落进「子文件已删、Writer 未失效」的窗口，Writer 兜底分支重建无
        // sessionMeta 头的孤儿 JSONL（主文件在失效后重删自愈，子文件不会）。
        // 账本里已结账出场的子 agent 无需失效——其展开已结束、不再 append。
        for id in ids {
            scheduler.invalidateWriters(parentSessionID: id)
        }
        // 任务子会话 rollout（§5.9：<parent>-t<8hex>.jsonl）随主会话一并删除：
        // 它们被 listSessions 按 originator 过滤（侧栏不可见、无独立删除入口），
        // 只删主文件会把全部任务子轨迹留成孤儿。"-t" 前缀不会误伤主会话——
        // 主 sessionID 是纯 UUID（十六进制，不含 "-t"）。
        let childPrefixes = ids.map { "\($0)-t" }
        if !childPrefixes.isEmpty,
           let files = try? FileManager.default.contentsOfDirectory(
               at: BrainRollout.directory, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "jsonl"
                && childPrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for id in ids {
            try? FileManager.default.removeItem(at: BrainRollout.fileURL(for: id))
        }
        refresh()
    }

    /// Called after the first user message of a fresh session so the sidebar
    /// title updates and the session appears in the list.
    func syncCurrentSession() {
        if currentSessionID != brain.sessionID {
            currentSessionID = brain.sessionID
        }
        refresh()
    }

    /// 窗口关闭生命周期（§5.10，评审 #12）：关窗即终止一切在跑工作——
    /// 「切换即取消」同一哲学；app 退出由进程终止兜底。
    /// 顺序与 newSession 相同的理由（rev.3 #6）：先停调度器（清人队列 +
    /// 取消任务），再 brain.cancel()——否则 cancel 的 .turnSettled 会把
    /// 尚未清空的排队人消息立刻发出去。
    func shutdownForClose() {
        scheduler.shutdown()
        if brain.isRunning { brain.cancel() }
    }
}
