import Foundation

/// macOS Seatbelt sandbox executor — Swift port of codex's
/// `sandboxing/src/seatbelt.rs` approach: generate a `(version 1)` profile
/// per sandbox mode and run the command under `/usr/bin/sandbox-exec`.
///
/// - read-only:        deny all writes + deny network
/// - workspace-write:  writes allowed only inside the workspace root (+ tmp)
/// - danger-full-access: no sandboxing at all
/// POSIX realpath — Seatbelt subpath matching operates on fully resolved
/// paths, and firmlinked roots (/var, /tmp) must be canonicalized.
private func realFileSystemPath(_ path: String) -> String {
    path.withCString { cPath -> String in
        guard let resolved = realpath(cPath, nil) else { return path }
        let result = String(cString: resolved)
        free(resolved)
        return result
    }
}

enum BrainSandbox {

    struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let durationMS: Int
        /// Sandboxed runs that violate the policy exit with a sandbox violation.
        var sandboxViolation: Bool { exitCode == 125 }
        var output: String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty && err.isEmpty { return "(no output)" }
            if err.isEmpty { return out }
            if out.isEmpty { return err }
            return out + "\n" + err
        }
        var formatted: String {
            "exit: \(exitCode)\n\(output)"
        }
    }

    // MARK: - Profile generation

    static func profile(mode: BrainSandboxMode, workspaceRoot: String,
                        networkAccess: Bool = false,
                        writableRoots: [String] = []) -> String? {
        switch mode {
        case .dangerFullAccess:
            return nil
        case .readOnly:
            // Read-only means read-only: a temp-write allowance let sandboxed
            // commands drop executables into /var/folders and run them.
            return baseProfile(writablePaths: [], networkAccess: false)
        case .workspaceWrite:
            // codex sandbox_workspace_write: the workspace root plus any
            // user-added writable roots; network off unless explicitly enabled.
            var paths = [workspaceRoot] + writableRoots
            paths.append(NSTemporaryDirectory())
            return baseProfile(writablePaths: paths, networkAccess: networkAccess)
        }
    }

    /// A workable condensed profile in the spirit of codex's
    /// seatbelt_base_policy + filesystem policies: full read, constrained
    /// writes, process lifecycle allowed, network denied.
    private static func baseProfile(writablePaths: [String], networkAccess: Bool) -> String {
        // Seatbelt matches subpaths against resolved paths — canonicalize
        // symlinked roots (/tmp → /private/tmp, /var → /private/var), exactly
        // why codex canonicalizes its writable roots.

        var lines: [String] = [
            "(version 1)",
            "(allow process-exec)",
            "(allow process-fork)",
            "(allow process-info* (target same-sandbox))",
            "(allow file-read*)",
            "(allow file-read-metadata)",
            "(allow sysctl-read)",
            "(allow file-ioctl (literal \"/dev/ptmx\"))",
        ]
        if networkAccess {
            lines.append("(allow network*)")
        } else {
            // Network is denied in both sandboxed modes (codex network_policy).
            lines.append("(deny network*)")
        }
        for path in writablePaths {
            // realpath() also resolves firmlinks (/var → /private/var) that
            // URL.resolvingSymlinksInPath leaves untouched.
            let resolved = realFileSystemPath(path)
            // Control characters in a path would terminate the profile string
            // early → sandbox-exec fails → the caller auto-escalates
            // unsandboxed. Skip such roots instead.
            guard !resolved.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\0" || $0 == "\r" }) else {
                continue
            }
            let escaped = resolved.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("(allow file-write* (subpath \"\(escaped)\"))")
            lines.append("(allow file-read* (subpath \"\(escaped)\"))")
        }
        // Seatbelt is default-deny: writes outside the allowed subpaths need no
        // explicit (deny file-write*) — adding one would override the allows.
        return lines.joined(separator: "\n")
    }

    // MARK: - Execution

    /// Builds the Process for a command under the given sandbox mode — shared
    /// by the one-shot `run` and the resumable exec-session registry.
    static func makeProcess(command: String, cwd: String, mode: BrainSandboxMode,
                             workspaceRoot: String, networkAccess: Bool = false,
                             writableRoots: [String] = []) -> Process {
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())

        // Sandboxed commands run through /bin/sh: zsh's output redirection is
        // rejected by Seatbelt even when the target subpath is allowed.
        // Profiles are passed inline with -p (see note in profile()).
        if let profile = profile(mode: mode, workspaceRoot: workspaceRoot,
                                 networkAccess: networkAccess, writableRoots: writableRoots) {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            proc.arguments = ["-p", profile, "/bin/sh", "-c", command]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", command]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SANDBOX"] = mode.rawValue
        proc.environment = environment
        return proc
    }

    /// Runs a shell command under the sandbox mode.
    /// Mirrors codex's shell tool: /bin/zsh (login-style) with a hard timeout.
    static func run(command: String,
                    cwd: String,
                    mode: BrainSandboxMode,
                    workspaceRoot: String,
                    networkAccess: Bool = false,
                    writableRoots: [String] = [],
                    timeout: TimeInterval = 120) async -> CommandResult {
        let start = Date()
        // A missing workdir used to fall back to HOME silently — the model
        // believed it was in the project while the command ran in the home
        // directory. Fail loudly instead (125 = sandbox/launcher refusal).
        guard FileManager.default.fileExists(atPath: cwd) else {
            return CommandResult(stdout: "", stderr: "workdir does not exist: \(cwd)",
                                 exitCode: 125, durationMS: 0)
        }

        let proc = makeProcess(command: command, cwd: cwd, mode: mode,
                               workspaceRoot: workspaceRoot,
                               networkAccess: networkAccess, writableRoots: writableRoots)
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return CommandResult(stdout: "", stderr: "failed to spawn: \(error.localizedDescription)",
                                  exitCode: 127, durationMS: 0)
        }

        // Drain pipes concurrently: reading only AFTER termination deadlocks
        // on any command whose output exceeds the ~64KB pipe buffer (the
        // child blocks on write, never exits, and only the timeout kills it).
        let outReader = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errReader = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        // Timeout enforcement (lock-guarded flag: written by the global-queue
        // timer / cancel handler, read after the continuation resumes).
        final class TimedOutFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let timedOut = TimedOutFlag()
        let timer = DispatchWorkItem {
            if proc.isRunning {
                timedOut.set()
                proc.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                proc.terminationHandler = { _ in
                    timer.cancel()
                    continuation.resume()
                }
            }
        } onCancel: {
            // Turn cancellation must not leave the child running (it keeps
            // writing files / the network after the user pressed Stop).
            timedOut.set()
            timer.cancel()
            if proc.isRunning { proc.terminate() }
        }

        let stdout = String(data: await outReader.value, encoding: .utf8) ?? ""
        let stderr = String(data: await errReader.value, encoding: .utf8) ?? ""
        let duration = Int(Date().timeIntervalSince(start) * 1000)

        if timedOut.get() {
            return CommandResult(stdout: stdout, stderr: "command timed out after \(Int(timeout))s",
                                 exitCode: 124, durationMS: duration)
        }
        return CommandResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus,
                             durationMS: duration)
    }

    /// Escalation path (codex "escalate to full access"): re-run without
    /// sandbox after the user approves.
    static func runUnsandboxed(command: String, cwd: String,
                               timeout: TimeInterval = 120) async -> CommandResult {
        await run(command: command, cwd: cwd, mode: .dangerFullAccess,
                  workspaceRoot: cwd, timeout: timeout)
    }

    // MARK: - Delete detection

    /// Heuristic: does this command line DELETE things? Gates the shell tool's
    /// approval flow ("everything but delete runs without asking"): rm-family
    /// commands at any pipeline-segment start, `find … -delete`, `xargs rm`,
    /// `git clean`. Token-based, path-prefixed forms (`/bin/rm`) included,
    /// sudo/env wrappers skipped. False negatives are possible for exotic
    /// shells/aliases; false positives err on the safe side (they just ask).
    static func involvesDeletion(_ command: String) -> Bool {
        let deleteCommands: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "trash"]
        let wrappers: Set<String> = ["sudo", "env", "nohup", "command", "time", "nice"]
        let segments = command
            .replacingOccurrences(of: "&&", with: ";")
            .replacingOccurrences(of: "||", with: ";")
            .replacingOccurrences(of: "|", with: ";")
            .replacingOccurrences(of: "\n", with: ";")
            .split(separator: ";")
        for segment in segments {
            var words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0.split(separator: "/").last ?? $0) }
            // Skip leading wrappers (sudo rm …, env rm …).
            while let first = words.first, wrappers.contains(first) { words.removeFirst() }
            guard let head = words.first else { continue }
            if deleteCommands.contains(head) { return true }
            // `git … clean` at any subcommand position (git -C path clean -fd).
            if head == "git", words.dropFirst().contains("clean") { return true }
            if head == "find" {
                if words.contains("-delete") { return true }
                // find … -exec rm {} \; / -execdir rm — the classic miss.
                for (i, w) in words.enumerated() where w == "-exec" || w == "-execdir" {
                    if i + 1 < words.count, deleteCommands.contains(words[i + 1]) { return true }
                }
            }
            if head == "xargs", words.dropFirst().contains(where: { deleteCommands.contains($0) }) {
                return true
            }
            // `sh -c '…'` payloads are commands of their own — recurse.
            if ["sh", "bash", "zsh"].contains(head),
               let cIndex = words.firstIndex(of: "-c"), cIndex > 0,
               cIndex + 1 < words.count {
                if involvesDeletion(words[(cIndex + 1)...].joined(separator: " ")) { return true }
            }
        }
        // Command substitutions run their inner command: `echo $(rm -rf x)`,
        // `touch \`rm x\``. Turn the delimiters into separators and re-check.
        if command.contains("$(") || command.contains("`") {
            let inner = command
                .replacingOccurrences(of: "$(", with: ";")
                .replacingOccurrences(of: "`", with: ";")
                .replacingOccurrences(of: ")", with: ";")
            if inner != command, involvesDeletion(inner) { return true }
        }
        return false
    }
}

