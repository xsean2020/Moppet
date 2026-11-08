# Moppet Brain 并行任务执行架构设计（rev.3）

状态：设计稿（未实施）。rev.2 依据评审意见修订：修正 R3 数据竞态误判、人车道触发时序、取消双重结账、ToolRegistry 宠物气泡泄漏、审批排队超时漏洞、submit 原子占位、纯任务会话落盘等 13 项。rev.3 再修 7 项：UserInputCenter 队列与 300s 计时的矛盾、compactNow 不发 .turnSettled、审批计时器双源冲突、排队任务取消结账路径、伪码符号/落盘时机统一、Stop 覆盖人队列、R8 工作量修正（逐条见 §11 修订记录）。
参考原型：`dsh-superagent-prototype/`（Ticket 状态机、WorkerSlots、Effects 队列、Passes 单飞调度）。
基线：当前 `main`（`swift build` 已验证通过，exit 0）上增量落地，不破坏现有公共 API。

---

## 0. 影响面核实（GitNexus MCP，设计前实际执行）

按项目 AGENTS.md 要求，对将改动的关键符号跑 `impact`（MCP `mcp__gitnexus-mcp__impact`，repo=Moppet，direction=upstream，summaryOnly）：

| 目标 | 结果 |
| --- | --- |
| `BrainAgent`（Class） | **CRITICAL**，受影响 104 个符号（d=1: 96，d=2: 5，d=3: 3），epistemic=exact；受影响执行流包括 `ChatView.handleSlash`、`sessionRow`、`batchDeletionConfirm`、`BrainExec.run`。索引比 HEAD 落后 4 个 commit（关键行号已按工作树逐行复核） |
| `ChatSessionStore`（Class） | **CRITICAL**，受影响 94 个符号（d=1: 93），epistemic=exact |
| `BrainAgent.submit`（Function） | **HIGH**，受影响 8 个符号，4 个直接调用方：`QuickChat.submit`（Sources/Moppet/App/QuickChat.swift:96）、`BrainExec.run`（Sources/Moppet/Brain/BrainExec.swift:53）、`ChatView.send`（Sources/Moppet/Views/ChatView.swift:899）、`BrainSlash` /init（Sources/Moppet/Brain/BrainSlash.swift:32） |

结论：`BrainAgent` 是全应用最热符号，**任何"在 runLoop 内部并行化"的方案都会把 104 个符号的 CRITICAL 面变成实际改动面**。本设计把并行性放在**组合层（多实例）而不是内部（单实例多 loop）**——runLoop 结构不动，`BrainAgent` 的改动收敛为六类小增量：items 写点统一加锁（§5.5）、submit 原子占位 `trySubmit`（§5.3）、`.turnSettled` 空闲信号（§5.4）、`announcesToPet` 门控（§5.8）、任务结果注入 API（§5.5）、`makeTaskChild`（§5.12）。

---

## 1. 现状（已核实的代码事实）

- 单任务门：`BrainAgent.submit`（BrainAgent.swift:400）`guard !isRunning`（:401）拒绝运行中的新输入——消息被静默吞掉；`ChatView.send` 二次拦截（ChatView.swift:895），Send 按钮 `disabled: brain.isRunning`（:790），运行中只显示 Stop（:541-545），header 单个 ProgressView（:453-455）。
- runLoop 完全串行：`for _ in 0..<maxTurnsPerSubmit`（BrainAgent.swift:805）；轮内唯一并行是工具 task-group（:895-917）。
- **items 写点不统一**：`itemsLock` 只保护 `emit(.planUpdated)`（BrainAgent.swift:998-1011）；runLoop 的 assistant/call/output 追加（:858-867、:921-939）、submit 的 user/图片追加（:412-417）、compactHistoryIfNeeded/compactNow 的整体换血（:496-511、:528-555）全部无锁。单 agent 时代单写者线程可容忍；**多写者（任务结果注入）下并发 append Swift Array 是 UB**（EXC_BAD_ACCESS/数据损坏）。
- loopGeneration 所有权：submit 捕获 generation，收尾仅当 `generation == loopGeneration` 才清 `isRunning/runTask`（:427-437）；`cancel`/`compactNow` 靠 bump generation 夺权（:447-450、:525-527）。
- **submit 无原子占位**：submit 是非隔离 async（SE-0338 切到全局并发执行器），`guard !isRunning`（:401）到 `isRunning = true`（:423）之间含 beginSession/写 rollout 的文件 I/O——两个并发调用方可同时通过 guard，形成 BrainAgent.swift:431-433 注释所述的历史事故形态（双 runLoop 交错）。
- 每会话一个 agent：`ChatSessionStore.brain`（ChatSessionStore.swift:23），切换/新建先 `if brain.isRunning { brain.cancel() }`（:84、:92）。
- 审批队列：`ApprovalCenter` 单 pending + queued、`OnceContinuation`、超时 Task **只 deny 当前 pending**（PetBus.swift:270-277 `if self.pending?.id == requestID`）——排队中的请求计时器到点 no-op，`presentNext`（:281-287）不重设计时器，**排队审批永不超时**。
- `request_user_input` 是**无队列的单 pending 槽**（BrainUserInput.swift:43、151-163）：并发第二个请求覆盖第一个卡片；且该工具全程不发 BrainEvent（dispatch 不传 emit，BrainTools.swift:373；handler BrainTools.swift:798-832）。
- **ToolRegistry 直呼 PetBus**：`execute` 的 `setState(.thinking)` + `defer settle()`（ToolRegistry.swift:127-128）；scan_clean 的两条 say（:229、:234）、execute_clean 的两条 say（:262、:278）。`PetBus.say` 会把 `streamingDismissed` 重置为 false（PetBus.swift:66）——后台任务的工具公告会顶掉正在流式的主对话气泡、并重新弹出用户已点掉的 QuickChat 气泡。注意审批入口：Brain 的清洁工具审批走 `runCleaningTool` → `requestApproval`（BrainTools.swift:617-634，有 context 可透传 source），再以 `.confirmedFlag` 调 execute（:631）；ToolRegistry 的 `.ui` 审批分支（ToolRegistry.swift:119-124）唯一调用方是旧版 `AIAgent.swift:744`，**Brain 不经过它**。
- PetBus 全局单气泡（PetBus.swift:24-31），`BrainAgent` 多处直呼（BrainAgent.swift:421、453、831、874-879、904）。
- 独立 agent 入口已存在：QuickChat 自有 `BrainAgent`（QuickChat.swift:19）；`BrainExec` 无 UI 一次性 agent（BrainExec.swift:19）。
- rollout：每 session 一个 JSONL，`Writer.append` 有 appendLock（BrainRollout.swift:125-131）；`listSessions` 全量枚举（:181-203）；解码对未知行 `try?` 跳过（:253）；主 agent 的 writer 在 submit 内惰性创建（BrainAgent.swift:405）。
- `ChatView.brainBubble` 对 `BrainResponseItem` 的 switch 无 default（ChatView.swift:1027-1044）——新增 case 会编译失败（护栏），渲染 case 必须补。
- 聊天窗有显式关闭按钮（ChatView.swift:458 dismiss）；store 是 ChatView 的 `@State`（:61），关窗即销毁；`onDisappear` 在关窗时触发（:154-156 现用它清 chatSurfaceVisible）。

## 2. 目标（用户需求 → 架构约束）

1. 同一会话可同时提交多个任务并行执行，有并发上限（slot 模型）。
2. 对话式消息不排队成任务；任务结果完成后自然落回对话流。
3. 任务卡片（排队/执行中/完成/失败）+ 进行中状态；完成结果写进 transcript。
4. mustPreserve 清单一项都不能坏（§7 逐项对照）。

## 3. 总体架构

```
ChatView (SwiftUI, @Observable 读)
   │  send(): 三路分流（§5.6）
   ▼
ChatSessionStore ──── brain: BrainAgent          ← 对话车道（永远 1 个，现有实例）
   │                  ├─ .taskResult 落盘（ingestUserMessage / ingestTaskResult）
   │                  └─ onEvent → 宠物公告（现状不动）+ 转发 scheduler（含 .turnSettled）
   └── scheduler: BrainTaskScheduler (@MainActor, 新增)
          ├─ tasks / recentEnded                  ← 任务车道（K = maxConcurrent，默认 2）
          │     每个任务一个子 BrainAgent（独立 rollout 文件）
          ├─ pendingPerson: [PendingPersonMessage] ← 人车道：主 agent 忙时排队，.turnSettled 续发
          └─ pump()：单飞调度（passes.ts 映射），事件驱动，无定时器

ApprovalCenter / UserInputCenter  ← 全局共享；source 归属标签 + 排队超时修复（§5.7）
ToolRegistry                      ← execute 增 quiet；工具路径的 PetBus 公告按来源静音（§5.8）
PetBus                            ← 子 agent 静音（announcesToPet=false），scheduler 聚合公告
```

三条并发车道：
- **对话车道**：主 `BrainAgent`，现有 turn 语义不变（§5.3 原子占位加固）。
- **任务车道**：每个任务一个**子 `BrainAgent` 实例**，`maxConcurrent`（默认 2）个 slot，排队溢出。
- **人车道**：人消息与任务应答**永不排队成任务、永不被任务挤占**——对话有专属车道；任务内提问/审批通过 continuation 恢复，不占新 slot（dsh "person 额外槽位"的结构化等价物，§4.1）。

## 4. superagent 机制 → Brain 落地映射

| # | dsh-superagent 机制（出处） | Moppet 落地 | 差异与理由 |
| --- | --- | --- | --- |
| 1 | **WorkerSlots 并发上限 + 人的消息保留超额槽**：`reserve(ticketId, 'launch'\|'wake'\|'person')` 同步预留，`person` 可占 `max+1`（src/executor/dsh.ts:171-199，reserve :192-196；docs/003-execution.md「Concurrency」） | `BrainTaskScheduler.maxConcurrent`（默认 2）限制任务车道；人消息走独立对话车道，结构上不可能被任务挤占；任务内审批/提问靠 continuation 恢复、不占 slot | dsh 的 person 槽是"唤醒已存在 worker"的额度；Moppet 对话是常驻独立车道，等价保证更强（永远有 1 个槽），无需 max+1 的负数逻辑 |
| 2 | **持久化 Effects 队列**：同 kind+key UPSERT 合并、`Later` 只推迟不计失败、真失败才指数退避（src/app/effects.ts:61-66、103-122、138-141） | 任务入队为内存队列 + `queuedAt` 排序（不做 SQLite 持久化队列）；"暂不能执行"（slot 满）与"真失败"严格分离：排队不算失败、不计重试预算，卡片显示「排队中」 | Moppet 任务生命周期 = 一次窗口/会话会话期（切会话、关窗即取消，与现状 `ChatSessionStore.swift:84/92` 一致），持久化队列收益不抵复杂度；崩溃丢未完成任务，与今天丢运行中 turn 同级 |
| 3 | **Ticket 阶段是派生表**：`ticketStage()` 从事实自上而下第一条命中（src/core/stage.ts:9-21），canRetry 同样派生（:24-26） | `BrainTask.stage` 纯函数；「等待你」子态从 `ApprovalCenter/UserInputCenter` 的 source 查询派生（§5.7），不依赖事件顺序 | 完全同构。派生而非存储枚举，杜绝状态漂移与事件乱序问题 |
| 4 | **Assignment 独立 pending→running→ended**（docs/001-domain.md:35-36；src/core/assignments.ts:34-43） | `BrainTask.runState` 独立于子 agent 的 `isRunning`；结账单点（run Task 收尾）且幂等（§5.2）；结果投递进任务启动时快照的主 agent | 「恰好一次」由幂等 + 单点结账保证；投递目标在任务启动时快照，会话切换不会串 |
| 5 | **waitsForPerson：自动输入挂起 + 人消息直达唤醒**（src/core/model.ts:349-353；src/core/tickets.ts:234-270） | 任务提问/审批时卡片转「等待你」（从中心查询派生）；用户应答直接 resume continuation（零延迟）；用户在输入框打的字永远进对话车道 | 等价映射。等待期间任务仍占 slot（R1） |
| 6 | **后台任务完成唤醒 + 30 分钟硬上限**（src/executor/background.ts:96-104；src/executor/dsh.ts:601-672） | **不移植 settling look**。Moppet 的长后台作业（`exec_command`）本来就跨 turn 存活（BrainExecSession 300s 生命周期 cap，BrainExecSession.swift:166-168、181-184）；任务结束后无需"同 slot 唤醒"——后续指令就是新的人消息或新任务 | settling look 为"worker 常驻会话"设计；Moppet 任务是一次性 prompt→result |
| 7 | **瞬时错误退避 + "继续"消息续跑**：408/429/5xx/连接类最多 3 次，turn 失败不重启任务而是发"继续"（src/executor/dsh.ts:44-55、548-576） | 子 agent 失败后 scheduler 检查 `child.lastError` 分类：瞬时→延迟 5s×2^n 重发 `child.trySubmit("继续")`（子 agent 历史完整保留）；非瞬时→failed，transcript 结果行给「重试」按钮（等价 dsh Retry） | "继续"续跑复用子 rollout 历史，是 dsh"同一 Executor Session 续跑"的最自然映射 |
| 8 | **单飞 Pass 调度 + 事件触发**（src/app/passes.ts:28、56-62） | `pump()` 单飞：`pumping` + `pumpAgain` 合并并发请求；无 2s tick——事件驱动（入队/取消/任务结束/`.turnSettled`） | 去掉定时器：桌面场景全部状态变化都有明确事件源 |
| 9 | **pause 只挡新分发不打断进行中**（dsh.ts:232-235） | 不设全局 pause（v1）。等价物：`cancelAll()` 只取消排队+运行中任务，不触碰对话车道 | 桌面单用户场景暂无"暂停一切"需求 |

明确**不移植**：Effects 的 SQLite 持久化（生命周期不符）、settling look / 30 分钟上限（见 #6）、Eval 路由器（确定性分流，§5.6）、Ticket 目录/prepare 命令。

## 5. 类型与文件级设计

### 5.1 任务模型（新增 `Sources/Moppet/Brain/BrainTaskScheduler.swift`）

```swift
/// 一个并行任务 = 一次独立的子 BrainAgent 生命周期（dsh 的 Ticket/Assignment 合并体）。
struct BrainTask: Identifiable, Equatable {
    enum RunState: String, Codable { case queued, running, ended }   // 存储态（Assignment 语义）
    enum Outcome: String, Codable { case none, completed, failed, cancelled }
    enum Stage: String { case queued, running, awaitingUser, completed, failed, cancelled }

    let id: String            // "task-" + UUID 前缀
    let title: String         // prompt 首行 ≤48 chars
    let prompt: String
    let images: [String]
    let createdAt: Date
    var runState: RunState = .queued
    var outcome: Outcome = .none
    var lastError: String?
    var lastToolName: String?             // 子 agent onEvent(.toolStarted) 驱动
    var usage: BrainUsage?
    var retried: Int = 0

    /// stage.ts:9-21 直译。hasPendingAsk 由调度器从 Approval/UserInput 中心**查询**派生（§5.7），
    /// 不依赖事件到达顺序。
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
```

### 5.2 调度器（rev.2/rev.3：幂等结账、目标快照、账本清理、取消语义）

```swift
@MainActor @Observable
final class BrainTaskScheduler {
    static let defaultMaxConcurrent = 2
    var maxConcurrent = BrainTaskScheduler.defaultMaxConcurrent   // UserDefaults 持久化
    /// 只含未结束任务（queued/running）。ended 的结果以 transcript 的 taskResult 行呈现。
    private(set) var tasks: [BrainTask] = []
    /// 最近结束任务的提示记录（cap 10）——transcript 结果行的「重试」按钮据此重发同 prompt。
    private(set) var recentEnded: [BrainTask] = []
    private(set) var pendingPerson: [PendingPersonMessage] = []

    struct PendingPersonMessage: Identifiable { let id = UUID(); let text: String; let images: [String] }

    struct ChildRun {
        let agent: BrainAgent
        /// 任务启动时快照的结果投递目标（= 当时 store.brain）。会话切换后收尾仍投回原会话。
        weak var targetMainAgent: BrainAgent?
        var runTask: Task<Void, Never>?
    }
    @ObservationIgnored private var children: [String: ChildRun] = [:]   // 结账后即移除
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private weak var mainAgent: BrainAgent?          // store 每次 swap 后重绑

    func submitTask(_ text: String, images: [String]) -> String
    func submitPerson(_ text: String, images: [String])                  // 人车道唯一入口（§5.3）
    func cancelTask(id: String)        // 运行中：只取消（结账在 run Task 收尾）；排队中：直接 child:nil 结账（§6）
    /// Stop 按钮语义：cancelAll() + pendingPerson.removeAll()——用户表达"全部停止"，
    /// 排队人消息一并放弃（否则 brain.cancel() 的 .turnSettled 会立即续发，违背意图）。
    func stopEverything()
    /// 会话切换/新建前调用：stopEverything() + children 账本清理。
    func resetForSessionChange()
    /// 窗口关闭（onDisappear）调用：stopEverything() + brain.cancel 由 store 编排。
    func shutdown()
    private func pump()        // 单飞（passes.ts:56-62 直译）
}
```

**投递目标账本**：`@ObservationIgnored private var taskTargets: [String: BrainAgent]`——`submitTask` 时快照 `mainAgent`（强引用，结账/清理时移除）。排队任务被取消时同样需要目标来 ingest 结果行（rev.3 #4）。

**submitTask（入队即落盘 prompt 行）**：
```swift
func submitTask(_ text: String, images: [String]) -> String {
    let task = BrainTask(id: ..., title: ..., prompt: text, images: images, createdAt: Date())
    tasks.append(task)
    taskTargets[task.id] = mainAgent
    // prompt 行在入队时写进主 transcript（§5.9：writer==nil 则 beginSession）——
    // 用户立刻看到自己发了什么；纯任务会话重启后历史不丢；
    // 与排队取消的 cancelled 结果行首尾呼应。
    mainAgent?.ingestUserMessage(text: text, images: images)
    emitTaskEvent(.taskQueued(...)); pump()
    return task.id
}
```

**pump() 语义**（全部在 @MainActor）：
1. 若 `pumping` 已真 → 置 `pumpAgain = true` 返回（请求合并）。
2. `pumping = true`；循环：`running < maxConcurrent` 时按 `createdAt` 取最旧 `queued` 任务 → `startChild(task)`。
3. `pumping = false`；`pumpAgain` → 清零重跑。

**startChild(task)**（slot 在 pump 的判断之后同步占用，两个 start 不可能抢同一槽——dsh reserve 的同步预留语义）：

```swift
let target = taskTargets[task.id] ?? mainAgent            // 快照已在 submitTask 建立
let child = target?.makeTaskChild() ?? BrainAgent.makeDefaultChild()
child.announcesToPet = false
child.onEvent = { [weak self, taskID = task.id] event in
    Task { @MainActor in self?.handleChildEvent(taskID, event) }
}
let run = Task { [weak self, child, task] in
    var prompt = task.prompt; var images = task.images
    var attempt = 0
    while !Task.isCancelled {
        _ = await child.trySubmit(prompt, images: images)     // 原子占位（§5.3）
        if child.lastError == nil { break }                   // 成功
        if child.lastError == "cancelled" { break }           // 取消 → 结账为 cancelled
        guard Task.isCancelled == false, Self.isTransient(child.lastError!), attempt < 3 else { break }
        attempt += 1
        try? await Task.sleep(for: .seconds(5 * pow(2, Double(attempt - 1))))   // 取消点：立即退出
        guard !Task.isCancelled else { break }
        prompt = "继续"; images = []                           // dsh resumeAfter 直译
    }
    await MainActor.run { self?.finishTask(task.id, child: child, target: self?.taskTargets[task.id]) }
}
children[task.id] = ChildRun(agent: child, targetMainAgent: target, runTask: run)
```

**finishTask（唯一结账点，幂等，child 可空）**：
```swift
private func finishTask(_ id: String, child: BrainAgent?, target: BrainAgent?) {
    guard var task = tasks.first(where: { $0.id == id }), task.runState != .ended else { return }  // 幂等
    // 分类：child==nil（排队中直接取消）→ .cancelled；
    //       child.lastError == "cancelled" → .cancelled；非 nil → .failed；否则 .completed
    task.runState = .ended; task.outcome = ...; task.lastError = child?.lastError
    task.usage = child?.lastUsage
    tasks.removeAll { $0.id == id }
    recentEnded.append(task); if recentEnded.count > 10 { recentEnded.removeFirst() }
    children[id] = nil                       // 释放子 agent（deinit stopAll）与账本
    taskTargets[id] = nil                    // 释放目标快照
    let summary = child.map { ... 最后一条 assistant message / lastError ... }
        ?? "任务在排队中被取消（未开始执行）"
    target?.ingestTaskResult(taskID: task.id, title: task.title,
                             status: task.outcome.rawValue, summary: summary, usage: task.usage)
    PetBus 聚合公告（announcesToPet 语义，§5.8）
    emitTaskEvent(.taskEnded(...)); pump()
}
```

要点：
- **单点结账**：cancelTask/cancelAll 只负责取消（运行中：`run.cancel()` + `child.cancel()`，run Task 在 `child.trySubmit` 因取消立即返回后走 finishTask；**排队中：无 child/run Task，cancelTask 直接以 `child: nil` 调 finishTask**——排队任务无并发写者，幂等 guard 覆盖其余竞态）。**不存在第二条结账路径**。
- **目标快照**：`taskTargets` 在 submitTask 时快照、ChildRun.targetMainAgent 同源；会话切换后，被取消任务的「已取消」结果投回**原会话**的 transcript（原 agent 实例被快照持有至结账完成），不会写进新会话。
- **捕获无环**：run Task 捕获 `[weak self, child, task]`；scheduler→children→runTask→weak self，无 retain cycle；`children[id] = nil`、`taskTargets[id] = nil` 与 `tasks` 移除保证账本不随长会话增长。
- `isTransient`：错误串含 `408/429/500-599/timed out/timeout/connection/reset/refused/network`（dsh.ts:44-55 判定集的字符串等价物）。

### 5.3 人车道（rev.2：原子占位 + .turnSettled 驱动）

**BrainAgent.submit 原子占位改造**（修复 §1 指出的 guard→isRunning 非原子窗口）：

```swift
private let stateLock = NSLock()        // 保护 isRunning / loopGeneration 的读写

/// 原子占位版 submit：占位失败返回 false（不产生任何副作用），成功语义与原 submit 完全一致。
@discardableResult
func trySubmit(_ text: String, images: [String] = []) async -> Bool {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !images.isEmpty else { return false }
    stateLock.lock()
    guard !isRunning else { stateLock.unlock(); return false }
    isRunning = true                     // ← 在任何 await / 文件 I/O 之前完成占位
    stateLock.unlock()
    // ……原 submit 的 :403-439 主体不变（BrainActivity.touch → beginSession → runLoop…）
    return true
}
func submit(_ text: String, images: [String] = []) async { await trySubmit(text, images: images) }
```

- 占位提前到 :403 之前：`beginSession`/`writer.append(context:)` 等原有步骤全部发生在占位之后，占位与 runLoop 之间**没有返回路径**（原 :403-427 无 early return），无需回滚逻辑。
- `cancel()`/`compactNow()` 对 `isRunning`、`loopGeneration` 的读写全部经 `stateLock`（行为不变，仅加锁）。
- runTask 收尾（BrainAgent.swift:434-437）的清 flag 同样在 `stateLock` 内，并**追加 `emit(.turnSettled)`**（§5.4）——这是可靠的空闲信号。

**人车道流**：
- `ChatView.send()` 的人消息**一律**走 `scheduler.submitPerson(text, images)`（不再直调 `brain.submit`，消除「用户直发与 pump 续发竞速」的第三条路径）：
  - 主 agent 空闲 → spawn `Task { if await agent.trySubmit(...) { 移出队列 + onPersonSubmitted 回调（store.syncCurrentSession） } }`；
  - 占位失败（恰好被并发 claim）→ 留在队列，等待下一次 `.turnSettled` 重试——**不吞消息**。
- 续发触发：`.turnSettled` 在 `isRunning=false` **之后**、同一线程同步 emit（BrainAgent.swift:434-437 处），事件经 `Task{@MainActor}` 转发到 scheduler 时 flag 必然已归位——**不使用** `.turnCompleted`（BrainAgent.swift:884，emit 于 runLoop 内部、早于 flag 归位，评审指出的时序缺陷成立）。三个清 flag 点都要 emit：runTask 收尾（:434-437）、`cancel()`（:447-450 清 flag 后）、**`compactNow()` 的 defer（:524-527 清 flag 后）**——/compact 持有 isRunning 数秒（:523），期间入队的人消息若无人续发将滞留到下一次无关事件（rev.3 #2）。
- flush 语义：每次触发只出队一条；并发的两次 flush 中落败方 trySubmit 返回 false 且 no-op（消息仍在队列），由下一个 `.turnSettled` 续发——单 FIFO 队列 + 无标志位，无死锁、无重复、无丢失。
- 排队中的消息在 transcript 尾部渲染「待发送」行（`pendingPerson` 驱动，可点 ✕ 撤回）。

### 5.4 BrainEvent 扩展（`Sources/Moppet/Brain/BrainTypes.swift`）

```swift
enum BrainEvent {
    // …现有 case 不动…
    case turnSettled                       // 可靠空闲信号：isRunning 已归位后 emit（§5.3）
    case taskQueued(taskID: String, title: String)
    case taskStarted(taskID: String, title: String)
    case taskEnded(taskID: String, title: String, status: String)   // "completed"|"failed"|"cancelled"
}
```

- `.turnSettled` 由 runTask 收尾与 `cancel()` 在清 flag 后同步 emit；stale loop（generation 不匹配）不 emit。
- 现有消费方全部有 `default: break`（ChatSessionStore.swift:39-50、QuickChat.swift:111-165、BrainExec.swift:37-51），新增 case 无编译破坏。
- rev.1 的 `.taskProgress`/`.userInputRequested` 删除：任务卡进度读 scheduler 记录（`lastToolName` 由 handleChildEvent 直接写）；「等待你」归属改为中心查询（§5.7），不依赖事件顺序（request_user_input 本就不发事件——BrainTools.swift:373、:798-832 已核实）。
- `approvalRequested` **不加关联值**（会破坏穷举 switch 的既有模式匹配），归属走数据字段（§5.7）。

### 5.5 transcript 落地与 items 并发治理（`BrainTypes.swift` + `BrainAgent.swift`）

**新 item 类型**：

```swift
enum BrainResponseItem {
    // …现有 case 不动…
    /// 任务完成/失败/取消后写进主 transcript 的结果卡（编码 "task_result"）。
    case taskResult(taskID: String, title: String, status: String, summary: String, usageTokens: Int?)
}
```

- 编解码：`CodingKeys` 加 `taskID/title/status/summary/usageTokens`，decode 按 `"type" == "task_result"`。
- 兼容：新构建读旧文件无影响；旧构建读新文件，未知 type 在 `init(from:)` 抛错（BrainTypes.swift:147），`BrainRollout.readRecords` 对不可解码行 `try?` 跳过（BrainRollout.swift:253）——旧构建丢这一行，不炸会话。

**items 写点统一加锁**（rev.2 核心修正：评审指出的 R3 误判成立——runLoop 的追加 :858-867、:921-939 均无锁，仅靠 ingest 侧持锁拦不住无锁写者）：

| 写/读点 | 现状 | 改造 |
| --- | --- | --- |
| submit 的 user/图片追加（:412-417） | 无锁 | 包进 `itemsLock` |
| runLoop 的 assistant/calls 追加（:858-867） | 无锁 | 包进 `itemsLock` |
| runLoop 的 outputs 追加（:921-939） | 无锁 | 包进 `itemsLock` |
| compactHistoryIfNeeded 换血（:496-511） | 无锁 | 包进 `itemsLock` |
| compactNow 换血 + summarizable 快照（:528-555） | 无锁 | 包进 `itemsLock` |
| emit(.planUpdated)（:1000-1011） | 已加锁 | 不变 |
| **ingestUserMessage / ingestTaskResult**（新增） | — | 在 `itemsLock` 内 append |
| runLoop 的 `history: items` 读取（:818-821） | 无锁 | 改为锁内快照 `let history = …` |
| statusText / exportMarkdown 的 items 遍历（:581-585、:624-644） | 无锁 | 锁内快照 |

- UI 的 `@Observable` 主线程读取保持现状（不加锁）——这是**既有的**读写并发特征（今天 runLoop 的池线程 append 与 SwiftUI 主线程读并存），本设计不扩大它：所有**写-写**并发被消除，读侧行为与今日逐字节一致。
- `ingestUserMessage(text:images:)`：`if writer == nil { beginSession() }`（复用 submit :405 的惰性语义）→ 锁内 append user message + image items → `writer.append`。**任务的 prompt 在提交时即写入主 transcript**。
- `ingestTaskResult(...)`：同样先惰性 beginSession → 锁内 append `.taskResult` → `writer.append`。纯任务会话（用户只发过任务）重启后 prompt 行 + 结果行都在，历史不丢。
- 两函数是主 transcript 的**唯一**外部写入口，且只在 itemsLock 临界区内动 items——与统一加锁后的 runLoop 写点互斥，写-写竞态消除。
- 模型历史投影：`SDKChatModel.streamTurn`（BrainAgent.swift:43-77 switch）与 `ResponsesModel.encodeItem`（CodexSubscription.swift:743-767 switch）各加 `.taskResult` case → 投影为 user note `"[task \(status): \(title)]\n\(summary)"`（与 `.plan` 投影 assistant note 同理，CodexSubscription.swift:754-756）。任务 prompt 已作为普通 user message 在历史中，模型同时拥有提问与结果。
- 其余消费点：`pairingSafe` 走 `default` 原样保留（BrainAgent.swift:483-485）；`compactNow` summarizable 过滤把 `.taskResult` 归入可摘要侧；`exportMarkdown` 加一 case；**`ChatView.brainBubble` 的无 default 穷举 switch（ChatView.swift:1027-1044）必须补 `taskResultCard` 渲染 case**——漏改即编译失败，`swift build` 是护栏。

### 5.6 分流规则（ChatView.send，ChatView.swift:883-902 改造）

```
slash 命令        → handleSlash（不动；/compact /init /cd 仍 gate 主 agent）
taskMode 开        → scheduler.submitTask(text, images)（composer 新增「任务」chip，默认关）
其余（人消息）     → scheduler.submitPerson(text, images)（空闲即发，忙即排队——不再直调 brain.submit）
```

- Send 按钮移除 `disabled: brain.isRunning`（ChatView.swift:790），永远可发；`ChatView.send` 的 `guard !brain.isRunning`（:895）删除，由 scheduler 的 trySubmit 原子占位仲裁。
- v1 确定性分流（显式开关 + 忙时入队），不做 LLM 路由；v2 可选 auto 档。

### 5.7 审批与用户输入（并行语义 + rev.2 修正）

- `ApprovalRequest` 加 `var source: String? = nil`，`ApprovalCenter.request(title:detail:source:)` 带默认值参数；`UserInputRequest` 同样加 `source`，`UserInputCenter.request(questions:source:)` 同理。source 由 `BrainTools.Context.source: String?`（新字段，构造点 BrainAgent.swift:982-994 不破坏）透传：
  - `requestApproval`（BrainTools.swift:477-501）→ `ApprovalCenter.request(source: context.source)`；
  - `runRequestUserInput`（BrainTools.swift:798-832）→ `UserInputCenter.request(questions:source: context.source)`；
  - Brain 的清洁工具审批走 `runCleaningTool` → `requestApproval`（BrainTools.swift:617-634）——**同一通道，天然带 source**；ToolRegistry 的 `.ui` 分支（ToolRegistry.swift:119-124）只有 `AIAgent.swift:744` 使用，Brain 不经过，无需改动（评审假设经核实不成立，见 §11 #8）。
- **「等待你」派生**：`ApprovalCenter.hasRequest(source:)` / `UserInputCenter.hasRequest(source:)`（新增查询方法，扫描 pending+queued 的 source）；scheduler 的 `stage(hasPendingAsk:)` 据此计算——单一代码评审点，无事件乱序问题。
- **超时计时统一为「呈现时武装单一定时器」**（rev.3 修正 rev.2 的两处矛盾）：
  - `ApprovalCenter`：现状超时 Task 只对当前 pending 生效（PetBus.swift:270-277），排队请求永不超时；而 rev.2 的「presentNext 重设 + 原请求级 Task 保留」会让**两个计时器并存**——原 Task 在 request+15min 触发时该请求已是 pending（:274-276 检查通过），排队后呈示的审批实际预算 < 15 分钟。修复：**删除 request() 里的请求级计时 Task**，改为单一 `timeoutTask: Task<Void, Never>?` 与 `armTimeout()`——pending 安装时与 `presentNext()`（:281-287）出队时调用（先 cancel 旧 Task），15 分钟**从成为 pending 起算**，每个请求恰好一个生效计时器。
  - `UserInputCenter`：现状 300s 计时是 request() TaskGroup 里的 per-request 睡眠子任务（BrainUserInput.swift:128-140），经 `Channel.finish(nil)` 单赢——加队列后排队请求到点即被 finish，出队时 `guard !channel.isFinished`（:121-124）拒绝安装卡片，模型直接拿到「user did not answer」（BrainTools.swift:826-827），**排队超 300s 的提问永远到不了用户面前**。修复：与 ApprovalCenter 同构——睡眠子任务移出 request() 的 TaskGroup，改由呈现层武装（pending 安装/出队时启动 300s 计时并 cancel 旧计时），Channel 单赢语义、`clearPendingOnMain` id 归属检查、超时公告（BrainUserInput.swift:138-140）全部保留。
- `UserInputCenter` 补 pending+queued 队列（镜像 ApprovalCenter 的 presentNext 模式），修复「第二个请求覆盖第一个卡片」（BrainUserInput.swift:151-163 现状无队列直接覆盖）。
- ApprovalSheet / UserInputSheet 显示来源徽标（「任务：清理下载文件夹」/「对话」）。

### 5.8 宠物气泡治理（rev.2：覆盖工具路径）

- `BrainAgent` 加 `var announcesToPet = true`；子 agent 置 false，门控 5 处直呼点：`say("Thinking…")`（:421）、`PetBus.shared.settle()`（cancel 内 :453）、`setState(.talking)`（:831）、最终 `say`（:874-879）、`setState(.scanning)`（:904）。主 agent/QuickChat/BrainExec 默认 true，零变化。
- **ToolRegistry 路径静音**（评审 #4 成立，已核实）：`ToolRegistry.execute(name:args:approval:quiet: Bool = false)`（ToolRegistry.swift:106）；`Tool.handler` 闭包签名追加第三参 `quiet: Bool`，6 处 PetBus 调用点改为 `if !quiet { … }`：execute 的 `setState(.thinking)`/`defer settle()`（:127-128）、scan_clean 两条 say（:229、:234）、execute_clean 两条 say（:262、:278）。`BrainTools.runCleaningTool` 调 execute 时传 `quiet: context.source != nil`（BrainTools.swift:631）；`MCPServer.swift:100`、`SmokeTest.swift:1962` 用默认 false 零变化。handler 签名变更是编译强制的手工改动（31 个 Tool 构造各补一个参数，rev.3 实测计数），漏改即编译失败。
- 效果：任务子 agent 运行清洁工具时不再触发任何 PetBus 写——既不顶掉流式气泡，也不会经 `PetBus.say` 的 `streamingDismissed = false`（PetBus.swift:66）重新弹出用户已点掉的 QuickChat 气泡。
- scheduler 聚合公告（带 hideAfter，自动消失）：任务开始 `say("开始任务：\(title)", state: .scanning, hideAfter: 6)`；失败 sad、完成 celebrating 同理。子 agent 的 onEvent 接线在 scheduler，不经 `ChatSessionStore.makeAgent` 的宠物公告闭包，错误公告不双播。
- **审批公告例外**：`ApprovalCenter.request` 本身不公告；宠物侧「需要你的批准」来自 `ChatSessionStore.makeAgent` 的 onEvent（ChatSessionStore.swift:45-47）——那是主 agent 的接线。任务的审批公告由 scheduler 的 handleChildEvent 发（带任务名），任务 agent 未接入 makeAgent 闭包，无双播。

### 5.9 rollout 持久化策略

- **主会话文件**：追加两类行——任务 prompt 的普通 user message（提交时，经 ingestUserMessage）与 `.taskResult`（结束时）。排队态不持久化（崩溃丢队列，与今天丢运行中 turn 同级）。
- **子任务文件**：每个子 agent 惰性 `beginSession()`（复用 BrainAgent.swift:405 语义），`SessionMeta.originator = "moppet-brain-task"`，`sessionID = "<parentSessionID>-t<taskID 短码>"`；完整保留子任务的工具轨迹、turnOutcome、approvalEvent。
- **侧栏过滤**：`BrainRollout.listSessions`（:190-199）与 `titleForSession` 调用方跳过 `originator == "moppet-brain-task"`；不迁移旧文件。
- `resume`（BrainAgent.swift:344-368）原样：prompt 行与 taskResult 行自然重放。

### 5.10 ChatSessionStore 改造（rev.2）

- 新增 `private(set) var scheduler = BrainTaskScheduler()`；`makeAgent` 的 onEvent 在现有 switch 后追加转发给 scheduler（含 `.turnSettled`）；scheduler.mainAgent 在每次 swap 后由 store 重绑。
- `newSession()`/`resume(_:)`：**先** `scheduler.resetForSessionChange()`（= stopEverything：cancelAll + pendingPerson 清空 + children/taskTargets 清理）**再**执行现有 `if brain.isRunning { brain.cancel() }` 与换 agent——顺序保证被取消任务的目标快照仍指旧 agent，且人队列不会把旧对话的话发进新对话（评审 #11）。有运行中任务时先弹确认 sheet（复用 deletionConfirm 模式）。
- **窗口关闭生命周期**（评审 #12）：`ChatView.onDisappear`（ChatView.swift:154-156 已有此钩子）追加 `store.shutdownForClose()` = `brain.cancel()` + `scheduler.shutdown()`（= stopEverything）。关窗即终止一切在跑工作，与「切换即取消」同一哲学；app 退出由进程终止兜底。不采用"后台继续跑"——finishTask 的结账与公告都依赖 scheduler 存活，孤儿化的收益不抵不可见消耗。

### 5.11 ChatView 改造（ChatView.swift）

| 位置 | 改动 |
| --- | --- |
| :453-455 header | `brain.isRunning \|\| scheduler.hasActive` 时 ProgressView；任务数 >0 显示「N 任务」徽标 |
| :541-545 Stop | `brain.cancel(); scheduler.stopEverything()`（整体生效：任务全取消 **+ 排队人消息清空**——否则 cancel 的 .turnSettled 会立即续发队列，违背"全部停止"意图，rev.3 #6）；每张任务卡自带 ✕ 单任务取消 |
| :682-715 任务条 | ForEach 之后、streaming bubble 之前渲染 `scheduler.tasks`（非 ended 卡片）+ `pendingPerson` 待发送行；emptyHint 条件（:684）加任务/队列非空一项 |
| :790 Send | 移除 `disabled: brain.isRunning` |
| :883-902 send() | §5.6 三路分流；`store.syncCurrentSession()` 挂到 scheduler.onPersonSubmitted |
| :1027-1044 brainBubble | **补 `.taskResult` case** → taskResultCard（status 图标 + summary + failed/cancelled 时的「重试」按钮，查 scheduler.recentEnded）——穷举 switch，漏改编译失败 |
| 任务卡组件 | 新文件 `Sources/Moppet/Views/BrainTaskCard.swift`：克隆 planCard（:1158-1175）+ BatchProgress indeterminate ring（Theme/BatchProgress.swift）；卡内只放状态行与 `lastToolName`，**不放流式正文**（R4） |
| :163-168 展开态 | 任务条不进 offset ForEach；`.taskResult` 是尾部追加不插中部，offset 键不错位；换会话清空逻辑不变 |
| :154-156 onDisappear | 追加 `store.shutdownForClose()`（§5.10） |

QuickChat 与 BrainExec：v1 不改（QuickChat.swift:62 单任务语义保留；BrainExec.swift:8-69 一次性 agent）。

### 5.12 并发与 Sendable 边界

- **`BrainAgent` 不引入 actor 隔离**：保持「非隔离 class + @Observable + 事件回主线程」的现有边界（QuickChat.swift:30-35 模式）。新增可变共享点及保护：
  - `items`：全部写点统一 itemsLock（§5.5），模型历史读锁内快照；
  - `isRunning`/`loopGeneration`：stateLock（§5.3）；
  - `writer`：惰性 beginSession 只发生在 trySubmit 占位之后（submit 路径）或 ingest 路径（scheduler @MainActor 串行调用），单写者；
  - `pendingTaskResults` 不存在——ingest 直写（锁内），无第二缓冲。
- **scheduler 是唯一新增 @MainActor 点**；子 agent onEvent 用 `Task { @MainActor in … }` 回主线程（事件乱序只影响 `lastToolName` 显示，不影响状态机——runState 迁移全部在 @MainActor 的 finishTask/pump 单点发生）。
- 跨实例共享：`mcpClients` 值 `BrainMCPClient` 是串行 queue 保护的 `@unchecked Sendable`（BrainMCPClient.swift:7-9），并行 dispatch 安全；子 agent spawn 时拷贝 `mcpToolInfos`（之后只读）。`BrainRollout.Writer.append` per-writer appendLock（BrainRollout.swift:125-131），主/子文件互不相干。
- `BrainTaskScheduler.ChildRun.runTask`（外层：重试/结账）与子 agent 内部 `runTask`（BrainAgent.swift:429-438，generation 所有权）是两层 Task；generation 机制原样复用，不复制不修改。
- `ApprovalCenter`/`UserInputCenter`/`PetBus` 均 @MainActor 或 applyOnMain；ToolRegistry.execute 是 static async（无共享可变状态新增——`quiet` 是值传参）。

## 6. 关键时序（rev.3）

**提交→完成**：`send()`（taskMode）→ `submitTask` 入队 → `ingestUserMessage` 写 prompt 行（writer 惰性建）→ `pump()` 有空 slot → spawn 子 agent（快照 target）→ `child.trySubmit` → 子 rollout 记录 → runLoop（现有）→ run Task 收尾 → `finishTask`（幂等、账本清理）→ `target.ingestTaskResult` → 卡片消失、结果行入 transcript → `pump()` 补位。

**人消息（忙时）**：`send()` → `submitPerson` → trySubmit 占位失败/主 agent 忙 → 入队 + 待发送行 → runTask 收尾清 flag → `emit(.turnSettled)` → scheduler flush → `trySubmit` 成功 → 出队 → 正常 user bubble。/compact 期间排队（compactNow 持 isRunning，:523）由其 defer 清 flag 后的 `.turnSettled`（:524-527 处）同样续发。

**取消单任务**：卡片 ✕ → `cancelTask` → 运行中：`run.cancel()` + `child.cancel()`（BrainAgent.swift:446-454：generation 夺权 + stopAll + emit .turnSettled）→ `child.trySubmit` 立即返回（lastError=="cancelled"）→ run Task 走唯一 finishTask → **单条** cancelled 结果行入**快照目标**（原会话）→ 账本清理 → pump；**排队中：无 child/run Task，cancelTask 直接以 `child: nil` 调 finishTask**（cancelled，summary 注明未开始，rev.3 #4）→ 账本清理 → pump。

**Stop**：`brain.cancel()`（对话 turn 终止 + .turnSettled，但人队列已被清空 → 续发为 no-op）+ `scheduler.stopEverything()`（cancelAll：运行中任务走取消路径、排队任务直接结账；**pendingPerson.removeAll()**——用户表达"全部停止"，排队消息一并放弃，rev.3 #6）。

**切会话/关窗**：确认 sheet（如有运行中任务）→ `scheduler.resetForSessionChange()`（= stopEverything + children/taskTargets 清理）→ `brain.cancel()` → 换 agent / 关窗销毁。被取消任务的结账投回旧 agent 快照。

**瞬时错误**：子 turn 失败（非取消）→ `isTransient` → 睡 5s（Task.sleep，取消即中断）→ `child.trySubmit("继续")`（同子 rollout、同历史）→ 最多 3 次 → 仍败 → failed 行 + 重试按钮。

## 7. 兼容性清单（mustPreserve 逐项对照，rev.3）

| mustPreserve 项 | 保留方式 |
| --- | --- |
| 取消 cancel/Stop（BrainAgent.swift:446-454） | `cancel()` 语义不变（generation 夺权 + stopAll + settle），新增 stateLock 保护与 `.turnSettled` emit；Stop 升级为 `brain.cancel()+stopEverything()`（人队列一并清空）；单任务取消经唯一 finishTask 结账，无双份结果（§6） |
| 审批流 approvalRequested（BrainTools.swift:477-501、PetBus.swift:219-298） | once-resume、单 pending 呈现、Esc=deny（ChatView.swift:959-975）原样；15 分钟超时语义保持并**修复排队覆盖**（呈现时武装单一定时器，从成为 pending 起算，§5.7）；source 为带默认值新参数，现有调用点零破坏 |
| loopGeneration 所有权（BrainAgent.swift:427-438、444） | 机制不动；仅其与 isRunning 的读写收进 stateLock；子 agent 各自独立 generation |
| 会话切换/resume（ChatSessionStore.swift:83-95、BrainAgent.swift:344-368） | 保留「切换先 cancel」并扩展到任务与人队列（resetForSessionChange）；resume 一字不改；taskResult 行是纯追加 item，不影响 plan 恢复（:360-365）与 pairingSafe |
| rollout 持久化（BrainRollout.swift:102-141） | Writer 不改；新行类型走既有 response_item 容器；ingest 是唯一外部写入口且在 itemsLock 内；Reflector 行号坐标只增不移 |
| 流式输出 streamingText（BrainAgent.swift:209、815-872） | 主 agent 单缓冲语义不动；子 agent 各有独立 streamingText，任务卡不渲染流式正文；**工具路径静音**保证 `PetBus.say` 不再把 `streamingDismissed` 重置（PetBus.swift:66），dismissed 气泡契约不被并行任务破坏 |
| slash 命令（BrainSlash.swift:28-39、ChatView.swift:911-955） | `/compact /init /cd` 的 `guard !brain.isRunning` gate 主 agent 语义不变；/compact 与任务并行安全（compactNow 独占主 items，子 agent 不碰；itemsLock 化后与 ingest 也互斥）；新增 `/tasks`（run 加默认值参数） |
| 图片输入（BrainAgent.swift:414-417、922-934） | 主 agent 的 user message+image 顺序契约不动（追加路径加锁不改顺序）；任务图片只进子 transcript，同 agent 内保序；任务 prompt 行的图片经 ingestUserMessage 与消息同序追加 |
| 模型/沙盒切换（BrainAgent.swift:281-302、329-334） | 子 agent spawn 时快照（makeTaskChild 拷贝）——运行中改动只影响下一个任务；主 agent 路径不变 |
| 宠物气泡 PetBus（PetBus.swift:21-203） | announcesToPet 门控 agent 5 处直呼；ToolRegistry 6 处调用点按 quiet 静音（§5.8）；主/QuickChat/Exec/清理面板默认行为零变化；streamingDismissed/endStreamingTurn 契约不被并行任务触碰 |
| 审批 denied 记账 FlagBox（BrainAgent.swift:762-767、792、963-972） | per-runLoop 局部——子 agent 天然各有一套，写入各自 rollout/approvals.jsonl |
| TurnOutcome 单一出口 finish()（BrainAgent.swift:785-800） | runLoop 不动；子任务 turnOutcome 写子文件 |
| compactNow/auto-compact（BrainAgent.swift:466-561） | 逻辑不动（summarizable 加 case、换血加锁）；compact 的 isRunning 置位收进 stateLock（与 trySubmit 原子占位互斥） |
| request_user_input 单槽问答（BrainUserInput.swift:39-180） | Channel 单赢/300s 超时/clearPendingOnMain 原样；补队列修复并发覆盖；source 归属 |
| PetBus 公告时序契约（BrainAgent.swift:421/831/904/874-879） | 主 agent 时序不变；子 agent 静音，不打断主时序 |
| 工具子任务事件通道（BrainAgent.swift:892-894） | notify `@Sendable [weak self]` 不动；scheduler child onEvent 同纪律回主 |

公共 API 硬清单：`submit(_:_:)`、`cancel()`、`compactNow()`、`BrainEvent`/`BrainResponseItem` 既有 case、`ApprovalCenter.request(title:detail:)`、`BrainSlash.run(_:brain:)`、`ToolRegistry.execute(name:args:approval:)`（quiet 带默认值）、`Tool.handler` 闭包为**内部类型**（同模块机械更新，非公共 API）全部签名兼容；新增仅：默认值参数、新增 case、新类型/新方法、`trySubmit`（新增方法）。

## 8. 改动文件清单

新增：
- `Sources/Moppet/Brain/BrainTaskScheduler.swift` —— BrainTask、BrainTaskScheduler（slot/pump/人车道/瞬时重试/幂等结账/目标快照）
- `Sources/Moppet/Views/BrainTaskCard.swift` —— 任务卡视图

修改：
- `Sources/Moppet/Brain/BrainTypes.swift` —— `taskResult` item；`BrainEvent` 增 `turnSettled/taskQueued/taskStarted/taskEnded`
- `Sources/Moppet/Brain/BrainAgent.swift` —— items 写点统一 itemsLock + 历史快照（:412-417/:818-821/:858-867/:921-939/:496-511/:528-555/:581-585/:624-644）；`trySubmit` 原子占位 + stateLock；`.turnSettled` emit（:434-437/:446-454）；`announcesToPet` 门控（:421/:453/:831/:874-879/:904）；`ingestUserMessage`/`ingestTaskResult`（惰性 beginSession）；`makeTaskChild`；`toolContext` 透传 `source`（:982-994）
- `Sources/Moppet/Brain/BrainTools.swift` —— `Context.source: String?`；requestApproval / runRequestUserInput / runCleaningTool 透传 source 与 quiet（:477-501/:617-634/:631/:798-832）
- `Sources/Moppet/Core/ToolRegistry.swift` —— `execute(…, quiet:)`；handler 签名加 `quiet`；6 处 PetBus 调用点门控（:106/:119-124 不动/:127-128/:229/:234/:262/:278）
- `Sources/Moppet/Brain/BrainRollout.swift` —— listSessions/titleForSession 过滤 task originator
- `Sources/Moppet/Core/CodexSubscription.swift` —— `encodeItem`（:743-767）加 `.taskResult` case
- `Sources/Moppet/Core/PetBus.swift` —— `ApprovalRequest.source`；`request(source:)`；删除请求级计时 Task，新增 `timeoutTask` + `armTimeout()`（pending 安装与 presentNext 出队时武装，:253-298）
- `Sources/Moppet/Brain/BrainUserInput.swift` —— pending+queued 队列；`UserInputRequest.source`；`hasRequest(source:)`
- `Sources/Moppet/ViewModels/ChatSessionStore.swift` —— scheduler、onEvent 转发、resetForSessionChange 顺序、shutdownForClose
- `Sources/Moppet/Views/ChatView.swift` —— 分流、Send 解禁、任务条、header、Stop、**brainBubble 补 case**（:1027-1044）、onDisappear
- `Sources/Moppet/Brain/BrainSlash.swift` —— `run(_:brain:tasks:)` + `/tasks`
- `Sources/Moppet/Brain/BrainSmokeTest.swift` —— 双任务并行、取消幂等（单条结果行）、纯任务会话落盘、排队审批超时 冒烟测试

## 9. 分阶段落地

- **P0（一个 PR）**：itemsLock 统一 + 历史快照；trySubmit/stateLock；`.turnSettled`；BrainTaskScheduler（幂等结账/目标快照/人车道）；taskResult item + 两个 transports + brainBubble case + exportMarkdown/compactNow；ingest 双路径（惰性 beginSession）；announcesToPet；ToolRegistry quiet 透传；ChatView 任务条/分流/Stop/onDisappear；ChatSessionStore 接线与 reset 顺序。完成后并行任务可用、`swift build` 过、mustPreserve 全部成立。
- **P1**：ApprovalCenter/UserInputCenter 的 source 徽标 + 排队超时重设 + UserInputCenter 队列；瞬时错误自动续跑；`/tasks`；切会话确认 sheet；结果行重试按钮。
- **P2**：任务卡流式预览（需先解决 body 每 delta 全量重估）；侧栏 per-session 徽标；auto 分流；任务详情视图（读子 rollout）；挂起释放 slot。

## 10. 已知风险与取舍（rev.3）

- **R1 等待用户的任务占住 slot**：`awaitingUser` 期间不释放槽位。原「15 分钟硬顶」对排队审批不成立（PetBus.swift:270-276），rev.3 的「呈现时武装单一定时器」修复后（§5.7），审批与提问的等待上限均恢复有效；残余风险：K=2 双任务同时等人仍会饿死队列（有硬顶，P2 可做挂起释放）。
- **R2 旧构建读新 rollout 丢 task_result 行**：`readRecords` try? 跳行（BrainRollout.swift:253），不炸会话。
- **R3（已修复为设计约束）items 写-写竞态**：rev.1 的「itemsLock 拦得住」论断错误——runLoop 追加本就无锁。rev.2 将**所有** items 写点统一加锁 + 历史读锁内快照（§5.5），写-写 UB 消除；UI 读侧保持既有特征不扩大。
- **R4 UI 重估放大**：任务卡不含流式正文，只有事件驱动状态字段。
- **R5 队列不持久化**：崩溃丢排队与运行中任务（与今日同级）；跨重启留 P2。
- **R6 QuickChat 不同享并行能力**：保留单任务语义。
- **R7 窗口关闭终止任务**：onDisappear cancelAll（§5.10）——关窗即放弃在跑任务，token 消耗随取消停止；不做后台存活（孤儿结账不可见）。
- **R8 ToolRegistry handler 签名机械改动**：31 个 `Tool` 构造（`grep -c "list.append(Tool(" ToolRegistry.swift` = 31，rev.3 实测）各补 `quiet` 参数，6 处 PetBus 调用点加门控；handler 由 execute 单点调用（ToolRegistry.swift:129），漏改编译失败；一次性成本。
- **R9 评审意见 #8 的前提修正**：Brain 的破坏性清洁工具审批不走 ToolRegistry `.ui` 分支（唯一调用方 AIAgent.swift:744），而走 BrainTools.runCleaningTool → requestApproval（BrainTools.swift:617-634），source 天然可达；已核实并据此收敛改动面。

## 11. 修订记录（评审意见 → 处置）

| # | 评审问题 | 处置 |
| --- | --- | --- |
| 1 | R3 数据竞态误判（runLoop 追加无锁，:858-867/:921-939） | 成立。§5.5 改为 items 写点统一加锁 + 历史读锁内快照；R3 重写 |
| 2 | 人车道触发时序（.turnCompleted 早于 isRunning 归位，:884 vs :434-437） | 成立。新增 `.turnSettled`（清 flag 后同步 emit），§5.3 重写 |
| 3 | 取消双重结账 / runTask 未取消 / 结果入错会话 | 成立。finishTask 幂等 + cancel 只取消不结账 + 目标 agent 启动时快照，§5.2/§6 重写 |
| 4 | ToolRegistry 直呼 PetBus 泄漏（:127-128/:229/:234/:262/:278；say 重置 streamingDismissed PetBus.swift:66） | 成立。§5.8 增加 quiet 透传与 6 处门控；文件清单补 ToolRegistry.swift |
| 5 | 排队审批永不超时（:270-276 只 deny 当前 pending） | 成立。presentNext 重设 15 分钟计时，§5.7；R1 更新 |
| 6 | submit guard→isRunning 非原子（非隔离 async，SE-0338） | 成立。trySubmit 原子占位 + stateLock，§5.3；人消息一律走 scheduler 消除第三条竞速路径 |
| 7 | 纯任务会话不落盘（writer 惰性 :405） | 成立。ingest 双路径惰性 beginSession + 任务 prompt 提交时入主 transcript，§5.5/§5.9 |
| 8 | 清洁工具审批拿不到 source（.ui 分支） | **前提修正**：Brain 不走 `.ui`（唯一调用方 AIAgent.swift:744）；Brain 路径经 runCleaningTool→requestApproval，source 可达（BrainTools.swift:617-634）。§5.7/§R9 修正；ToolRegistry 的 quiet 静音仍按 #4 实施 |
| 9 | request_user_input 无事件、tasksWithPendingAsk 无法清除、事件乱序 | 成立。改为从 Approval/UserInput 中心查询派生（hasRequest(source:)），删除 .userInputRequested/.taskProgress 事件，§5.1/§5.4/§5.7 |
| 10 | brainBubble 穷举 switch 无 default（ChatView.swift:1027-1044） | 成立。§5.5/§5.11/§8 补渲染 case |
| 11 | cancelAll 未清 pendingPerson | 成立。resetForSessionChange 统一清理，§5.2/§5.10/§6 |
| 12 | 关窗后子 agent 孤儿跑完、结账丢失 | 成立。onDisappear → shutdownForClose，§5.10/§5.11；R7 |
| 13 | children 账本无清理、捕获自相矛盾（[child] 却用 self） | 成立。捕获改 [weak self, child, task]、结账即 children[id]=nil、ended 移出 tasks 进 recentEnded（cap 10），§5.2 |

rev.3（第二轮评审，7 项）：

| # | 评审问题 | 处置 |
| --- | --- | --- |
| 14 | UserInputCenter 加队列与 300s 计时矛盾（per-request 睡眠 :128-140 到点即 finish，出队 guard !channel.isFinished :121-124 拒装卡，模型拿到 BrainTools.swift:826-827 兜底） | 成立。与 ApprovalCenter 同构改「呈现时武装计时」：睡眠子任务移出 request() 的 TaskGroup，pending 安装/出队时启动 300s 并 cancel 旧计时，§5.7 重写 |
| 15 | compactNow 持 isRunning（:523）数秒、defer（:524-527）清 flag 但不发 .turnSettled → /compact 期间排队的人消息滞留 | 成立。.turnSettled 扩展到第三个清 flag 点（compactNow defer），§5.3/§6 |
| 16 | rev.2 审批修复自相矛盾：presentNext 重设 + 原请求级 Task 保留 → 双计时器，排队后呈示的审批实际预算 < 15min 早 deny | 成立。删除请求级计时 Task，单一 `timeoutTask` + `armTimeout()`（先 cancel 旧），15min 从成为 pending 起算，§5.7 |
| 17 | 排队任务取消结账无机制（finishTask 签名要求 child，:387 声称排队任务直接结账） | 成立。finishTask 改 `child: BrainAgent?` 可空 + taskTargets 账本；排队取消走 `child: nil` 路径（无并发写者，幂等 guard 仍适用），§5.2/§6 |
| 18 | 伪码符号错误（startChild 先用后定义 target）且 prompt 行落盘时机两处不一致（§6 入队时 vs §5.2 startChild） | 成立。target 取自 submitTask 建立的 taskTargets；ingestUserMessage 统一移到 submitTask（入队即落盘），§5.2 重写 |
| 19 | Stop 未覆盖人队列：brain.cancel() 的 .turnSettled 会立即续发排队消息，违背"全部停止" | 成立。新增 `stopEverything()`（cancelAll + pendingPerson.removeAll），Stop/切换/关窗统一走它；cancelAll 本身不清队列，两种语义分离，§5.2/§5.11/§6 |
| 20 | R8 低估（实测 31 处 Tool 构造非约 20） | 成立。grep 计数 31（6 处 PetBus 调用点），R8 更新；可行性不变（execute :129 单点调用 + 编译护栏） |
