import Foundation
import Observation
import SwiftAISDK
import AISDKProvider
import AISDKProviderUtils

// MARK: - Model stream events

enum BrainStreamEvent {
    case textDelta(String)
    case toolCall(BrainToolCall)
    case completed(finalMessage: String?, usage: BrainUsage?)
}

/// A model backend the Brain can talk to. Implementations:
/// - `OpenAIResponsesModel`  — codex's native wire protocol (Responses API + SSE)
/// - `SDKChatModel`          — any swift-ai-sdk vendor via chat completions
/// - `ScriptedModel`         — headless tests (no network)
protocol BrainModel {
    func streamTurn(system: String, developer: String,
                    history: [BrainResponseItem],
                    specs: [BrainTools.Spec]) async throws -> AsyncThrowingStream<BrainStreamEvent, Error>
}

// MARK: - Model backend: swift-ai-sdk for every vendor

/// THE Brain provider layer. All vendors (OpenAI/GLM/Anthropic/Gemini/
/// DeepSeek/Groq/Mistral/Ollama/custom) are served through swift-ai-sdk via
/// AIModelFactory — one transport, one tool-marshalling path, matching how
/// codex swaps providers behind a single agent core.
struct SDKChatModel: BrainModel {

    let settings: AISettings

    func streamTurn(system: String, developer: String,
                    history: [BrainResponseItem],
                    specs: [BrainTools.Spec]) async throws -> AsyncThrowingStream<BrainStreamEvent, Error> {
        let model = try AIModelFactory.makeModel(settings)

        // System prompt goes via `instructions` — the SDK rejects system
        // messages inside `messages` (AI_InvalidPromptError).
        var messages: [ModelMessage] = [.user(developer)]
        for item in history {
            switch item {
            case .message(let role, let content):
                if role == "assistant" {
                    messages.append(.assistant(content))
                } else if !content.isEmpty {
                    messages.append(.user(content))
                }
            case .functionCall(let callID, let name, let arguments):
                // Represented via the SDK tool loop; re-inject as a note so the
                // model retains context when resuming cross-vendor sessions.
                messages.append(.assistant("called \(name)(\(arguments)) id=\(callID)"))
            case .functionCallOutput(_, let output):
                messages.append(.user("tool output: \(output.prefix(2000))"))
            case .reasoning(let summary):
                if !summary.isEmpty { messages.append(.assistant("reasoning: \(summary)")) }
            case .plan:
                break
            case .imageItem(let callID, let dataURL):
                // Images ride as native image parts — vendors that accept
                // image input see the pixels; text-only vendors reject with
                // a clear provider error (same signal codex gives upstream).
                let note = callID == "user"
                    ? "(the user attached an image)"
                    : "(tool result image for call \(callID))"
                if let mediaType = Self.dataURLMediaType(dataURL) {
                    messages.append(.user(UserModelMessage(content: .parts([
                        .text(TextPart(text: note)),
                        .image(ImagePart(image: .string(dataURL), mediaType: mediaType)),
                    ]))))
                } else {
                    messages.append(.user("\(note) [unsupported image data URL]"))
                }
            case .taskResult(_, let title, let status, let summary, _):
                // Parallel-task result card — projected as a user note so the
                // model keeps the outcome in history (same shape as the .plan
                // assistant-note projection; design doc §5.5).
                messages.append(.user("[task \(status): \(title)]\n\(summary)"))
            }
        }

        var toolSet: ToolSet = [:]
        for spec in specs {
            let schema = JSONBridge.toJSONValue(spec.parametersJSONSchema)
            let description = spec.description
            toolSet[spec.name] = tool(
                description: ToolDescription(stringLiteral: description),
                inputSchema: FlexibleSchema(jsonSchema(schema)),
                execute: nil    // brain dispatches tools itself; SDK only marshals calls
            )
        }

        let stream = try streamText(
            model: model,
            tools: toolSet,
            instructions: .text(system),
            messages: messages,
            stopWhen: [isStepCount(1)],   // one model round per brain turn
            settings: CallSettings(maxOutputTokens: 4096)
        )

        return AsyncThrowingStream { (continuation: AsyncThrowingStream<BrainStreamEvent, Error>.Continuation) in
            let task = Task {
                do {
                    var finalText = ""
                    var usage = BrainUsage(inputTokens: 0, outputTokens: 0)
                    for try await part in stream.fullStream {
                        switch part {
                        case .textDelta(_, let delta, _):
                            finalText += delta
                            continuation.yield(.textDelta(delta))
                        case .toolCall(let call):
                            let args: String
                            if let encoded = try? JSONSerialization.data(withJSONObject: JSONBridge.toAny(call.input)),
                               let text = String(data: encoded, encoding: .utf8) {
                                args = text
                            } else {
                                args = "{}"
                            }
                            continuation.yield(.toolCall(BrainToolCall(
                                callID: call.toolCallId, name: call.toolName, argumentsJSON: args)))
                        case .finishStep(_, let usagePayload, _, _, _, _):
                            if let input = usagePayload.inputTokens {
                                usage.inputTokens += input
                            }
                            if let output = usagePayload.outputTokens {
                                usage.outputTokens += output
                            }
                        default:
                            break
                        }
                    }
                    continuation.yield(.completed(finalMessage: finalText.isEmpty ? nil : finalText,
                                                  usage: usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// "data:image/png;base64,…" → "image/png" (nil when malformed).
    static func dataURLMediaType(_ dataURL: String) -> String? {
        guard dataURL.hasPrefix("data:"), dataURL.contains(";") else { return nil }
        let mime = dataURL.dropFirst("data:".count).prefix(while: { $0 != ";" })
        return mime.isEmpty ? nil : String(mime)
    }
}

// MARK: - Scripted model (headless testing)

/// Deterministic model for `--brain-smoke`: plays back canned turns.
final class ScriptedModel: BrainModel {
    private var scripted: [[BrainStreamEvent]]
    /// 每轮收到的 history 尾部 user 文本（依赖上下文注入等 prompt 断言用）。
    private(set) var receivedUserTexts: [String] = []
    init(scripted: [[BrainStreamEvent]]) { self.scripted = scripted }

    func streamTurn(system: String, developer: String,
                    history: [BrainResponseItem],
                    specs: [BrainTools.Spec]) async throws -> AsyncThrowingStream<BrainStreamEvent, Error> {
        if let lastUser = history.reversed().first(where: {
            if case .message("user", _) = $0 { return true }
            return false
        }), case .message("user", let userText) = lastUser {
            receivedUserTexts.append(userText)
        }
        guard !scripted.isEmpty else {
            return AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.completed(finalMessage: "done",
                                                  usage: BrainUsage(inputTokens: 1, outputTokens: 1)))
                    continuation.finish()
                }
            }
        }
        let events = scripted.removeFirst()
        return AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - The Brain agent (observable session)

/// Codex-style turn loop as an observable session powering the chat UI and
/// the pet: submit → stream model → dispatch tool calls (parallel) → feed
/// outputs back → repeat until a turn ends with no tool calls (or the turn
/// cap). Every response item is persisted to the rollout JSONL.
@Observable
final class BrainAgent {

    // Settings (codex-like knobs surfaced in UI)
    var sandboxMode: BrainSandboxMode = .workspaceWrite
    var approvalPolicy: BrainApprovalPolicy = .onRequest
    var cwd: String = FileManager.default.homeDirectoryForCurrentUser.path
    var maxTurnsPerSubmit = 10
    var mcpEnabled = true
    /// codex `sandbox_workspace_write.network_access` — ON by default so the
    /// pet chat can look things up (curl/web checks) without flipping a toggle
    /// per session; the chat window's 🌐 button still turns it off.
    var networkAccess = true
    /// codex `sandbox_workspace_write.writable_roots` — extra writable paths
    /// beyond the workspace root (editable via /cd-style workflows; kept in
    /// sync by the chat UI toggles).
    var writableRoots: [String] = []
    /// codex hosted web_search — only the Responses (ChatGPT subscription)
    /// transport can execute it; the toggle no-ops on other vendors.
    var webSearchEnabled = false
    /// 宠物公告门控（设计文档 §5.8）：任务子 agent 置 false——后台任务的
    /// thinking/talking/scanning/settle 不再写全局单气泡，也不把
    /// streamingDismissed 重置回 false（PetBus.say 的副作用）顶掉正在流式的
    /// 主对话气泡。主 agent / QuickChat / BrainExec 默认 true，零变化。
    var announcesToPet = true

    // Live state
    private(set) var items: [BrainResponseItem] = []
    private(set) var streamingText = ""
    private(set) var plan = BrainPlan.empty
    private(set) var isRunning = false
    private(set) var lastUsage: BrainUsage?
    private(set) var lastError: String?
    private(set) var lastToolLine: String?
    private(set) var sessionID = UUID().uuidString.lowercased()

    var onEvent: ((BrainEvent) -> Void)?

    private var model: BrainModel
    /// Snapshot of the settings this agent's transport was built from —
    /// the chat UI binds its provider/model pickers to it.
    private(set) var settings: AISettings
    private var writer: BrainRollout.Writer?
    private var mcpClients: [String: BrainMCPClient] = [:]
    private var mcpToolInfos: [(server: String, name: String, description: String, schema: [String: Any])] = []
    private var runTask: Task<Void, Never>?
    /// Resumable exec sessions (codex unified_exec session map).
    private let execSessions = BrainExecSessionRegistry()
    /// 本会话 rollout 的 originator（§5.9）：主 agent "moppet-brain"，任务子
    /// agent "moppet-brain-task"——侧栏按后者过滤。
    private var originator = "moppet-brain"
    /// 本 agent 作为任务子 agent 的归属标签（§5.7）：ApprovalCenter /
    /// UserInputCenter 的「等待你」派生据此归属到任务；主 agent 为 nil。
    private(set) var taskSource: String?
    /// 保护 isRunning / loopGeneration 的读写（§5.3）：submit 是非隔离 async
    /// （SE-0338 切到全局并发执行器），guard→占位之间含文件 I/O，两个并发
    /// 调用方可同时通过裸 guard——原子占位的前提是状态位自身受锁。
    private let stateLock = NSLock()

    // MARK: Growth instrumentation (P2, design doc §5.6)

    /// Turn-level signals for `TurnOutcome`. These are plain observations of
    /// what the loop already does — no extra model calls, no extra I/O on the
    /// hot path. Recording is gated by `GrowthSettings.enabled` at write time.
    private var turnStartedAt = Date()
    private var turnPrompt = ""
    private var turnIndex = 0
    private var lastUserPrompt = ""
    private var lastUserAt: Date?
    private var previousIntent: IntentClass?
    /// The user repeated themselves inside two minutes — the previous turn
    /// did not land. Set at submit time, consumed by the current turn.
    private var reAskedThisTurn = false
    /// The user is correcting the last answer ("不对，我说的是…") — §5.7
    /// trigger ③, the only trigger that needs no inference at all.
    private var correctedThisTurn = false

    init(model: BrainModel? = nil, settings: AISettings = AISettings.load()) {
        self.settings = settings
        if let model {
            self.model = model
        } else {
            self.model = Self.defaultModel(settings, webSearch: false)
        }
    }

    /// Provider layer: swift-ai-sdk for every vendor, except the ChatGPT
    /// subscription backend which speaks the Responses API only and gets a
    /// dedicated transport (CodexSubscription.ResponsesModel).
    static func defaultModel(_ settings: AISettings, webSearch: Bool = false) -> BrainModel {
        if settings.vendor.usesCodexResponsesTransport {
            // Stored access tokens die after ~1h; the refresh token (kept
            // since this round) renews them transparently. Fall back to the
            // in-memory value when there is nothing persisted.
            let stored = APIKeyStore.read(for: .codex) ?? ""
            let token = settings.apiKey.isEmpty ? stored : settings.apiKey
            return CodexSubscription.ResponsesModel(
                accessToken: token,
                model: settings.model.isEmpty ? CodexSubscription.defaultModel : settings.model,
                webSearch: webSearch)
        }
        return SDKChatModel(settings: settings)
    }

    func swapModel(_ model: BrainModel) {
        self.model = model
    }

    /// Rebuild the transport from `newSettings` (or persisted settings) —
    /// provider/model switching cascades here; the next turn uses it.
    func refreshModel(settings newSettings: AISettings? = nil) {
        let s = newSettings ?? AISettings.load()
        self.settings = s
        self.model = Self.defaultModel(s, webSearch: webSearchEnabled)
        if s.vendor == .codex {
            // Keep the model menu on the account's real catalog (throttled
            // inside; silent when offline / token missing) and renew an
            // expired access token in the background so the next turn starts
            // with a usable one.
            Task {
                _ = await CodexSubscription.validAccessToken()
                await CodexSubscription.refreshModels()
            }
        }
    }

    /// Toggling hosted web search rebuilds the transport (the flag rides on
    /// the Responses request, so mid-session flips apply next turn).
    func setWebSearch(_ enabled: Bool) {
        webSearchEnabled = enabled
        refreshModel()
    }

    var writerExists: Bool { writer != nil }

    // MARK: - Lifecycle

    func beginSession() {
        let meta = BrainRollout.SessionMeta(
            id: sessionID,
            timestamp: Date(),
            cwd: cwd,
            originator: originator,
            cliVersion: "1.0.0",
            instructions: nil,
            // §5.12: stamp WHICH harness produced this session at open time.
            // Without it, "this version performs worse" can only be guessed —
            // the per-turn outcome also carries the fingerprint, but the meta
            // is the authoritative anchor for a session's whole lifetime.
            harnessFingerprint: GrowthLedger.shared.fingerprint(HarnessStore.load())
        )
        writer = BrainRollout.Writer(meta: meta)
        writer?.append(context: turnContext)
        if mcpEnabled {
            Task { await connectMCP() }
        }
    }

    var turnContext: BrainTurnContext {
        BrainTurnContext(cwd: cwd, sandboxMode: sandboxMode,
                         approvalPolicy: approvalPolicy, model: modelDescription,
                         networkAccess: networkAccess, writableRoots: writableRoots,
                         startedAt: Date())
    }

    private var modelDescription: String {
        switch model {
        case let sdk as SDKChatModel: return sdk.settings.model
        case let responses as CodexSubscription.ResponsesModel: return responses.model
        default: return "scripted"
        }
    }

    func resume(sessionID: String) {
        guard let session = BrainRollout.load(sessionID: sessionID) else {
            lastError = "session not found: \(sessionID)"
            return
        }
        self.sessionID = sessionID
        items = session.items
        if let context = session.lastTurnContext {
            cwd = context.cwd
            sandboxMode = context.sandboxMode
            approvalPolicy = context.approvalPolicy
            if let network = context.networkAccess { networkAccess = network }
            if let roots = context.writableRoots { writableRoots = roots }
        }
        // Restore the last persisted plan (plan items are appended on every
        // update_plan call; the newest one wins).
        if case .plan(let steps)? = items.last(where: {
            if case .plan = $0 { return true }
            return false
        }) {
            plan = BrainPlan(steps: steps)
        }
        writer = BrainRollout.Writer(meta: session.meta)
        writer?.append(context: turnContext)
    }

    // MARK: - MCP

    func connectMCP() async {
        // Reconnecting must not duplicate the tool list (each beginSession
        // used to append another copy of every server's tools).
        mcpToolInfos.removeAll()
        for (name, config) in BrainMCPClient.loadConfig() {
            if mcpClients[name] != nil { continue }   // already connected
            guard let client = try? BrainMCPClient(serverName: name, config: config) else { continue }
            do {
                try await client.initialize()
                let tools = try await client.listTools()
                mcpClients[name] = client
                for tool in tools {
                    mcpToolInfos.append((name, tool.name, tool.description, tool.schema))
                }
                emit(.toolStarted(name: "mcp:\(name)", callID: "-"))
                emit(.toolFinished(name: "mcp:\(name) connected (\(tools.count) tools)",
                                   callID: "-", output: "", isError: false))
            } catch {
                // A failed server never blocks the brain.
            }
        }
    }

    // MARK: - Submit a turn (the core loop)

    /// Submit a user turn. `images` are data URLs of user-attached images
    /// (codex UserInput::Image / TUI paste); they enter the transcript as
    /// image items so every transport can re-encode them natively.
    func submit(_ text: String, images: [String] = []) async {
        await trySubmit(text, images: images)
    }

    /// 原子占位版 submit（设计文档 §5.3）：占位失败返回 false（不产生任何
    /// 副作用），成功语义与原 submit 完全一致。submit 是非隔离 async
    /// （SE-0338 切到全局并发执行器），原 guard→`isRunning = true` 之间含
    /// beginSession/写 rollout 的文件 I/O——两个并发调用方可同时通过 guard，
    /// 形成下方注释所述的历史事故形态；占位提前到任何 await / 文件 I/O 之前。
    /// 唯一的占位后返回路径是「启动前校验」：占位→启动窗口内被 cancel()/
    /// compactNow 抢占（generation 被外部 bump）时放弃启动并返回 false——
    /// 此时 rollout 已写入 user 行（与 mid-turn 取消同形），isRunning 由
    /// cancel 清位、不在此重复回滚。
    @discardableResult
    func trySubmit(_ text: String, images: [String] = []) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !images.isEmpty else { return false }
        // withLock：async-safe 的 scoped locking（临界区内无挂起点，语义与
        // lock/unlock 对完全一致）。check-and-set 必须同一临界区——占位
        // 与抢占之间不能留窗口。
        // Claim 纪元：generation 递增与占位同一临界区——cancel()/compactNow
        // 的 defer 在「占位→启动」窗口内 bump generation 即令本 claim 失效，
        // 启动前校验据此放弃本次 turn。否则被取消的 turn 照常执行且 runTask
        // 句柄被下一次提交覆盖，形成双 runLoop 并发（streamingText 无锁交叉
        // 写、rollout 行交错，Stop 再也停不掉第一个 loop）。
        let generation = stateLock.withLock { () -> Int? in
            guard !isRunning else { return nil }
            isRunning = true   // ← 在任何 await / 文件 I/O 之前完成占位
            loopGeneration += 1
            return loopGeneration
        }
        guard let generation else { return false }
        // The user is here: any background self-improvement yields instantly.
        BrainActivity.touch()
        Evolver.shared.cancel()
        // 惰性 beginSession 在 itemsLock 内判定+创建：submit 路径与 ingest
        // 路径（scheduler @MainActor）都可能首建——两路并发不允许产出两个
        // Writer 交错写同一 JSONL（§5.5 写-写竞态治理）。
        itemsLock.withLock {
            if writer == nil { beginSession() }
        }
        // codex persists a turn_context per turn — /cd and mid-session
        // toggles survive restarts (they used to roll back on resume).
        writer?.append(context: turnContext)

        beginTurn(prompt: text)

        itemsLock.withLock {
            items.append(.message(role: "user", content: text))
            for dataURL in images {
                items.append(.imageItem(callID: "user", dataURL: dataURL))
            }
        }
        writer?.append(item: .message(role: "user", content: text))
        for dataURL in images {
            writer?.append(item: .imageItem(callID: "user", dataURL: dataURL))
        }
        // Never echo the user's question into the pet bubble — it's their
        // own words; show agent-side state instead (hideAfter 0 keeps the
        // bubble until the first delta/tool event replaces it).
        if announcesToPet {
            PetBus.shared.say(L("Thinking…"), state: .thinking, hideAfter: 0)
        }

        lastError = nil
        emit(.turnStarted)

        // 启动前校验 + runTask 赋值同一临界区（校验→赋值窗口零宽）：generation
        // 已被 cancel()/compactNow defer 在占位窗口内 bump → 本次 turn 放弃
        // 启动。isRunning 不在此回滚——cancel 已清位；若已被 compactNow 或
        // 更新的 claim 持有，代清会踩他人占位。仅恢复 lastError（占位窗口内
        // 上面的 nil 可能抹掉了 cancel 的写入；与后写者的竞争窗口是 µs 级
        // 赋值对 ms 级 beginSession 文件 I/O，实际不可达，与既有锁粒度一致）。
        let start = stateLock.withLock { () -> Bool in
            guard loopGeneration == generation else { return false }
            runTask = Task {
                await runLoop()
                // Only the CURRENT loop owns the flag/handle — a cancelled-but-
                // still-unwinding stale loop must not clobber a newer submit's
                // state (that's how double runLoops used to interleave).
                guard generation == self.loopGeneration else { return }
                // 锁内复查 generation：杜绝「compare 通过 → cancel/新 claim
                // 落入 → 清掉他人句柄/flag」的窄窗（句柄覆盖是缺陷⑤形态）。
                let settled = self.stateLock.withLock { () -> Bool in
                    guard generation == self.loopGeneration else { return false }
                    self.isRunning = false
                    self.runTask = nil
                    return true
                }
                // 可靠空闲信号（§5.3/§5.4）：flag 归位之后同步 emit——人车道
                // 续发唯一驱动源。stale loop（generation 不匹配）不 emit。
                if settled { self.emit(.turnSettled) }
            }
            return true
        }
        guard start else {
            lastError = "cancelled"
            // 补一发空闲信号：cancel()/compactNow 自身的 .turnSettled 发出时，
            // 在途 flush 还挂在占位 await 上——没有这一发，被放弃 turn 涉及
            // 的队列要等下一次无关事件才续发。
            emit(.turnSettled)
            return false
        }
        let handle = stateLock.withLock { runTask }
        await handle?.value
        return true
    }

    /// Claim/run epoch — bumped at trySubmit claim（与 isRunning 占位同一临
    /// 界区）以及 cancel()/compactNow 的 defer：让 stale（被取消）的占位或
    /// loop 检测到自己已不再拥有会话状态。
    private var loopGeneration = 0

    func cancel() {
        // 单临界区：generation bump（使占位窗口内的 claim 失效——双 runLoop
        // 修复的另一半）+ flag 清位 + runTask 句柄原子摘除。句柄在锁外
        // cancel()：Task.cancel 非阻塞，且此刻 generation 已递增，被取消 loop
        // 的收尾闭包必然 stale、不会清写他人状态。
        let handle = stateLock.withLock { () -> Task<Void, Never>? in
            loopGeneration += 1
            isRunning = false
            let task = runTask
            runTask = nil
            return task
        }
        handle?.cancel()
        lastError = "cancelled"
        execSessions.stopAll()
        if announcesToPet {
            PetBus.shared.settle()
        }
        // 清 flag 后同步 emit（§5.3 三个清 flag 点之二）：Stop 后人车道若还有
        // 排队消息由此续发（stopEverything 会先清队列，续发为 no-op）。
        emit(.turnSettled)
    }

    deinit {
        execSessions.stopAll()
    }

    /// codex /compact parity — when the transcript outgrows the window, keep
    /// the opening user goal + recent tail, replacing the middle with a
    /// compact marker so long sessions stay within budget.
    var compactThreshold: Int = 80
    var compactKeepTail: Int = 40

    /// Truncation must never split a function_call from its
    /// function_call_output: an orphan output makes the Responses API 400
    /// on EVERY later turn of the session. Sweep the final list so calls
    /// without outputs (and outputs without calls) are dropped.
    static func pairingSafe(_ input: [BrainResponseItem]) -> [BrainResponseItem] {
        var result: [BrainResponseItem] = []
        var openCalls = Set<String>()
        for item in input {
            switch item {
            case .functionCall(let callID, _, _):
                openCalls.insert(callID)
                result.append(item)
            case .functionCallOutput(let callID, _):
                if openCalls.contains(callID) {
                    openCalls.remove(callID)
                    result.append(item)
                }   // orphan output: silently dropped by the truncation
            default:
                result.append(item)
            }
        }
        if !openCalls.isEmpty {
            result.removeAll { item in
                if case .functionCall(let callID, _, _) = item { return openCalls.contains(callID) }
                return false
            }
        }
        return result
    }

    func compactHistoryIfNeeded() {
        // 整体换血纳入 itemsLock（§5.5）：ingest 写点并行后，无锁换血与
        // append 并发是 UB。函数内无 await，整段持锁即可。
        itemsLock.lock()
        defer { itemsLock.unlock() }
        guard items.count > compactThreshold else { return }
        let head = items.prefix(2)   // first user goal + first reply
        let tail = items.suffix(compactKeepTail)
        let dropped = items.count - head.count - tail.count
        var compacted = Array(head)
        compacted.append(.message(
            role: "user",
            content: "[context compacted: \(dropped) earlier exchange(s) summarized away — rely on the plan and recent history]"
        ))
        compacted.append(contentsOf: tail)
        items = Self.pairingSafe(compacted)
        writer?.append(item: .message(
            role: "user",
            content: "[history compacted: \(dropped) items]"))
    }

    /// codex `/compact` parity — a REAL model-generated summary replaces the
    /// middle of the transcript (auto-compact above only truncates). The
    /// summary is persisted as a `compacted` rollout record, like codex's
    /// CompactedItem. Returns a short human-readable result line.
    @discardableResult
    func compactNow() async -> String {
        guard !itemsLock.withLock({ items.isEmpty })
        else { return "nothing to compact (empty session)" }
        // check-and-set 收进 stateLock（§5.3/§7）：compact 的 isRunning 置位与
        // trySubmit 原子占位互斥，同一窗口不再有两个写者能各自过 guard。
        let running = stateLock.withLock { () -> Bool in
            let busy = isRunning
            if !busy { isRunning = true }
            return busy
        }
        guard !running else { return "wait for the current turn to finish first" }
        defer {
            stateLock.withLock {
                loopGeneration += 1   // invalidate any racing loop's ownership
                isRunning = false
            }
            // 清 flag 后同步 emit（§5.3 三个清 flag 点之三，rev.3 #2）：
            // /compact 持 isRunning 数秒，期间入队的人消息由此续发。
            emit(.turnSettled)
        }
        let (summarizable, head) = itemsLock.withLock { () -> ([BrainResponseItem], [BrainResponseItem]) in
            let summarizable = items.filter { item in
                switch item {
                case .message, .functionCall, .functionCallOutput, .taskResult: return true
                case .reasoning, .plan, .imageItem: return false
                }
            }
            return (summarizable, Array(items.prefix(2)))
        }
        do {
            let stream = try await model.streamTurn(
                system: "You summarize agent conversations. Produce a dense summary (≤300 words): the user's goals, decisions made, commands/tools that ran and their outcomes, current state and next step. Plain text, no preamble.",
                developer: "summarize",
                history: summarizable,
                specs: [])
            var summary = ""
            for try await event in stream {
                if case .textDelta(let delta) = event { summary += delta }
            }
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "compaction skipped (empty summary from the model)"
            }
            let dropped = itemsLock.withLock { () -> Int in
                let tail = Array(items.suffix(min(compactKeepTail, max(0, items.count - 2))))
                var compacted = head
                compacted.append(.message(
                    role: "user",
                    content: "[compacted summary of earlier turns]\n\(summary)"))
                compacted.append(contentsOf: tail)
                let dropped = items.count - compacted.count
                items = Self.pairingSafe(compacted)
                return dropped
            }
            writer?.append(.compacted(summary: summary))
            return "compacted: \(dropped) items replaced by a \(summary.count)-char summary"
        } catch {
            return "compaction failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Chat slash-command helpers (TUI commands, chat-UI equivalents)

    /// `/status` — session configuration + token usage (codex slash_dispatch).
    var statusText: String {
        var lines = [
            "session: \(sessionID)",
            "provider: \(settings.vendor.rawValue)",
            "model: \(modelDescription)",
            "cwd: \(cwd)",
            "sandbox: \(sandboxMode.rawValue)" +
                (sandboxMode == .workspaceWrite ? " (network \(networkAccess ? "on" : "off"))" : ""),
            "approval: \(approvalPolicy.rawValue)",
            "web_search: \(webSearchEnabled && settings.vendor.usesCodexResponsesTransport ? "on" : "off")",
            "mcp: \(mcpClients.isEmpty ? "none" : mcpClients.keys.sorted().joined(separator: ", "))",
        ]
        if let usage = lastUsage {
            lines.append("tokens (last turn): \(usage.inputTokens) in + \(usage.outputTokens) out = \(usage.totalTokens)")
        }
        let running = execSessions.list()
        if !running.isEmpty {
            lines.append("exec sessions: \(running.count) (\(running.filter(\.running).count) running)")
        }
        // 锁内快照（§5.5）：ingest 并行后 items.count 不能裸读。
        itemsLock.lock()
        let itemCount = items.count
        itemsLock.unlock()
        lines.append("transcript: \(itemCount) items (auto-compact at \(compactThreshold))")
        return lines.joined(separator: "\n")
    }

    /// `/mcp` — connected servers, their tools and resource availability.
    var mcpStatusText: String {
        guard !mcpClients.isEmpty else {
            return "no MCP servers connected — configure ~/.moppet/brain/mcp.json"
        }
        var lines: [String] = []
        for name in mcpClients.keys.sorted() {
            let tools = mcpToolInfos.filter { $0.server == name }
            lines.append("\(name): \(tools.count) tools" +
                (tools.isEmpty ? "" : " (" + tools.map(\.name).sorted().joined(separator: ", ") + ")"))
        }
        lines.append("resources: list_mcp_resources / read_mcp_resource available")
        return lines.joined(separator: "\n")
    }

    /// `/ps` — live exec sessions (codex background terminals).
    var execSessionsText: String {        let list = execSessions.list()
        guard !list.isEmpty else { return "no exec sessions" }
        return list.map { snapshot in
            "\(snapshot.id)  \(snapshot.running ? "running" : "exited(\(snapshot.exitCode.map(String.init) ?? "?"))")  \(snapshot.command.prefix(60))"
        }.joined(separator: "\n")
    }

    /// `/stop` — terminate sessions (all, or one by id). Returns what ran.
    @discardableResult
    func stopExecSessions(id: String? = nil) -> String {
        let stopped = execSessions.stop(id: id)
        guard !stopped.isEmpty else { return id.map { "no such session: \($0)" } ?? "no exec sessions" }
        return "stopped: \(stopped.joined(separator: ", "))"
    }

    /// `/export` — write the transcript as Markdown (codex /export parity).
    /// File lands in ~/.moppet/brain/exports/<sessionID>.md.
    func exportMarkdown() -> URL? {
        var lines = ["# \(PetIdentity.name) — session \(sessionID)", ""]
        // 锁内快照后遍历（§5.5）。
        itemsLock.lock()
        let snapshot = items
        itemsLock.unlock()
        for item in snapshot {
            switch item {
            case .message(let role, let content):
                lines.append(role == "user" ? "## 🧑 User" : "## 🐹 \(PetIdentity.name)")
                lines.append(content)
                lines.append("")
            case .reasoning(let summary):
                if !summary.isEmpty { lines.append("> _\(summary)_"); lines.append("") }
            case .functionCall(_, let name, let arguments):
                lines.append("**tool call:** `\(name)` `\(arguments.prefix(120))`")
            case .functionCallOutput(_, let output):
                lines.append("```\n\(output.prefix(2000))\n```"); lines.append("")
            case .plan(let steps):
                lines.append("**plan:** " + steps.map { step in
                    "[\(planMark(step.status))] \(step.step)"
                }.joined(separator: " · "))
                lines.append("")
            case .imageItem(let callID, _):
                lines.append("**image** (\(callID == "user" ? "attached by user" : "view_image \(callID)"))")
                lines.append("")
            case .taskResult(_, let title, let status, let summary, _):
                lines.append("**task \(status):** \(title)")
                lines.append(summary)
                lines.append("")
            }
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/exports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).md")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func planMark(_ status: String) -> String {
        switch status {
        case "completed": return "x"
        case "in_progress": return ">"
        default: return " "
        }
    }

    // MARK: - Growth (P2)

    /// Opens the turn: timestamps it, detects "the user said it again", and
    /// guesses the domain from words (tools refine it at the end).
    private func beginTurn(prompt: String) {
        turnStartedAt = Date()
        turnPrompt = prompt
        turnIndex += 1
        reAskedThisTurn = false
        correctedThisTurn = Self.correctionDetected(prompt)
        if let last = lastUserAt, Date().timeIntervalSince(last) < 120 {
            let overlap = CueMatcher.jaccard(CueMatcher.bigrams(lastUserPrompt),
                                             CueMatcher.bigrams(prompt))
            reAskedThisTurn = overlap >= 0.6
        }
        lastUserAt = Date()
        lastUserPrompt = prompt
    }

    /// "不对" / "我说的是…" / "that's wrong". Deliberately narrow: a false
    /// positive buys a reflection call the evidence cannot support, which is
    /// how the library fills with invented lessons.
    static func correctionDetected(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["不对", "不是这个", "不是我要", "我说的是", "搞错", "错了",
                       "不是让你", "你弄错",
                       "that's wrong", "that is wrong", "no, i meant", "not what i asked"]
        return markers.contains { lowered.contains($0) }
    }

    /// Lessons that matched this intent and this wording. Empty when growth is
    /// off — an opted-out user's prompt must stay byte-identical to before.
    private func growthDeveloperBlock(intent: IntentClass) -> String {
        guard GrowthSettings.enabled else { return "" }
        let block = LessonLibrary.injectedBlock(intent: intent, query: turnPrompt)
        return block.isEmpty ? "" : "\n\n" + block
    }

    /// Closes the turn: logs the outcome and, for a bad one, schedules a
    /// reflection. Never blocks the UI — the reflection runs detached.
    private func finishTurn(_ outcome: TurnOutcome) {
        previousIntent = outcome.intent
        // §5.12: the outcome belongs in the SESSION RECORD, not only in the
        // growth log — `Reflector.focus` reads it back by line number, and the
        // "which exit wrote what" question is answerable only if the record is
        // in the transcript's own timeline. Written unconditionally: it is one
        // small line in a file that already holds the whole transcript, and
        // gating it on the growth switch would leave resumed sessions with a
        // silently incomplete record.
        writer?.append(.turnOutcome(outcome))
        guard GrowthSettings.enabled else { return }
        TurnOutcomeLog.append(outcome)
        guard outcome.deservesReflection else { return }
        scheduleReflection(for: outcome)
    }

    private func scheduleReflection(for outcome: TurnOutcome) {
        // One reflection per session: `reflect/reply.md` is the durable marker,
        // so a relaunch does not re-buy the same conclusion.
        let marker = GrowthPaths.session(outcome.sessionID)
            .appendingPathComponent("reflect/reply.md")
        guard GrowthPaths.read(marker) == nil else { return }
        let tree = HarnessStore.load()
        let model = self.model
        let sessionID = outcome.sessionID
        let intent = outcome.intent
        let corrected = outcome.userCorrected
        Task.detached(priority: .utility) {
            let outcomes = TurnOutcomeLog.load(days: 1).filter { $0.sessionID == sessionID }
            let evidence = outcomes.isEmpty ? [outcome] : outcomes
            // §5.7's trigger list lives in one place; calling it here keeps
            // "user corrected" and "≥2 bad turns" from drifting apart from
            // the single `deservesReflection` shortcut.
            guard Reflector.shouldReflect(evidence, userCorrected: corrected) else { return }
            let result = await Reflector.reflect(
                sessionID: sessionID, outcomes: evidence,
                intent: intent, tree: tree, model: model)
            // The reason string is the audit trail: "budget exhausted",
            // "NO_ENTRY" and "empty reply" must stay distinguishable.
            _ = result.reason
        }
    }

    /// "I'll clean that up" with no state-changing call behind it. The pattern
    /// list is deliberately short: a false positive costs a bad verdict, and a
    /// bad verdict costs a reflection call.
    static func promisesAction(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["我来", "我会", "我马上", "这就", "正在为你", "开始清理", "已经帮你",
                       "i'll ", "i will ", "let me ", "starting now", "on it"]
        return markers.contains { lowered.contains($0) }
    }

    private func runLoop() async {
        // Approval decisions land in the growth log through this latch — the
        // closure fires from parallel tool children, hence the lock.
        let denied = FlagBox()
        var context = toolContext
        context.recordApproval = { [weak self] event in
            if !event.approved { denied.set() }
            self?.appendApproval(event)
        }
        let system = BrainInstructions.systemPrompt(
            cwd: cwd, sandboxMode: sandboxMode, approvalPolicy: approvalPolicy,
            networkAccess: networkAccess)
        let promptIntent = IntentClass.classify(text: turnPrompt, previous: previousIntent)
        let developer = BrainInstructions.assembleDeveloperMessage(cwd: cwd)
            + growthDeveloperBlock(intent: promptIntent)
        let specs = BrainTools.allSpecs(mcpTools: mcpToolInfos,
                                        mcpConnected: !mcpClients.isEmpty)

        var outcome = TurnOutcome(sessionID: sessionID, turnIndex: turnIndex,
                                  intent: promptIntent, startedAt: turnStartedAt)
        outcome.harnessFingerprint = GrowthLedger.shared.fingerprint(HarnessStore.load())
        outcome.reAskedWithin120s = reAskedThisTurn
        // Headless runs earn no verdict — they have no user to be right for.
        outcome.headless = ApprovalCenter.headlessAutoApprove || ApprovalCenter.headlessDeny

        /// The one exit path. Every `return` below goes through it, so a new
        /// exit added later cannot silently skip accounting.
        func finish(_ text: String?, usage: BrainUsage?) {
            outcome.wallSeconds = Date().timeIntervalSince(turnStartedAt)
            if let usage {
                outcome.inputTokens = usage.inputTokens
                outcome.outputTokens = usage.outputTokens
            }
            outcome.approvalDenied = denied.get
            outcome.userCorrected = correctedThisTurn
            if let text, !text.isEmpty, outcome.intent != .chat,
               Set(outcome.toolNames).isDisjoint(with: TurnOutcome.mutatingTools),
               Self.promisesAction(text) {
                outcome.promisedButNoAction = true
            }
            finishTurn(outcome)
        }

        // codex /compact parity: trim the context window before each submit.
        compactHistoryIfNeeded()

        for _ in 0..<maxTurnsPerSubmit {
            if Task.isCancelled {
                outcome.userCancelled = true
                finish(nil, usage: nil)
                return
            }

            var pendingCalls: [BrainToolCall] = []
            var turnFinal: String? = nil
            var usage: BrainUsage? = nil
            streamingText = ""

            do {
                // 历史锁内快照（§5.5）：model 拿到的是稳定副本，ingest/换血
                // 与流式请求互不干扰。
                let history = itemsLock.withLock { items }
                let stream = try await model.streamTurn(
                    system: system, developer: developer,
                    history: history, specs: specs
                )
                for try await event in stream {
                    if Task.isCancelled {
                        outcome.userCancelled = true
                        finish(nil, usage: nil)
                        return
                    }
                    switch event {
                    case .textDelta(let delta):
                        streamingText += delta
                        if announcesToPet {
                            PetBus.shared.setState(.talking)
                        }
                    case .toolCall(let call):
                        pendingCalls.append(call)
                    case .completed(let message, let eventUsage):
                        turnFinal = message
                        usage = eventUsage
                    }
                }
            } catch {
                lastError = error.localizedDescription
                streamingText = ""
                // Error announcement is single-path from the UI layers
                // (QuickChat / ChatView onEvent) — this internal say used to
                // double-broadcast over their localized bubbles.
                emit(.error(error.localizedDescription))
                finish(nil, usage: usage)
                return
            }

            if let usage {
                lastUsage = usage
                // Usage lives in lastUsage only — a fake reasoning item in
                // the rollout got replayed on resume and the Responses API
                // rejects non-model reasoning items with a 400.
            }

            // 终审修复（rev.2 上移）：取消检查点必须在 items/rollout 追加之
            // 前——轮顶（:936）与流事件（:956）两个既有检查点都在追加前触发，
            // 追加总是成对；检查点若放在追加之后，取消触发的 return 会留下无
            // 配对输出的孤儿 function_call（items+rollout 双写），按配对不变
            // 量（pairingSafe 文档）codex Responses 传输会在后续每轮 400，且
            // 仅在 ≥80 项压缩时自愈。与流事件检查点同形：已取消即丢弃未持久
            // 化输出，且不再派发任何工具（dismissForSource 只扫已安装请求，
            // 派发前复查拦住未安装的审批/提问）。
            if Task.isCancelled {
                outcome.userCancelled = true
                finish(nil, usage: nil)
                return
            }

            // Persist the model's turn output (message and/or calls) — 追加
            // 纳入 itemsLock（§5.5）：ingest 写点并行后无锁 append 是 UB。
            if !streamingText.isEmpty {
                itemsLock.withLock {
                    items.append(.message(role: "assistant", content: streamingText))
                }
                writer?.append(item: .message(role: "assistant", content: streamingText))
            }
            for call in pendingCalls {
                itemsLock.withLock {
                    items.append(.functionCall(callID: call.callID, name: call.name,
                                               arguments: call.argumentsJSON))
                }
                writer?.append(item: .functionCall(callID: call.callID, name: call.name,
                                                   arguments: call.argumentsJSON))
            }

            // No tool calls → the turn is complete.
            guard !pendingCalls.isEmpty else {
                let streamed = streamingText
                streamingText = ""
                let message: String? = turnFinal ?? (streamed.isEmpty ? nil : streamed)
                if let finalText = message, !finalText.isEmpty, announcesToPet {
                    // Full answer, and it stays until the next turn replaces
                    // it (hideAfter 0). The old prefix(90) cut answers short
                    // in the pet bubble; the bubble itself scrolls now.
                    PetBus.shared.say(finalText, state: .talking, hideAfter: 0)
                }
                // Domain from what it DID, now that we know the tools.
                outcome.intent = IntentClass.classify(
                    text: turnPrompt, tools: outcome.toolNames, previous: previousIntent)
                finish(message, usage: usage)
                emit(.turnCompleted(outputMessage: message, usage: usage))
                return
            }

            outcome.toolCalls += pendingCalls.count
            outcome.toolNames.append(contentsOf: pendingCalls.map(\.name))

            // Dispatch tool calls in parallel (codex runs tool calls concurrently).
            let notify: @Sendable (BrainEvent) -> Void = { [weak self] event in
                self?.emit(event)
            }
            let outputs: [BrainToolOutput] = await withTaskGroup(
                of: BrainToolOutput.self
            ) { group in
                for call in pendingCalls {
                    group.addTask {
                        notify(.toolStarted(name: call.name, callID: call.callID))
                        // Pose only — the old "→ tool" TEXT fought the bubble
                        // contract ("bubble shows results, not progress") in
                        // the QuickChat path; tool names live in the transcript.
                        if self.announcesToPet {
                            PetBus.shared.setState(.scanning)
                        }
                        let output = await BrainTools.dispatch(call: call, context: context) { event in
                            notify(event)
                        }
                        let isError = output.hasPrefix("error:")
                        notify(.toolFinished(name: call.name, callID: call.callID,
                                             output: output, isError: isError))
                        return BrainToolOutput(callID: call.callID, output: output, isError: isError)
                    }
                }
                var collected: [BrainToolOutput] = []
                for await output in group { collected.append(output) }
                return collected
            }

            outcome.toolErrors += outputs.filter(\.isError).count

            for output in outputs.sorted(by: { a, b in a.callID < b.callID }) {
                lastToolLine = "← \(output.output.prefix(120))"
                if output.output.hasPrefix("image:data:image/") {
                    // view_image result: a short text confirmation for chat-
                    // completions vendors + the image itself as a first-class
                    // conversation item (codex ImageViewItem). The sentinel is
                    // the full "image:data:image/…" prefix so ordinary tool
                    // output that merely starts with "image:" never matches.
                    let dataURL = String(output.output.dropFirst("image:".count))
                    let summary = Self.imageSummary(dataURL)
                    itemsLock.withLock {
                        items.append(.functionCallOutput(callID: output.callID, output: summary))
                        items.append(.imageItem(callID: output.callID, dataURL: dataURL))
                    }
                    writer?.append(item: .functionCallOutput(callID: output.callID, output: summary))
                    writer?.append(item: .imageItem(callID: output.callID, dataURL: dataURL))
                } else {
                    itemsLock.withLock {
                        items.append(.functionCallOutput(callID: output.callID, output: output.output))
                    }
                    writer?.append(item: .functionCallOutput(callID: output.callID, output: output.output))
                }
            }
        }
        lastError = "reached max turns (\(maxTurnsPerSubmit))"
        outcome.maxTurnsHit = true
        outcome.intent = IntentClass.classify(
            text: turnPrompt, tools: outcome.toolNames, previous: previousIntent)
        finish(nil, usage: nil)
        emit(.turnCompleted(outputMessage: nil, usage: nil))
    }

    /// Thread-safe one-bit latch: parallel tool children set it, the loop
    /// reads it once when the turn closes.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One line per approval decision. §5.12 (G2) puts it in the session
    /// record — that is the copy `Reflector.focus` renders as `(approval) …`
    /// when a reflection asks "what did the user refuse?". The per-session
    /// growth file is a convenience duplicate, written only when the user has
    /// opted in.
    private func appendApproval(_ event: ApprovalEvent) {
        writer?.append(.approvalEvent(event))
        guard GrowthSettings.enabled else { return }
        let url = GrowthPaths.session(sessionID).appendingPathComponent("approvals.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }
        GrowthPaths.write((GrowthPaths.read(url) ?? "") + line + "\n", to: url)
    }

    /// One-line human/model-readable summary of an image data URL.
    static func imageSummary(_ dataURL: String) -> String {
        let mime = dataURL.dropFirst("data:".count).prefix(while: { $0 != ";" })
        let base64 = dataURL.drop { $0 != "," }.dropFirst()
        let approxBytes = base64.utf8.count * 3 / 4
        return "success: image loaded (\(mime), ~\(approxBytes) bytes) — attached to the conversation"
    }

    private var toolContext: BrainTools.Context {
        BrainTools.Context(
            turn: BrainTurnContext(cwd: cwd, sandboxMode: sandboxMode,
                                   approvalPolicy: approvalPolicy, model: modelDescription,
                                   networkAccess: networkAccess, writableRoots: writableRoots),
            workspaceRoot: URL(fileURLWithPath: cwd),
            mcpClients: mcpClients,
            plan: plan,
            execSessions: execSessions,
            networkAccess: networkAccess,
            writableRoots: writableRoots,
            source: taskSource
        )
    }

    // MARK: - Parallel task support (设计文档 §5.5 / §5.9 / §5.12)

    /// 主 transcript 的唯一外部写入口之一（任务 prompt，提交时落盘）：纯任务
    /// 会话重启后 prompt 行也在。惰性 beginSession 复用 submit 语义；items
    /// 追加在 itemsLock 内，与 runLoop/compact 写点互斥。
    func ingestUserMessage(text: String, images: [String]) {
        let writer = itemsLock.withLock { () -> BrainRollout.Writer? in
            if self.writer == nil { beginSession() }
            items.append(.message(role: "user", content: text))
            for dataURL in images {
                items.append(.imageItem(callID: "user", dataURL: dataURL))
            }
            return self.writer
        }
        writer?.append(item: .message(role: "user", content: text))
        for dataURL in images {
            writer?.append(item: .imageItem(callID: "user", dataURL: dataURL))
        }
    }

    /// 主 transcript 的唯一外部写入口之二（任务结果卡，结束时落盘）。
    func ingestTaskResult(taskID: String, title: String, status: String,
                          summary: String, usage: BrainUsage?) {
        let item = BrainResponseItem.taskResult(
            taskID: taskID, title: title, status: status,
            summary: summary, usageTokens: usage.map { $0.totalTokens })
        let writer = itemsLock.withLock { () -> BrainRollout.Writer? in
            if self.writer == nil { beginSession() }
            items.append(item)
            return self.writer
        }
        writer?.append(item: item)
    }

    /// 任务车道子 agent（§5.12/§5.9）：独立实例、独立 rollout 文件；
    /// 模型/沙盒设置在 spawn 时快照——主 agent 运行中的改动只影响下一个任务。
    func makeTaskChild(taskID: String) -> BrainAgent {
        let child = BrainAgent(model: model, settings: settings)
        child.sandboxMode = sandboxMode
        child.approvalPolicy = approvalPolicy
        child.cwd = cwd
        child.maxTurnsPerSubmit = maxTurnsPerSubmit
        child.networkAccess = networkAccess
        child.writableRoots = writableRoots
        child.webSearchEnabled = webSearchEnabled
        // 子会话不自行拨 MCP：clients 从父实例拷贝共享（BrainMCPClient 是串行
        // queue 保护的 @unchecked Sendable，并行 dispatch 安全），工具清单拷贝
        // 后只读——specs 与 dispatch 都齐了，也无重复连接。
        child.mcpEnabled = false
        child.mcpClients = mcpClients
        child.mcpToolInfos = mcpToolInfos
        child.sessionID = "\(sessionID)-t\(taskID.dropFirst("task-".count))"
        child.originator = BrainRollout.taskOriginator
        child.taskSource = taskID
        return child
    }

    /// 无主 agent 可挂时的兜底子 agent（§5.2 startChild）。
    static func makeDefaultChild(taskID: String) -> BrainAgent {
        let child = BrainAgent()
        child.sessionID = "\(child.sessionID)-t\(taskID.dropFirst("task-".count))"
        child.originator = BrainRollout.taskOriginator
        child.taskSource = taskID
        return child
    }

    /// Serializes transcript mutations: emit(.planUpdated) fires from PARALLEL
    /// tool children while runLoop appends — unguarded Array writes race.
    private let itemsLock = NSLock()

    /// 会话文件已被 deleteAll 删除（ChatSessionStore 经调度器账本或 store 直达
    /// 本实例调用）：Writer 失效，后续 append（取消后展开中的工具输出、异步
    /// 结账的 task_result 行）直接丢弃——否则 Writer 兜底分支会用单条记录
    /// 重建无 sessionMeta 头的孤儿 JSONL（load() 读到即 nil、侧栏不可见、
    /// 无删除入口）。锁序 itemsLock→appendLock 与 beginSession/ingest 一致。
    func invalidateRollout() {
        itemsLock.withLock { writer?.invalidate() }
    }

    private func emit(_ event: BrainEvent) {
        onEvent?(event)
        switch event {
        case .planUpdated(let newPlan):
            itemsLock.lock()
            plan = newPlan
            // Plans are transcript items: the chat window renders them and
            // resume() replays the last one — without this the plan card was
            // dead UI and every resumed session forgot its plan.
            items.append(.plan(steps: newPlan.steps))
            let writer = self.writer
            itemsLock.unlock()
            writer?.append(item: .plan(steps: newPlan.steps))
        default:
            break
        }
    }

    // MARK: - Helpers

    static func parseArgs(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
