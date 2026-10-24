import Foundation

/// Resumable exec sessions — Swift port of codex `unified_exec`
/// (`exec_command` + `write_stdin`): start a command, yield after a grace
/// period while it keeps running, then poll or feed stdin by session id.
/// Unlike codex there is no PTY (this is a chat-UI agent, not a terminal):
/// stdout and stderr are interleaved into one buffer, and `chars` written
/// via write_stdin go to the process stdin verbatim (send "\n" for Enter).
///
/// Mutable state is confined behind a single lock; the process output
/// handlers only append under it.
final class BrainExecSession: @unchecked Sendable {

    struct Snapshot: Equatable {
        let id: String
        let command: String
        let running: Bool
        let exitCode: Int32?
        /// Total output bytes produced so far (across reads).
        let totalBytes: Int
    }

    let id: String
    let command: String
    private let process: Process
    private let stdinHandle: FileHandle
    private let lock = NSLock()
    private var pendingOutput = ""
    private var totalBytes = 0
    /// Soft cap on retained-but-unread output — a chatty process must not
    /// grow the buffer without bound between polls.
    private static let bufferCap = 1 << 20

    /// Buffered-UTF8 safety: stdout arrives in arbitrary byte chunks; hold
    /// back trailing partial sequences so multi-byte characters never split.
    private var carry = Data()

    init?(id: String, command: String, cwd: String, mode: BrainSandboxMode,
          workspaceRoot: String, networkAccess: Bool, writableRoots: [String]) {
        self.id = id
        self.command = command
        process = BrainSandbox.makeProcess(
            command: command, cwd: cwd, mode: mode, workspaceRoot: workspaceRoot,
            networkAccess: networkAccess, writableRoots: writableRoots)
        let stdinPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outPipe
        process.standardError = outPipe   // merged stream (no PTY)
        stdinHandle = stdinPipe.fileHandleForWriting
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
        do {
            try process.run()
        } catch {
            return nil
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        var data = carry + chunk
        carry = Data()
        // Hold back at most a 3-byte trailing partial UTF-8 sequence. If the
        // data still doesn't decode, a genuinely invalid byte (binary output,
        // progress bars) sits in the middle — buffer it used to wedge the
        // stream forever (every later chunk re-failed); replace instead.
        var heldBack = 0
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil, heldBack < 3 {
            carry = Data(data.suffix(1)) + carry
            data = Data(data.dropLast(1))
            heldBack += 1
        }
        if String(data: data, encoding: .utf8) != nil {
            pendingOutput += String(data: data, encoding: .utf8) ?? ""
        } else {
            pendingOutput += String(decoding: data, as: UTF8.self)
            carry = Data()   // the held-back bytes were part of the junk run
        }
        totalBytes += chunk.count
        if pendingOutput.utf8.count > Self.bufferCap {
            pendingOutput = String(pendingOutput.suffix(Self.bufferCap))
        }
    }

    /// Waits up to `seconds` for the process to exit. Returns the exit code,
    /// or nil if it is still running. Cancellation-aware: a cancelled turn
    /// stops polling instead of spinning to the deadline.
    func wait(seconds: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { break }
            if let code = exitCodeNow() { return code }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return exitCodeNow()
    }

    private func exitCodeNow() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning ? nil : process.terminationStatus
    }

    /// Consumes and returns output produced since the last drain.
    func drainOutput() -> String {
        lock.lock()
        defer { lock.unlock() }
        let out = pendingOutput
        pendingOutput = ""
        return out
    }

    /// Writes `chars` to the process stdin (empty = poll only).
    func write(_ chars: String) {
        guard !chars.isEmpty else { return }
        lock.lock()
        let targetRunning = process.isRunning
        defer { lock.unlock() }
        // Writing to a dead child's stdin is a no-op (the process consumed
        // what it needed); the global SIGPIPE ignore covers any race where
        // it exits between the check and the write.
        guard targetRunning else { return }
        try? stdinHandle.write(contentsOf: Data(chars.utf8))
    }

    func terminate() {
        lock.lock()
        let running = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        guard running else { return }
        process.terminate()
        // SIGTERM-ignoring children must not outlive the session limit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(id: id, command: command,
                        running: process.isRunning,
                        exitCode: process.isRunning ? nil : process.terminationStatus,
                        totalBytes: totalBytes)
    }
}

/// Per-agent registry of live exec sessions — the counterpart of codex's
/// exec session map. Sessions survive across turns (background terminals),
/// die with the agent, and are listable/stoppable (/ps, /stop).
final class BrainExecSessionRegistry: @unchecked Sendable {

    private let lock = NSLock()
    private var sessions: [String: BrainExecSession] = [:]
    /// Hard lifetime cap per session, mirroring codex
    /// background_terminal_max_timeout (default 300s).
    static let maxLifetime: TimeInterval = 300

    @discardableResult
    func start(command: String, cwd: String, mode: BrainSandboxMode,
               workspaceRoot: String, networkAccess: Bool,
               writableRoots: [String]) -> BrainExecSession? {
        let id = UUID().uuidString.prefix(8).lowercased().description
        guard let session = BrainExecSession(
            id: id, command: command, cwd: cwd, mode: mode,
            workspaceRoot: workspaceRoot, networkAccess: networkAccess,
            writableRoots: writableRoots) else { return nil }
        lock.lock()
        sessions[id] = session
        lock.unlock()
        // Lifetime cap: reap quietly when the budget runs out.
        Task.detached { [weak session] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxLifetime * 1_000_000_000))
            session?.terminate()
        }
        return session
    }

    func session(id: String) -> BrainExecSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func list() -> [BrainExecSession.Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.map(\.snapshot).sorted { $0.id < $1.id }
    }

    /// Stops sessions by id, or every running one when id is nil.
    /// Returns the ids actually terminated.
    @discardableResult
    func stop(id: String? = nil) -> [String] {
        lock.lock()
        let targets = id.map { [$0] } ?? sessions.keys.sorted()
        let stopped = sessions.filter { targets.contains($0.key) }.map(\.value)
        lock.unlock()
        stopped.forEach { $0.terminate() }
        return stopped.map(\.id)
    }

    func stopAll() {
        stop(id: nil)
    }
}
