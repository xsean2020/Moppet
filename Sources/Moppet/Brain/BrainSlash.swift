import Foundation

/// Shared slash-command runner — codex TUI commands expressed as chat-level
/// actions. The chat window and the quick bar both call `run`; UI-only
/// commands (/new /export /copy) return nil so each surface can handle (or
/// decline) them natively.
enum BrainSlash {

    /// Runs a command. Returns output text (nil = unknown or UI-only — the
    /// caller decides what to do; `uiOnly` lists what needs a richer surface).
    /// `tasks`（设计文档 §8）：任务车道调度器，/tasks 报告用；默认 nil，
    /// 既有调用点（quick bar）零破坏。
    static func run(_ raw: String, brain: BrainAgent,
                    tasks: BrainTaskScheduler? = nil) async -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "empty command — /help lists commands" }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch command {
        case "/help":
            return (SlashCommand.all.map { "\($0.name) — \($0.summary)" }
                + ["(chat window only: /new, /export, /copy)"])
                .joined(separator: "\n")
        case "/status":
            return brain.statusText
        case "/mcp":
            return brain.mcpStatusText
        case "/tasks":
            guard let tasks else { return nil }   // 无调度器的入口（quick bar）：UI-only
            return await Self.tasksReport(tasks)
        case "/compact":
            guard !brain.isRunning else { return "brain is running — try again after the turn" }
            return await brain.compactNow()
        case "/init":
            guard !brain.isRunning else { return "brain is running — try again after the turn" }
            await brain.submit("Create an AGENTS.md file in \(brain.cwd) describing how to work with this project: what it is, build/run commands, code conventions, and anything an AI agent should know. Inspect the folder first; keep it concise.")
            return "asked the agent to draft AGENTS.md in \(brain.cwd)"
        case "/diff":
            return await runGitDiff(brain: brain)
        case "/pwd":
            return brain.cwd
        case "/cd":
            guard !brain.isRunning else { return "brain is running — try again after the turn" }
            let path = (argument as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "not a directory: \(path)"
            }
            brain.cwd = path
            return "cwd → \(path)"
        case "/ps":
            return brain.execSessionsText
        case "/stop":
            return brain.stopExecSessions(id: argument.isEmpty ? nil : argument)
        case "/new", "/export", "/copy":
            return nil    // UI-owned: the chat window implements them
        default:
            return "unknown command \(command) — /help lists commands"
        }
    }

    /// /tasks — 并行任务状态一览（§8）：任务卡同源的派生 stage，加上人车道
    /// 队列深度；纯读，不驱动任何状态迁移。
    @MainActor
    static func tasksReport(_ tasks: BrainTaskScheduler) -> String {
        var lines: [String] = []
        if !tasks.pendingPerson.isEmpty {
            lines.append(String(format: L("person lane: %lld queued"), tasks.pendingPerson.count))
        }
        for task in tasks.tasks {
            let stage = tasks.stage(of: task)
            var line = "· [\(stageLabel(stage))] \(task.title)"
            if let tool = task.lastToolName, stage == .running || stage == .awaitingUser {
                line += " — \(tool)"
            }
            lines.append(line)
        }
        let recent = tasks.recentEnded.suffix(5)
        for task in recent {
            lines.append("· [\(task.outcome.rawValue)] \(task.title)")
        }
        return lines.isEmpty
            ? L("no parallel tasks")
            : lines.joined(separator: "\n")
    }

    private static func stageLabel(_ stage: BrainTask.Stage) -> String {
        switch stage {
        case .queued: "queued"
        case .running: "running"
        case .awaitingUser: "waiting-for-you"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    /// /diff — git diff (tracked + untracked status), run directly in the
    /// workspace sandbox, never as a model turn (codex /diff parity).
    static func runGitDiff(brain: BrainAgent) async -> String {
        let tracked = await BrainSandbox.run(
            command: "git diff HEAD --stat && git status --short",
            cwd: brain.cwd, mode: .workspaceWrite,
            workspaceRoot: brain.cwd, timeout: 20)
        let full = await BrainSandbox.run(
            command: "git diff HEAD",
            cwd: brain.cwd, mode: .workspaceWrite,
            workspaceRoot: brain.cwd, timeout: 20)
        guard !tracked.output.contains("not a git repository") else {
            return "not a git repository: \(brain.cwd)"
        }
        var text = tracked.output
        if full.output.count > 4000 {
            text += "\n\n" + String(full.output.prefix(4000)) + "\n… [diff truncated]"
        } else {
            text += "\n\n" + full.output
        }
        return text
    }
}
