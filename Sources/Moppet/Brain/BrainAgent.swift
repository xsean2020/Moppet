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
    init(scripted: [[BrainStreamEvent]]) { self.scripted = scripted }

    func streamTurn(system: String, developer: String,
                    history: [BrainResponseItem],
                    specs: [BrainTools.Spec]) async throws -> AsyncThrowingStream<BrainStreamEvent, Error> {
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
            originator: "moppet-brain",
            cliVersion: "1.0.0",
            instructions: nil
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
                         networkAccess: networkAccess, writableRoots: writableRoots)
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
        guard !isRunning, !text.trimmingCharacters(in: .whitespaces).isEmpty || !images.isEmpty else { return }
        if writer == nil { beginSession() }
        // codex persists a turn_context per turn — /cd and mid-session
        // toggles survive restarts (they used to roll back on resume).
        writer?.append(context: turnContext)

        items.append(.message(role: "user", content: text))
        writer?.append(item: .message(role: "user", content: text))
        for dataURL in images {
            items.append(.imageItem(callID: "user", dataURL: dataURL))
            writer?.append(item: .imageItem(callID: "user", dataURL: dataURL))
        }
        // Never echo the user's question into the pet bubble — it's their
        // own words; show agent-side state instead (hideAfter 0 keeps the
        // bubble until the first delta/tool event replaces it).
        PetBus.shared.say(L("Thinking…"), state: .thinking, hideAfter: 0)

        isRunning = true
        lastError = nil
        emit(.turnStarted)

        loopGeneration += 1
        let generation = loopGeneration
        runTask = Task {
            await runLoop()
            // Only the CURRENT loop owns the flag/handle — a cancelled-but-
            // still-unwinding stale loop must not clobber a newer submit's
            // state (that's how double runLoops used to interleave).
            if generation == self.loopGeneration {
                self.isRunning = false
                self.runTask = nil
            }
        }
        await runTask?.value
    }

    /// Bumped by submit and cancel: lets a stale (cancelled) loop detect it
    /// no longer owns the session state.
    private var loopGeneration = 0

    func cancel() {
        loopGeneration += 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        lastError = "cancelled"
        execSessions.stopAll()
        PetBus.shared.settle()
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
        guard !items.isEmpty else { return "nothing to compact (empty session)" }
        guard !isRunning else { return "wait for the current turn to finish first" }
        // Own the running flag for the whole (multi-second) summary — a
        // concurrent submit used to interleave two writers on `items`.
        isRunning = true
        defer {
            loopGeneration += 1   // invalidate any racing loop's ownership
            isRunning = false
        }
        let summarizable = items.filter { item in
            switch item {
            case .message, .functionCall, .functionCallOutput: return true
            case .reasoning, .plan, .imageItem: return false
            }
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
            let head = items.prefix(2)
            let tail = items.suffix(min(compactKeepTail, max(0, items.count - 2)))
            var compacted = Array(head)
            compacted.append(.message(
                role: "user",
                content: "[compacted summary of earlier turns]\n\(summary)"))
            compacted.append(contentsOf: tail)
            let dropped = items.count - compacted.count
            items = Self.pairingSafe(compacted)
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
        lines.append("transcript: \(items.count) items (auto-compact at \(compactThreshold))")
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
        for item in items {
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

    private func runLoop() async {
        let context = toolContext
        let system = BrainInstructions.systemPrompt(
            cwd: cwd, sandboxMode: sandboxMode, approvalPolicy: approvalPolicy,
            networkAccess: networkAccess)
        let developer = BrainInstructions.assembleDeveloperMessage(cwd: cwd)
        let specs = BrainTools.allSpecs(mcpTools: mcpToolInfos,
                                        mcpConnected: !mcpClients.isEmpty)

        // codex /compact parity: trim the context window before each submit.
        compactHistoryIfNeeded()

        for _ in 0..<maxTurnsPerSubmit {
            if Task.isCancelled { return }

            var pendingCalls: [BrainToolCall] = []
            var turnFinal: String? = nil
            var usage: BrainUsage? = nil
            streamingText = ""

            do {
                let stream = try await model.streamTurn(
                    system: system, developer: developer,
                    history: items, specs: specs
                )
                for try await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .textDelta(let delta):
                        streamingText += delta
                        PetBus.shared.setState(.talking)
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
                return
            }

            if let usage {
                lastUsage = usage
                // Usage lives in lastUsage only — a fake reasoning item in
                // the rollout got replayed on resume and the Responses API
                // rejects non-model reasoning items with a 400.
            }

            // Persist the model's turn output (message and/or calls).
            if !streamingText.isEmpty {
                items.append(.message(role: "assistant", content: streamingText))
                writer?.append(item: .message(role: "assistant", content: streamingText))
            }
            for call in pendingCalls {
                items.append(.functionCall(callID: call.callID, name: call.name,
                                           arguments: call.argumentsJSON))
                writer?.append(item: .functionCall(callID: call.callID, name: call.name,
                                                   arguments: call.argumentsJSON))
            }

            // No tool calls → the turn is complete.
            guard !pendingCalls.isEmpty else {
                let streamed = streamingText
                streamingText = ""
                let message: String? = turnFinal ?? (streamed.isEmpty ? nil : streamed)
                if let finalText = message, !finalText.isEmpty {
                    PetBus.shared.say(String(finalText.prefix(90)), state: .talking)
                }
                emit(.turnCompleted(outputMessage: message, usage: usage))
                return
            }

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
                        PetBus.shared.setState(.scanning)
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
                    items.append(.functionCallOutput(callID: output.callID, output: summary))
                    writer?.append(item: .functionCallOutput(callID: output.callID, output: summary))
                    items.append(.imageItem(callID: output.callID, dataURL: dataURL))
                    writer?.append(item: .imageItem(callID: output.callID, dataURL: dataURL))
                } else {
                    items.append(.functionCallOutput(callID: output.callID, output: output.output))
                    writer?.append(item: .functionCallOutput(callID: output.callID, output: output.output))
                }
            }
        }
        lastError = "reached max turns (\(maxTurnsPerSubmit))"
        emit(.turnCompleted(outputMessage: nil, usage: nil))
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
            writableRoots: writableRoots
        )
    }

    /// Serializes transcript mutations: emit(.planUpdated) fires from PARALLEL
    /// tool children while runLoop appends — unguarded Array writes race.
    private let itemsLock = NSLock()

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
