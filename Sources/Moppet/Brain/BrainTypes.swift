import Foundation

/// The Brain — a faithful Swift port of OpenAI Codex's agent capability set,
/// serving as the desktop pet's brain. Type system mirrors
/// codex-rs/protocol: approval policies, sandbox modes, and event stream.
///
/// Sources studied: codex-rs `core/` (agent loop, tools, SSE client),
/// `protocol/` (AskForApproval, SandboxMode), `apply-patch/` (patch format),
/// `rollout/` (JSONL session records), `rmcp-client/` (MCP), `agents_md.rs`.
/// License: Apache-2.0 (upstream openai/codex).

// MARK: - Approval policy (protocol.rs AskForApproval)

enum BrainApprovalPolicy: String, Codable, CaseIterable, Identifiable {
    /// codex `untrusted`: every command needs approval unless explicitly allowed.
    case untrusted
    /// codex `on-request` (alias on-failure, the default): the model decides
    /// when to escalate; failures can be retried after user approval.
    case onRequest = "on-request"
    /// codex `never`: never ask; failures return straight to the model.
    case never

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .untrusted: "Untrusted (ask for every command)"
        case .onRequest: "On request (model decides)"
        case .never: "Never (auto-run)"
        }
    }

    /// Compact label for space-constrained menus — the full semantics live
    /// in the menu's tooltip (fixed-width pickers truncated displayName to
    /// "On request (model…").
    var shortName: String {
        switch self {
        case .untrusted: "Ask always"
        case .onRequest: "On request"
        case .never: "Never ask"
        }
    }
}

// MARK: - Sandbox mode (config_types.rs SandboxMode)

enum BrainSandboxMode: String, Codable, CaseIterable, Identifiable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .readOnly: "Read-only"
        case .workspaceWrite: "Workspace write"
        case .dangerFullAccess: "Full access (danger)"
        }
    }
}

/// Per-turn context, equivalent of codex TurnContext. `networkAccess` and
/// `writableRoots` mirror codex `sandbox_workspace_write.{network_access,
/// writable_roots}`; they decode as defaults so pre-v15.26 rollouts resume.
struct BrainTurnContext: Codable {
    var cwd: String
    var sandboxMode: BrainSandboxMode
    var approvalPolicy: BrainApprovalPolicy
    var model: String
    var networkAccess: Bool?
    var writableRoots: [String]?
    /// When this turn began — the anchor `wallSeconds` and the
    /// "re-asked within 120s" signal need (design doc §5.12, G3).
    var startedAt: Date?

    init(cwd: String, sandboxMode: BrainSandboxMode,
         approvalPolicy: BrainApprovalPolicy, model: String,
         networkAccess: Bool? = nil, writableRoots: [String]? = nil,
         startedAt: Date? = nil) {
        self.cwd = cwd
        self.sandboxMode = sandboxMode
        self.approvalPolicy = approvalPolicy
        self.model = model
        self.networkAccess = networkAccess
        self.writableRoots = writableRoots
        self.startedAt = startedAt
    }

    // Keys stay camelCase (the pre-synthesized encoding) so existing rollout
    // files keep decoding; only the new fields are optional additions.
    private enum CodingKeys: String, CodingKey {
        case cwd, sandboxMode, approvalPolicy, model, networkAccess, writableRoots, startedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decode(String.self, forKey: .cwd)
        sandboxMode = try c.decode(BrainSandboxMode.self, forKey: .sandboxMode)
        approvalPolicy = try c.decode(BrainApprovalPolicy.self, forKey: .approvalPolicy)
        model = try c.decode(String.self, forKey: .model)
        networkAccess = try c.decodeIfPresent(Bool.self, forKey: .networkAccess)
        writableRoots = try c.decodeIfPresent([String].self, forKey: .writableRoots)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
    }
}

// MARK: - Response items (Responses-API shaped conversation items)

enum BrainResponseItem: Codable, Equatable {
    case message(role: String, content: String)
    case reasoning(summary: String)
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)
    case plan(steps: [BrainPlanStep])
    /// An image entering the conversation — either a `view_image` tool result
    /// (codex `ImageViewItem`, callID = the tool call) or a user-attached
    /// image (callID = "user"). Carries a `data:` URL so it survives the
    /// rollout round-trip; each transport re-encodes it natively
    /// (Responses `input_image` / SDK image part).
    case imageItem(callID: String, dataURL: String)

    private enum CodingKeys: String, CodingKey {
        case type, role, content, summary, callID = "call_id", name, arguments, output, steps
        case dataURL = "data_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "message":
            self = .message(role: try c.decode(String.self, forKey: .role),
                            content: try c.decode(String.self, forKey: .content))
        case "reasoning":
            self = .reasoning(summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
        case "function_call":
            self = .functionCall(callID: try c.decode(String.self, forKey: .callID),
                                 name: try c.decode(String.self, forKey: .name),
                                 arguments: try c.decode(String.self, forKey: .arguments))
        case "function_call_output":
            self = .functionCallOutput(callID: try c.decode(String.self, forKey: .callID),
                                       output: try c.decode(String.self, forKey: .output))
        case "plan":
            self = .plan(steps: try c.decodeIfPresent([BrainPlanStep].self, forKey: .steps) ?? [])
        case "image":
            self = .imageItem(callID: try c.decodeIfPresent(String.self, forKey: .callID) ?? "user",
                              dataURL: try c.decode(String.self, forKey: .dataURL))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown item type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try c.encode("message", forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
        case .reasoning(let summary):
            try c.encode("reasoning", forKey: .type)
            try c.encode(summary, forKey: .summary)
        case .functionCall(let callID, let name, let arguments):
            try c.encode("function_call", forKey: .type)
            try c.encode(callID, forKey: .callID)
            try c.encode(name, forKey: .name)
            try c.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try c.encode("function_call_output", forKey: .type)
            try c.encode(callID, forKey: .callID)
            try c.encode(output, forKey: .output)
        case .plan(let steps):
            try c.encode("plan", forKey: .type)
            try c.encode(steps, forKey: .steps)
        case .imageItem(let callID, let dataURL):
            try c.encode("image", forKey: .type)
            try c.encode(callID, forKey: .callID)
            try c.encode(dataURL, forKey: .dataURL)
        }
    }
}

// MARK: - Plan (codex update_plan tool model)

struct BrainPlanStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var step: String
    var status: String   // pending | in_progress | completed

    private enum CodingKeys: String, CodingKey { case id, step, status }
    init(step: String, status: String) {
        self.step = step
        self.status = status
    }
}

struct BrainPlan: Codable, Equatable {
    var steps: [BrainPlanStep] = []

    static let empty = BrainPlan()
}

// MARK: - Live events emitted to UI / pet (EventMsg analogue)

enum BrainEvent {
    case turnStarted
    case assistantMessageDelta(String)
    case reasoningDelta(String)
    case toolStarted(name: String, callID: String)
    case toolFinished(name: String, callID: String, output: String, isError: Bool)
    case approvalRequested(name: String, detail: String)
    case approvalResolved(approved: Bool)
    case planUpdated(BrainPlan)
    case turnCompleted(outputMessage: String?, usage: BrainUsage?)
    case error(String)
}

struct BrainUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - Tool call / dispatch model

struct BrainToolCall: Equatable {
    let callID: String
    let name: String
    let argumentsJSON: String
}

struct BrainToolOutput {
    let callID: String
    let output: String
    let isError: Bool
}

/// How a tool wants to be executed w.r.t. sandbox & approval — mirrors the
/// codex shell-tool decision matrix.
enum BrainToolRisk {
    /// Read-only, no side effects: run without sandbox or approval.
    case readOnly
    /// Writes inside the workspace: runs sandboxed under the turn's mode.
    case writeWorkspace
    /// Arbitrary system effects: requires escalation decision.
    case systemEffect
    /// Destructive cleaning tool: always requires explicit user approval.
    case destructive
}

// MARK: - Errors

struct BrainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
