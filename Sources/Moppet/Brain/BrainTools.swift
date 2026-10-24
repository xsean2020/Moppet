import Foundation

/// The Brain's tool layer — Codex tool set (shell / read_file / apply_patch /
/// update_plan) unified with this app's 19 cleaning tools and any connected
/// MCP-server tools, dispatched through one registry with the codex-style
/// sandbox × approval decision matrix.
enum BrainTools {

    struct Spec {
        let name: String
        let description: String
        let parametersJSONSchema: [String: Any]
        let risk: BrainToolRisk
    }

    // MARK: - Specs (Codex tool surface)

    static let shellSpec = Spec(
        name: "shell",
        description: """
        Executes the given shell command. Commands run inside a sandbox that \
        matches the current sandbox mode with network access on by default; \
        non-delete commands that hit a sandbox violation are escalated and \
        rerun automatically. Only file-deleting commands (rm family, find \
        -delete, git clean, trash) ask the user first. Prefer this for \
        inspecting the system, building, and running scripts.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "The shell command to execute."],
                "workdir": ["type": "string", "description": "Working directory (defaults to cwd)."],
                "timeout_ms": ["type": "number", "description": "Timeout in milliseconds (default 120000)."],
            ],
            "required": ["command"],
        ],
        risk: .systemEffect
    )

    static let readFileSpec = Spec(
        name: "read_file",
        description: "Reads a text file from the local filesystem (line-numbered, truncated to a byte budget).",
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Absolute or workspace-relative file path."],
                "offset": ["type": "number", "description": "1-based line to start from (optional)."],
                "limit": ["type": "number", "description": "Max lines to return (optional)."],
            ],
            "required": ["path"],
        ],
        risk: .readOnly
    )

    static let applyPatchSpec = Spec(
        name: "apply_patch",
        description: """
        Applies a patch using the Codex custom patch format to edit files. \
        Use this for precise edits instead of shell heredocs whenever possible. \
        Format: *** Begin Patch / *** Add File: / *** Update File: (with @@ \
        hunks: context lines, '-old', '+new') / *** Delete File: / \
        *** Move to: / *** End Patch.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "patch": ["type": "string", "description": "The patch text."],
            ],
            "required": ["patch"],
        ],
        risk: .writeWorkspace
    )

    static let updatePlanSpec = Spec(
        name: "update_plan",
        description: """
        Updates the task plan shown to the user. Use when the task needs \
        multiple steps. Set one step to 'in_progress' at a time; mark steps \
        'completed' as you finish them.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "plan": [
                    "type": "array",
                    "description": "The full list of steps in order.",
                    "items": ["type": "string"],
                ],
                "step_status": [
                    "type": "string",
                    "description": "Target status for the step at 'step_index'.",
                    "enum": ["pending", "in_progress", "completed"],
                ],
                "step_index": ["type": "number", "description": "Index of the step to change."],
            ],
            "required": ["plan"],
        ],
        risk: .readOnly
    )

    static var codexSpecs: [Spec] {
        [shellSpec, readFileSpec, applyPatchSpec, updatePlanSpec,
         viewImageSpec, execCommandSpec, writeStdinSpec, requestUserInputSpec]
    }

    // MARK: view_image (codex handlers/view_image.rs)

    static let viewImageSpec = Spec(
        name: "view_image",
        description: """
        Loads an image file into the conversation so you can see it. Returns \
        the image itself (as a data URL the model input accepts). Use this to \
        inspect screenshots, diagrams, exported charts, photos. Supported: \
        PNG, JPEG, GIF, WebP (≤10 MB). Only call it when the task truly needs \
        to see the image.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "Absolute or workspace-relative image path."],
            ],
            "required": ["path"],
        ],
        risk: .readOnly
    )

    // MARK: unified exec (codex exec_command / write_stdin)

    static let execCommandSpec = Spec(
        name: "exec_command",
        description: """
        Starts a command as a RESUMABLE exec session and waits up to \
        yield_time_ms for it to finish. If it is still running, returns \
        status "running" with a session_id — poll it or feed stdin with \
        write_stdin. There is no PTY (interactive full-screen programs will \
        not render); send plain stdin lines via write_stdin instead. Use for \
        long builds/tests/watchers; prefer the one-shot `shell` tool for \
        quick commands.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "cmd": ["type": "string", "description": "The command line to execute."],
                "workdir": ["type": "string", "description": "Working directory (defaults to cwd)."],
                "yield_time_ms": ["type": "number", "description": "How long to wait before returning while it keeps running (250–30000, default 10000)."],
                "timeout_ms": ["type": "number", "description": "Session lifetime cap in ms (max 300000)."],
                "max_output_tokens": ["type": "number", "description": "Approximate output character budget (default 20000)."],
            ],
            "required": ["cmd"],
        ],
        risk: .systemEffect
    )

    static let writeStdinSpec = Spec(
        name: "write_stdin",
        description: """
        Writes characters to a running exec session's stdin and/or waits for \
        more output. Provide chars to type into the process (include \\n for \
        Enter); omit/empty chars to poll for new output. Returns the same \
        status shape as exec_command.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "session_id": ["type": "string", "description": "Session id from exec_command."],
                "chars": ["type": "string", "description": "Characters to write to stdin (optional; \\n = Enter)."],
                "yield_time_ms": ["type": "number", "description": "How long to wait for output (default 5000)."],
                "max_output_tokens": ["type": "number", "description": "Approximate output character budget (default 20000)."],
            ],
            "required": ["session_id"],
        ],
        risk: .readOnly
    )

    // MARK: request_user_input (codex handlers/request_user_input_spec.rs)

    static let requestUserInputSpec = Spec(
        name: "request_user_input",
        description: """
        Asks the user 1–3 structured questions with 2–3 options each (an \
        "Other" free-text choice is added automatically). Use when the task \
        genuinely needs a user decision (which app to clean, destructive \
        scope confirmation preferences, ambiguous intent). The user's \
        answers come back as text; if they dismiss or ignore it, say so and \
        continue with a safe default instead of repeating the question.
        """,
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "description": "Stable id for the question."],
                            "header": ["type": "string", "description": "Short label, max 12 chars."],
                            "question": ["type": "string"],
                            "options": [
                                "type": "array",
                                "minItems": 2,
                                "maxItems": 3,
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string"],
                                        "description": ["type": "string"],
                                    ],
                                    "required": ["label"],
                                ],
                            ],
                        ],
                        "required": ["id", "header", "question", "options"],
                    ],
                ],
            ],
            "required": ["questions"],
        ],
        risk: .readOnly
    )

    // MARK: MCP resources (codex handlers/mcp_resource_spec.rs)

    static let listMcpResourcesSpec = Spec(
        name: "list_mcp_resources",
        description: "Lists resources exposed by connected MCP servers (documents/data the servers can serve by URI).",
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "server": ["type": "string", "description": "Server name (defaults to the only connected server)."],
            ],
        ],
        risk: .readOnly
    )

    static let listMcpResourceTemplatesSpec = Spec(
        name: "list_mcp_resource_templates",
        description: "Lists parameterized resource templates (uriTemplate) exposed by connected MCP servers.",
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "server": ["type": "string", "description": "Server name (defaults to the only connected server)."],
            ],
        ],
        risk: .readOnly
    )

    static let readMcpResourceSpec = Spec(
        name: "read_mcp_resource",
        description: "Reads one MCP resource's contents by URI.",
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "server": ["type": "string"],
                "uri": ["type": "string", "description": "Resource URI from list_mcp_resources / templates."],
            ],
            "required": ["server", "uri"],
        ],
        risk: .readOnly
    )

    static var mcpResourceSpecs: [Spec] {
        [listMcpResourcesSpec, listMcpResourceTemplatesSpec, readMcpResourceSpec]
    }

    /// All specs: codex tools + cleaning tools + MCP tools/resources.
    /// MCP resources are only offered when at least one server is connected
    /// (codex registers them per configured server, spec_plan.rs:1276).
    static func allSpecs(mcpTools: [(server: String, name: String, description: String, schema: [String: Any])],
                         mcpConnected: Bool = false) -> [Spec] {
        var specs = codexSpecs
        if mcpConnected {
            specs.append(contentsOf: mcpResourceSpecs)
        }
        for registryTool in ToolRegistry.tools {
            specs.append(Spec(
                name: registryTool.name,
                description: registryTool.description,
                parametersJSONSchema: registryTool.jsonSchema,
                risk: registryTool.destructive ? .destructive : .readOnly
            ))
        }
        for mcp in mcpTools {
            specs.append(Spec(
                name: "mcp__\(mcp.server)__\(mcp.name)",
                description: "[MCP:\(mcp.server)] \(mcp.description)",
                parametersJSONSchema: mcp.schema,
                risk: .systemEffect
            ))
        }
        return specs
    }

    // MARK: - Dispatch

    struct Context {
        var turn: BrainTurnContext
        var workspaceRoot: URL
        var mcpClients: [String: BrainMCPClient] = [:]
        var plan: BrainPlan = .empty
        var execSessions: BrainExecSessionRegistry?
        var networkAccess: Bool = false
        var writableRoots: [String] = []
    }

    /// Executes one tool call. Returns output text for the model. A return
    /// value starting with "image:" carries a data URL — the agent loop
    /// turns it into an image conversation item in addition to the normal
    /// tool output (see runLoop).
    static func dispatch(call: BrainToolCall, context: Context,
                         emit: @escaping (BrainEvent) -> Void) async -> String {
        do {
            switch call.name {
            case "shell":
                return try await runShell(call, context: context, emit: emit)
            case "read_file":
                return try runReadFile(call, context: context)
            case "apply_patch":
                return try await runApplyPatch(call, context: context, emit: emit)
            case "update_plan":
                return try runUpdatePlan(call, context: context, emit: emit)
            case "view_image":
                return try runViewImage(call, context: context)
            case "exec_command":
                return try await runExecCommand(call, context: context, emit: emit)
            case "write_stdin":
                return try await runWriteStdin(call, context: context)
            case "request_user_input":
                return try await runRequestUserInput(call, context: context)
            case "list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource":
                return try await runMCPResource(call, context: context)
            default:
                if call.name.hasPrefix("mcp__") {
                    return try await runMCP(call, context: context, emit: emit)
                }
                if ToolRegistry.tool(named: call.name) != nil {
                    return try await runCleaningTool(call, context: context, emit: emit)
                }
                throw BrainError("unknown tool: \(call.name)")
            }
        } catch let patchError as ApplyPatch.PatchError {
            return "error: \(patchError.localizedDescription)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: shell (with codex's approval decision matrix)

    private static func runShell(_ call: BrainToolCall, context: Context,
                                 emit: @escaping (BrainEvent) -> Void) async throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let command = args["command"] as? String, !command.isEmpty else {
            throw BrainError("shell: missing 'command'")
        }
        let cwd = (args["workdir"] as? String).map { URL(fileURLWithPath: $0) }?.path ?? context.turn.cwd
        // Clamp the model-controlled timeout: unbounded values parked a
        // shell slot for hours; negatives killed the child instantly.
        let timeoutMS = min(max((args["timeout_ms"] as? Double) ?? 120_000, 1_000), 600_000)

        // Decision matrix (simplified from codex core/tools/handlers + approvals):
        // - untrusted        → always ask
        // - on-request       → delete commands ask up front; everything else
        //                      runs sandboxed and, on sandbox violation,
        //                      auto-escalates (no prompt — non-delete just works)
        // - never            → run sandboxed; violations return to model
        // - full-access mode → runs unsandboxed (mode allows it)
        func shouldAskFirst() -> Bool {
            context.turn.approvalPolicy == .untrusted
        }

        if shouldAskFirst() {
            let approved = await requestApproval(
                "shell (untrusted project)", command, emit: emit)
            guard approved else { return "error: user declined to run command" }
            let result = await BrainSandbox.runUnsandboxed(command: command, cwd: cwd,
                                                           timeout: timeoutMS / 1000)
            return result.formatted
        }

        // Deletion is the one thing that always needs explicit consent in
        // interactive policies — everything else must "just work" from the
        // pet chat (the user's rule: 除了删除，其他 bash 命令都允许).
        var deleteApproved = false
        if context.turn.approvalPolicy != .never,
           BrainSandbox.involvesDeletion(command) {
            let approved = await requestApproval(
                "shell — this command deletes files", command, emit: emit)
            guard approved else { return "error: user declined the delete command" }
            deleteApproved = true
        }

        let result = await BrainSandbox.run(
            command: command, cwd: cwd,
            mode: context.turn.sandboxMode,
            workspaceRoot: context.workspaceRoot.path,
            networkAccess: context.networkAccess,
            writableRoots: context.writableRoots,
            timeout: timeoutMS / 1000
        )

        if result.sandboxViolation || result.exitCode != 0 && result.stderr.contains("sandbox") {
            // Codex behaviour escalates on sandbox failure — but only ASK for
            // deletes (already consented above → escalate directly). Non-delete
            // commands auto-escalate: the sandbox is a guardrail, not a gate.
            if context.turn.approvalPolicy == .onRequest {
                let escalated = await BrainSandbox.runUnsandboxed(
                    command: command, cwd: cwd, timeout: timeoutMS / 1000)
                let note = deleteApproved ? "escalated (delete approved)"
                                          : "auto-escalated (non-delete)"
                return "sandboxed run failed; \(note):\n" + escalated.formatted
            }
            return "error: command was blocked by the sandbox policy " +
                   "(\(context.turn.sandboxMode.rawValue)). exit: \(result.exitCode)\n\(result.output)"
        }
        return result.formatted
    }

    private static func requestApproval(_ title: String, _ detail: String,
                                        emit: @escaping (BrainEvent) -> Void) async -> Bool {
        emit(.approvalRequested(name: title, detail: detail))
        // Headless --yes: approve without touching the UI layer (the MainActor
        // request below can never run when the main thread is blocked).
        if ApprovalCenter.headlessAutoApprove {
            emit(.approvalResolved(approved: true))
            return true
        }
        if ApprovalCenter.headlessDeny {
            emit(.approvalResolved(approved: false))
            return false
        }
        let approved = await ApprovalCenter.shared.request(title: "Brain · \(title)", detail: detail)
        emit(.approvalResolved(approved: approved))
        return approved
    }

    // MARK: read_file (codex: line-numbered, budgeted)

    /// The app's own credential/config stores are never model-readable:
    /// paired with default-on network access they form a one-shot exfil
    /// chain (read key → curl it out, neither step being a "deletion").
    private static func denyCredentialStores(_ url: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return }
        let guarded = [
            ".moppet/ai-keys.json",        // every vendor API key
            ".moppet/brain/mcp.json",      // MCP env can carry secrets
            ".moppet/brain/sessions",      // full transcripts + imageItems
        ]
        if guarded.contains(where: { path.hasPrefix(home + "/" + $0) }) {
            throw BrainError("access denied: \(url.lastPathComponent) is a Moppet credential or config store")
        }
    }

    private static func runReadFile(_ call: BrainToolCall, context: Context) throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let path = args["path"] as? String else {
            throw BrainError("read_file: missing 'path'")
        }
        let url = URL(fileURLWithPath: path.hasPrefix("/") ? path :
                        context.workspaceRoot.appendingPathComponent(path).path)
        try Self.denyCredentialStores(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BrainError("file not found: \(url.path)")
        }
        guard url.pathExtension.lowercased() != "png" else {
            throw BrainError("binary file (use shell for binaries)")
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        // Model-controlled numbers: clamp both ends — prefix(-1) is a
        // runtime trap that takes the whole app down.
        let offset = min(max(1, (args["offset"] as? Double).map(Int.init) ?? 1), 1_000_000)
        let limit = min(max(0, (args["limit"] as? Double).map(Int.init) ?? 2000), 2000)
        if offset > 1 { lines = Array(lines.dropFirst(offset - 1)) }
        lines = Array(lines.prefix(limit))

        var out = lines.enumerated().map { i, line in
            String(format: "%5lld %@", Int64(offset + i), line)
        }.joined(separator: "\n")

        let budget = 32_768
        if out.utf16.count > budget {
            let prefix = out.prefix(budget)
            out = prefix + "\n… [truncated: file continues]"
        }
        return out
    }

    // MARK: apply_patch

    private static func runApplyPatch(_ call: BrainToolCall, context: Context,
                                      emit: @escaping (BrainEvent) -> Void) async throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let patch = args["patch"] as? String, !patch.isEmpty else {
            throw BrainError("apply_patch: missing 'patch'")
        }
        // Sandbox check: when the turn is read-only, file edits are forbidden.
        guard context.turn.sandboxMode != .readOnly else {
            throw BrainError("apply_patch blocked: sandbox mode is read-only")
        }
        // Deletions and renames go through the SAME approval gate as shell
        // deletes — without this, "*** Delete File:" removed files with zero
        // prompts under every approval policy (including untrusted).
        let deletionTargets = ApplyPatch.deletionTargets(in: patch)
        if !deletionTargets.isEmpty {
            let approved = await requestApproval(
                "apply_patch deletes \(deletionTargets.count) file\(deletionTargets.count == 1 ? "" : "s")",
                deletionTargets.prefix(20).joined(separator: "\n"), emit: emit)
            guard approved else { return "error: user declined apply_patch (deletion)" }
        }
        let result = try ApplyPatch.apply(patch, workspaceRoot: context.workspaceRoot)
        var text = "success: \(result.summary)"
        if !result.added.isEmpty { text += "\nadded: " + result.added.joined(separator: ", ") }
        if !result.updated.isEmpty { text += "\nupdated: " + result.updated.joined(separator: ", ") }
        if !result.deleted.isEmpty { text += "\ndeleted: " + result.deleted.joined(separator: ", ") }
        if !result.moved.isEmpty {
            text += "\nmoved: " + result.moved.map { "\($0.0) → \($0.1)" }.joined(separator: ", ")
        }
        return text
    }

    // MARK: update_plan

    private static func runUpdatePlan(_ call: BrainToolCall, context: Context,
                                      emit: @escaping (BrainEvent) -> Void) throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let planStrings = args["plan"] as? [String] else {
            throw BrainError("update_plan: missing 'plan' array")
        }
        var plan = BrainPlan(steps: planStrings.map { BrainPlanStep(step: $0, status: "pending") })
        // Mutate semantics: callers may provide full new plan; step changes via index.
        if let idx = (args["step_index"] as? Double).map(Int.init),
           let status = args["step_status"] as? String,
           plan.steps.indices.contains(idx) {
            plan.steps[idx].status = status
        } else if plan.steps.count == 1 {
            plan.steps[0].status = "in_progress"
        }
        emit(.planUpdated(plan))
        return "plan updated (\(plan.steps.count) steps)"
    }

    // MARK: cleaning tools (ToolRegistry)

    /// Built-in cleaning tools are first-class Brain tools: the registry's
    /// full schema/safety surface, with ONE native approval dialog (the
    /// brain's own) instead of double prompting.
    private static func runCleaningTool(_ call: BrainToolCall, context: Context,
                                        emit: @escaping (BrainEvent) -> Void) async throws -> String {
        var args = BrainAgent.parseArgs(call.argumentsJSON) ?? [:]
        guard let spec = ToolRegistry.tool(named: call.name) else {
            throw BrainError("unknown cleaning tool")
        }
        if spec.destructive {
            let approved = await requestApproval(
                "cleaning tool \(call.name)",
                prettyArgs(args), emit: emit)
            guard approved else { return "error: user declined \(call.name)" }
            // Approval already granted natively — clear ToolRegistry's gate.
            args["confirmed"] = true
        }
        return try await ToolRegistry.execute(name: call.name, args: args, approval: .confirmedFlag)
    }

    private static func prettyArgs(_ args: [String: Any]) -> String {
        args.map { "\($0.key): \(String(describing: $0.value).prefix(160))" }
            .joined(separator: "\n")
    }

    // MARK: view_image

    /// Loads an image and returns it as `image:<data URL>`; the agent loop
    /// converts that sentinel into an image conversation item (codex returns
    /// an ImageViewItem in place of a plain function output).
    private static func runViewImage(_ call: BrainToolCall, context: Context) throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let path = args["path"] as? String, !path.isEmpty else {
            throw BrainError("view_image: missing 'path'")
        }
        let url = URL(fileURLWithPath: path.hasPrefix("/") ? path :
                        context.workspaceRoot.appendingPathComponent(path).path)
        try Self.denyCredentialStores(url)
        guard let data = try? Data(contentsOf: url) else {
            throw BrainError("unable to read image at \(url.path)")
        }
        guard data.count <= 10 * 1_048_576 else {
            throw BrainError("image too large (\(data.count) bytes; max 10 MB)")
        }
        guard let mime = Self.imageMIME(data) else {
            throw BrainError("unable to process image: invalid or unsupported image data (PNG/JPEG/GIF/WebP only)")
        }
        let dataURL = "data:\(mime);base64," + data.base64EncodedString()
        return "image:\(dataURL)"
    }

    /// Magic-byte sniffing (no ImageIO dependency; matches the formats the
    /// model endpoints accept).
    static func imageMIME(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }

    // MARK: exec_command / write_stdin (unified exec)

    private static func formattedExec(status: String, sessionID: String?,
                                      exitCode: Int32?, output: String,
                                      budget: Int) -> String {
        var text = "status: \(status)"
        if let sessionID { text += "\nsession_id: \(sessionID)" }
        if let exitCode { text += "\nexit: \(exitCode)" }
        text += "\noutput:\n\(output)"
        if text.count > budget {
            text = String(text.prefix(budget)) + "\n… [truncated]"
        }
        return text
    }

    private static func runExecCommand(_ call: BrainToolCall, context: Context,
                                       emit: @escaping (BrainEvent) -> Void) async throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let command = args["cmd"] as? String, !command.isEmpty else {
            throw BrainError("exec_command: missing 'cmd'")
        }
        guard let registry = context.execSessions else {
            throw BrainError("exec sessions are unavailable")
        }
        let cwd = (args["workdir"] as? String) ?? context.turn.cwd
        let yieldMS = min(max((args["yield_time_ms"] as? Double) ?? 10_000, 250), 30_000)
        let budget = min(max((args["max_output_tokens"] as? Double).map(Int.init) ?? 20_000, 0), 100_000)

        // Same decision matrix as the shell tool: untrusted asks first and
        // then runs unsandboxed; delete commands ask up front; other policies
        // start sandboxed.
        if context.turn.approvalPolicy == .untrusted {
            let approved = await requestApproval("exec_command (untrusted project)", command, emit: emit)
            guard approved else { return "error: user declined to run command" }
            guard let session = registry.start(
                command: command, cwd: cwd, mode: .dangerFullAccess,
                workspaceRoot: context.workspaceRoot.path,
                networkAccess: true, writableRoots: []) else {
                throw BrainError("failed to spawn command")
            }
            let code = await session.wait(seconds: yieldMS / 1000)
            return formattedExec(status: code == nil ? "running" : "completed",
                                 sessionID: session.id, exitCode: code,
                                 output: session.drainOutput(), budget: budget)
        }

        var deleteApproved = false
        if context.turn.approvalPolicy != .never,
           BrainSandbox.involvesDeletion(command) {
            let approved = await requestApproval(
                "exec_command — this command deletes files", command, emit: emit)
            guard approved else { return "error: user declined the delete command" }
            deleteApproved = true
        }

        guard let session = registry.start(
            command: command, cwd: cwd, mode: context.turn.sandboxMode,
            workspaceRoot: context.workspaceRoot.path,
            networkAccess: context.networkAccess,
            writableRoots: context.writableRoots) else {
            throw BrainError("failed to spawn command")
        }
        let code = await session.wait(seconds: yieldMS / 1000)

        // Sandbox violation that killed the process instantly → same rules as
        // the shell tool: deletes (already consented) escalate directly, and
        // NON-delete commands auto-escalate without a prompt.
        if code == 125, context.turn.approvalPolicy == .onRequest {
            _ = session.drainOutput()
            guard let escalated = registry.start(
                command: command, cwd: cwd, mode: .dangerFullAccess,
                workspaceRoot: context.workspaceRoot.path,
                networkAccess: true, writableRoots: []) else {
                throw BrainError("failed to spawn escalated command")
            }
            let escalatedCode = await escalated.wait(seconds: yieldMS / 1000)
            let note = deleteApproved ? "escalated (delete approved)"
                                      : "auto-escalated (non-delete)"
            return "sandboxed run was blocked; \(note):\n" +
                formattedExec(status: escalatedCode == nil ? "running" : "completed",
                              sessionID: escalated.id, exitCode: escalatedCode,
                              output: escalated.drainOutput(), budget: budget)
        }
        return formattedExec(status: code == nil ? "running" : "completed",
                             sessionID: session.id, exitCode: code,
                             output: session.drainOutput(), budget: budget)
    }

    private static func runWriteStdin(_ call: BrainToolCall, context: Context) async throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let sessionID = args["session_id"] as? String, !sessionID.isEmpty else {
            throw BrainError("write_stdin: missing 'session_id'")
        }
        guard let registry = context.execSessions else {
            throw BrainError("exec sessions are unavailable")
        }
        guard let session = registry.session(id: sessionID) else {
            throw BrainError("no such exec session: \(sessionID)")
        }
        if let chars = args["chars"] as? String, !chars.isEmpty {
            session.write(chars)
        }
        let yieldMS = min(max((args["yield_time_ms"] as? Double) ?? 5_000, 250), 60_000)
        let budget = min(max((args["max_output_tokens"] as? Double).map(Int.init) ?? 20_000, 0), 100_000)
        let code = await session.wait(seconds: yieldMS / 1000)
        if code != nil {
            // Let the readability handler flush the final buffered chunk.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return formattedExec(status: code == nil ? "running" : "completed",
                             sessionID: sessionID, exitCode: code,
                             output: session.drainOutput(), budget: budget)
    }

    // MARK: request_user_input

    private static func runRequestUserInput(_ call: BrainToolCall,
                                            context: Context) async throws -> String {
        guard let args = BrainAgent.parseArgs(call.argumentsJSON),
              let rawQuestions = args["questions"] as? [[String: Any]],
              (1...3).contains(rawQuestions.count) else {
            throw BrainError("request_user_input: 'questions' must contain 1–3 items")
        }
        var questions: [UserInputQuestion] = []
        for raw in rawQuestions {
            guard let id = raw["id"] as? String,
                  let question = raw["question"] as? String,
                  let rawOptions = raw["options"] as? [[String: Any]],
                  (2...3).contains(rawOptions.count) else {
                throw BrainError("request_user_input: each question needs id, question and 2–3 options")
            }
            let options = rawOptions.compactMap { option -> UserInputQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return UserInputQuestion.Option(label: label,
                                                description: option["description"] as? String ?? "")
            }
            guard options.count == rawOptions.count else {
                throw BrainError("request_user_input: option labels missing")
            }
            questions.append(UserInputQuestion(
                id: id,
                header: String((raw["header"] as? String) ?? id).prefix(12).description,
                question: question, options: options))
        }
        guard let answers = await UserInputCenter.shared.request(questions: questions) else {
            return "error: user did not answer (dismissed or timed out) — proceed with a safe default or explain what you need"
        }
        return questions.compactMap { q in
            answers[q.id].map { "\(q.id): \($0)" }
        }.joined(separator: "\n")
    }

    // MARK: MCP resources

    private static func runMCPResource(_ call: BrainToolCall, context: Context) async throws -> String {
        let args = BrainAgent.parseArgs(call.argumentsJSON) ?? [:]
        guard !context.mcpClients.isEmpty else {
            throw BrainError("no MCP servers are connected")
        }
        func resolveServer(_ name: String?) throws -> (String, BrainMCPClient) {
            if let name, let client = context.mcpClients[name] {
                return (name, client)
            }
            if name == nil, context.mcpClients.count == 1,
               let only = context.mcpClients.first {
                return (only.key, only.value)
            }
            let available = context.mcpClients.keys.sorted().joined(separator: ", ")
            throw BrainError("specify 'server' — connected: \(available)")
        }

        switch call.name {
        case "list_mcp_resources":
            let (name, client) = try resolveServer(args["server"] as? String)
            let resources = try await client.listResources()
            guard !resources.isEmpty else { return "(no resources on \(name))" }
            return resources.map { resource in
                "\(resource.uri) — \(resource.name)\(resource.description.map { " — \($0)" } ?? "")"
            }.joined(separator: "\n")
        case "list_mcp_resource_templates":
            let (name, client) = try resolveServer(args["server"] as? String)
            let templates = try await client.listResourceTemplates()
            guard !templates.isEmpty else { return "(no resource templates on \(name))" }
            return templates.map { "\($0.uri) — \($0.name)" }.joined(separator: "\n")
        case "read_mcp_resource":
            guard let server = args["server"] as? String, let uri = args["uri"] as? String else {
                throw BrainError("read_mcp_resource: 'server' and 'uri' are required")
            }
            guard let client = context.mcpClients[server] else {
                throw BrainError("MCP server not connected: \(server)")
            }
            return try await client.readResource(uri: uri)
        default:
            throw BrainError("unknown MCP resource tool")
        }
    }

    // MARK: MCP tools

    private static func runMCP(_ call: BrainToolCall, context: Context,
                               emit: @escaping (BrainEvent) -> Void) async throws -> String {
        // name format: mcp__<server>__<tool>
        let parts = call.name.components(separatedBy: "__")
        guard parts.count >= 3 else { throw BrainError("bad MCP tool name: \(call.name)") }
        let server = parts[1]
        let tool = parts.dropFirst(2).joined(separator: "__")
        guard let client = context.mcpClients[server] else {
            throw BrainError("MCP server not connected: \(server)")
        }
        let args = BrainAgent.parseArgs(call.argumentsJSON) ?? [:]
        // External MCP tools carry capabilities we cannot classify — under
        // the interactive approval policies they pass the same gate shell
        // does (they used to run with NO prompt under every policy).
        if context.turn.approvalPolicy == .untrusted || context.turn.approvalPolicy == .onRequest {
            let approved = await requestApproval("MCP tool \(call.name)", prettyArgs(args), emit: emit)
            guard approved else { return "error: user declined \(call.name)" }
        }
        return try await client.callTool(name: tool, arguments: args)
    }
}
