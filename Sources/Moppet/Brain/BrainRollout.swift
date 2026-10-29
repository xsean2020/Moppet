import Foundation

/// Session persistence — Swift port of codex's `rollout` crate: one JSONL
/// file per session under `~/.moppet/brain/sessions/`, starting with a
/// `session_meta` line, then `turn_context` and `response_item` records,
/// so sessions can be resumed exactly like `codex resume`.
enum BrainRollout {

    struct SessionMeta: Codable {
        let id: String
        let timestamp: Date
        let cwd: String
        let originator: String
        let cliVersion: String
        let instructions: String?
        /// Which harness produced this session (`HarnessStore.fingerprint`).
        /// Optional so pre-P2 rollouts still decode.
        var harnessFingerprint: String?
    }

    enum Record: Codable {
        case sessionMeta(SessionMeta)
        case turnContext(BrainTurnContext)
        case responseItem(BrainResponseItem)
        /// codex CompactedItem — written by /compact; on resume the summary
        /// re-enters the transcript as a user-context message.
        case compacted(summary: String)
        /// One turn's signals + verdict inputs (design doc §5.6 / §5.12).
        case turnOutcome(TurnOutcome)
        /// A user decision on an approval request (§5.12, G2).
        case approvalEvent(ApprovalEvent)

        private enum CodingKeys: String, CodingKey { case type, payload, summary }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "session_meta":
                self = .sessionMeta(try c.decode(SessionMeta.self, forKey: .payload))
            case "turn_context":
                self = .turnContext(try c.decode(BrainTurnContext.self, forKey: .payload))
            case "response_item":
                self = .responseItem(try c.decode(BrainResponseItem.self, forKey: .payload))
            case "compacted":
                self = .compacted(summary: try c.decode(String.self, forKey: .summary))
            case "turn_outcome":
                self = .turnOutcome(try c.decode(TurnOutcome.self, forKey: .payload))
            case "approval_event":
                self = .approvalEvent(try c.decode(ApprovalEvent.self, forKey: .payload))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown record")
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .sessionMeta(let meta):
                try c.encode("session_meta", forKey: .type)
                try c.encode(meta, forKey: .payload)
            case .turnContext(let context):
                try c.encode("turn_context", forKey: .type)
                try c.encode(context, forKey: .payload)
            case .responseItem(let item):
                try c.encode("response_item", forKey: .type)
                try c.encode(item, forKey: .payload)
            case .compacted(let summary):
                try c.encode("compacted", forKey: .type)
                try c.encode(summary, forKey: .summary)
            case .turnOutcome(let outcome):
                try c.encode("turn_outcome", forKey: .type)
                try c.encode(outcome, forKey: .payload)
            case .approvalEvent(let event):
                try c.encode("approval_event", forKey: .type)
                try c.encode(event, forKey: .payload)
            }
        }
    }

    /// Test seam: point rollouts at a temp directory so smoke runs can build
    /// synthetic sessions (divergence detection and the shadow prober both
    /// read real transcripts) without touching the user's history.
    static var rootOverride: URL?

    static var directory: URL {
        if let rootOverride {
            try? FileManager.default.createDirectory(at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/sessions")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fileURL(for sessionID: String) -> URL {
        directory.appendingPathComponent("\(sessionID).jsonl")
    }

    // MARK: - Writer

    final class Writer {
        let sessionID: String
        private let url: URL
        private let encoder: JSONEncoder
        private let appendLock = NSLock()

        init(meta: SessionMeta) {
            sessionID = meta.id
            url = fileURL(for: meta.id)
            encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if !FileManager.default.fileExists(atPath: url.path) {
                append(.sessionMeta(meta))
            }
        }

        func append(_ record: Record) {
            guard let data = try? encoder.encode(record) else { return }
            var line = String(data: data, encoding: .utf8) ?? ""
            line += "\n"
            // Serialized: parallel tool tasks (update_plan) and /compact can
            // append concurrently — unsynchronized seek+write interleaves and
            // tears JSONL lines.
            appendLock.lock()
            defer { appendLock.unlock() }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else if !FileManager.default.fileExists(atPath: url.path) {
                // Only ever CREATE here — the old fallback replaced the whole
                // file with this one line, wiping the session when the handle
                // briefly failed on an existing file.
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        func append(item: BrainResponseItem) { append(.responseItem(item)) }
        func append(context: BrainTurnContext) { append(.turnContext(context)) }
    }

    // MARK: - Reader / resume

    struct Session {
        let meta: SessionMeta
        var lastTurnContext: BrainTurnContext?
        var items: [BrainResponseItem]
    }

    static func load(sessionID: String) -> Session? {
        readRecords(at: fileURL(for: sessionID)).flatMap { records -> Session? in
            guard case .sessionMeta(let meta) = records.first else { return nil }
            var context: BrainTurnContext?
            var items: [BrainResponseItem] = []
            for record in records.dropFirst() {
                switch record {
                case .turnContext(let c): context = c
                case .responseItem(let item): items.append(item)
                case .sessionMeta: break
                case .turnOutcome, .approvalEvent: break   // signals, not transcript
                case .compacted(let summary):
                    // Everything compressible BEFORE this record is gone by
                    // definition — resuming must not resurrect it (the old
                    // replay restored the full history AND the summary).
                    items = [.message(
                        role: "user",
                        content: "[compacted summary of earlier turns]\n\(summary)")]
                }
            }
            return Session(meta: meta, lastTurnContext: context, items: items)
        }
    }

    /// Lightweight session enumeration: reads only the head of each file and
    /// counts markers by string search — never decodes full response items.
    /// (Full decode of every rollout made the dashboard/chat sidebar crawl.)
    /// Zero-message sessions (a "+" click that was never used) are excluded
    /// from the list AND the total — they'd bury real conversations and make
    /// the sidebar count read as "delete doesn't work".
    static func listSessions(limit: Int = 30)
        -> (sessions: [(id: String, date: Date, itemCount: Int)], total: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [(String, Date, Int)] = []
        for url in files where url.pathExtension == "jsonl" {
            let id = url.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard let firstLine = text.split(separator: "\n").first,
                  let meta = try? decoder.decode(Record.self, from: Data(firstLine.utf8)),
                  case .sessionMeta(let m) = meta else { continue }
            let itemCount = text.components(separatedBy: "\"type\":\"response_item\"").count - 1
            guard itemCount > 0 else { continue }
            results.append((id, m.timestamp, itemCount))
        }
        let sorted = results.sorted { $0.1 > $1.1 }
        return (Array(sorted.prefix(limit)), sorted.count)
    }

    /// Fast title: stream head lines until the first user message. Real JSON
    /// decode per line — raw string surgery broke on escaped quotes and
    /// matched same-shaped text inside assistant messages.
    static func titleForSession(sessionID: String) -> String? {
        guard let text = try? String(contentsOf: fileURL(for: sessionID), encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n").prefix(400) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            let item = (obj["item"] as? [String: Any]) ?? obj
            guard (item["role"] as? String) == "user",
                  let content = item["content"] as? String, !content.isEmpty else { continue }
            let title = content.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return String(title.prefix(48))
        }
        return nil
    }

    /// Every record with its 1-based line number. **The line number is the
    /// canonical coordinate for evidence citations** (design doc §5.12, I2):
    /// `compacted` rewrites the in-memory item list, but lines never move.
    static func records(sessionID: String) -> [(line: Int, record: Record)] {
        guard let text = try? String(contentsOf: fileURL(for: sessionID), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [(Int, Record)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else { continue }
            out.append((index + 1, record))
        }
        return out
    }

    private static func readRecords(at url: URL) -> [Record]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [Record] = []
        for line in text.split(separator: "\n") {
            guard !line.isEmpty else { continue }
            // Skip undecodable lines (torn mid-write line, unknown record
            // type from a newer build) — `break`ing here used to truncate
            // everything after the first bad line on resume.
            guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)) else { continue }
            records.append(record)
        }
        return records
    }
}

/// AGENTS.md discovery & instructions assembly — port of codex
/// `core/agents_md.rs`: collect AGENTS.md from ~/.moppet (user), then walk
/// from filesystem root down through every ancestor of cwd to cwd itself,
/// concatenated root→leaf order.
enum BrainInstructions {

    static let brainHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".moppet")

    /// System prompt = user persona (soul) first, then the harness tree
    /// (`~/.moppet/brain/harness/`), with the environment block injected at
    /// runtime. P0: the tree is seeded from `legacySystemPrompt`, so this is a
    /// no-op until the user edits a file — the acceptance test asserts exactly
    /// that (design doc §9, P0).
    static func systemPrompt(cwd: String, sandboxMode: BrainSandboxMode,
                             approvalPolicy: BrainApprovalPolicy,
                             networkAccess: Bool = false) -> String {
        HarnessStore.composeSystemPrompt(
            cwd: cwd, sandboxMode: sandboxMode,
            approvalPolicy: approvalPolicy, networkAccess: networkAccess)
    }

    /// The pre-harness implementation, kept verbatim as the last fallback in the
    /// degradation chain and as the reference the P0 byte-diff test compares to.
    /// Do not edit: `PetHarness.seed` is the editable copy now.
    static func legacySystemPrompt(cwd: String, sandboxMode: BrainSandboxMode,
                                   approvalPolicy: BrainApprovalPolicy,
                                   networkAccess: Bool = false) -> String {
        let name = PetIdentity.name
        var prompt = ""
        if let persona = PetIdentity.persona {
            prompt += "# Persona (user-defined soul)\n\(persona)\n\n"
        }
        prompt += """
        You are \(name) — a desktop pet with a coding & system agent brain built \
        after OpenAI Codex, living inside a macOS desktop-cleaning app. You can run \
        shell commands (one-shot or resumable exec sessions), read and edit files \
        with apply_patch, view images, make plans, ask the user structured \
        questions, call the app's built-in cleaning/analysis tools, and use \
        connected MCP servers.

        Environment:
        - cwd: \(cwd)
        - sandbox: \(sandboxMode.rawValue)\(sandboxMode == .workspaceWrite ? " (network \(networkAccess ? "allowed" : "denied"))" : "")
        - approval policy: \(approvalPolicy.rawValue)

        Operating rules:
        1. Inspect before you act: read files / run read-only commands first.
        2. Use apply_patch for file edits — never shell heredocs for writing files.
        3. Network is available (curl, web checks) and non-delete shell \
        commands run freely: if one fails on a sandbox violation it is \
        auto-escalated and rerun without the sandbox — no user prompt needed.
        4. Deleting (rm family, find -delete, git clean, trash) ALWAYS asks \
        the user first — never try to work around that with other commands.
        5. For cleaning tasks prefer the built-in tools (scan_clean first, show \
        results, then execute_clean after the user approves).
        6. scan_clean MUST honor the user's scope: if they name a category, \
        app or vendor (e.g. "only browser"), pass sections/items accordingly \
        and never omit both arguments — omitting means a FULL sweep. Report \
        the scanned scope back to the user.
        7. Long-running commands: use exec_command (resumable) and poll with \
        write_stdin instead of blocking the turn with huge timeouts.
        7. request_user_input is for genuine decisions only — never quiz the \
        user about things you can determine yourself.
        8. Keep responses concise. Answer in the user's language. Stay in character.
        """
        return prompt
    }

    static func discoverAgentsMD(cwd: String) -> [String] {
        var found: [(path: String, content: String)] = []

        // 1. User-level (~/.moppet/AGENTS.md), like ~/.codex/AGENTS.md.
        let userFile = brainHome.appendingPathComponent("AGENTS.md")
        if let text = try? String(contentsOf: userFile, encoding: .utf8) {
            found.append((userFile.path, text))
        }

        // 2. Ancestors root→cwd (codex scans from root downward to cwd).
        var ancestors: [String] = []
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            ancestors.append(dir.path)
            if dir.path == "/" { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        for path in ancestors.reversed() {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("AGENTS.md")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                found.append((candidate.path, text))
            }
        }
        return found.map { "<agent-instructions path=\"\($0.path)\">\n\($0.content)\n</agent-instructions>" }
    }

    static func assembleDeveloperMessage(cwd: String) -> String {
        let blocks = discoverAgentsMD(cwd: cwd)
        if blocks.isEmpty {
            return "No AGENTS.md files found."
        }
        return "Project instructions discovered:\n\n" + blocks.joined(separator: "\n\n")
    }
}
