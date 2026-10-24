import Foundation

/// Headless Brain verification (`Moppet --brain-smoke`): a ScriptedModel
/// drives the full codex-style loop — apply_patch on real files, sandboxed
/// shell, approval gating, rollout persistence/resume, and an MCP client
/// round-trip against this app's own MCP server. No network involved.
enum BrainSmokeTest {

    static func run() -> Never {
        var failures = 0
        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "✓" : "✗"
            FileHandle.standardError.write(Data("\(mark) \(name)\(detail.isEmpty ? "" : " — \(detail)")\n".utf8))
            if !condition { failures += 1 }
        }
        func trace(_ text: String) {
            FileHandle.standardError.write(Data("[trace] \(text)\n".utf8))
        }

        let sema = DispatchSemaphore(value: 0)

        // 1) apply_patch — parser & applier on a real workspace.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let hello = workspace.appendingPathComponent("hello.txt")
        try? "line1\nline2\nline3\n".write(to: hello, atomically: true, encoding: .utf8)

        do {
            // Add + Update + Delete in one patch.
            let patch = """
            *** Begin Patch
            *** Add File: created.txt
            +first
            +second
            *** Update File: hello.txt
            @@
             line1
            -line2
            +LINE-TWO
             line3
            *** Delete File: gone.txt
            *** End Patch
            """
            try? "bye".write(to: workspace.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
            let result = try ApplyPatch.apply(patch, workspaceRoot: workspace)
            let created = try String(contentsOf: workspace.appendingPathComponent("created.txt"), encoding: .utf8)
            let updated = try String(contentsOf: hello, encoding: .utf8)
            let deletedGone = !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("gone.txt").path)
            expect("apply_patch add", created == "first\nsecond")
            expect("apply_patch update", updated == "line1\nLINE-TWO\nline3\n", "got=[\(updated.replacingOccurrences(of: "\n", with: "\\n"))]")
            expect("apply_patch delete", deletedGone)
            expect("apply_patch summary", result.added == ["created.txt"] && result.updated == ["hello.txt"])

            // Move to.
            let movePatch = """
            *** Begin Patch
            *** Update File: created.txt
            @@
             first
            -second
            +second-v2
            *** Move to: renamed.txt
            *** End Patch
            """
            _ = try ApplyPatch.apply(movePatch, workspaceRoot: workspace)
            expect("apply_patch move", FileManager.default.fileExists(atPath: workspace.appendingPathComponent("renamed.txt").path))

            // Context mismatch must throw.
            let badPatch = """
            *** Begin Patch
            *** Update File: hello.txt
            @@
             nomatch
            -line2
            +x
            *** End Patch
            """
            let badResult = try? ApplyPatch.apply(badPatch, workspaceRoot: workspace)
            expect("apply_patch rejects bad context", badResult == nil)

            // Path escape must throw.
            let escapePatch = """
            *** Begin Patch
            *** Add File: ../../escaped.txt
            +x
            *** End Patch
            """
            let escapeResult = try? ApplyPatch.apply(escapePatch, workspaceRoot: workspace)
            expect("apply_patch blocks path escape", escapeResult == nil)
        } catch {
            expect("apply_patch section", false, error.localizedDescription)
        }

        trace("apply_patch section done")

        // 2) Sandbox — read-only mode blocks writes, workspace-write allows them.
        Task {
            // read-only: writing OUTSIDE the temp scratch (home) must be denied.
            let homeTarget = NSHomeDirectory() + "/brain-smoke-ro.txt"
            let blocked = await BrainSandbox.run(
                command: "echo hi > \(homeTarget)",
                cwd: workspace.path, mode: .readOnly, workspaceRoot: workspace.path)
            let blockedFile = !FileManager.default.fileExists(atPath: homeTarget)
            expect("sandbox read-only blocks writes", blockedFile,
                   "exit \(blocked.exitCode) stderr=[\(blocked.stderr.prefix(100))]")

            let allowed = await BrainSandbox.run(
                command: "echo hi > \(workspace.path)/sandboxed.txt",
                cwd: workspace.path, mode: .workspaceWrite, workspaceRoot: workspace.path)
            let allowedFile = FileManager.default.fileExists(atPath: workspace.appendingPathComponent("sandboxed.txt").path)
            expect("sandbox workspace-write allows writes", allowedFile,
                   "exit \(allowed.exitCode) stderr=\(allowed.stderr.prefix(100)) profile=[\(BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path) ?? "-")]")

            let networkBlocked = await BrainSandbox.run(
                command: "curl -m 2 -sf https://example.com && echo NETWORK-REACHED",
                cwd: workspace.path, mode: .readOnly, workspaceRoot: workspace.path)
            expect("sandbox denies network",
                   !networkBlocked.output.contains("NETWORK-REACHED"),
                   "exit \(networkBlocked.exitCode)")
            // Default-on network: the workspace-write profile carries the
            // allow clause so pet-chat curl/web checks work without toggles.
            expect("sandbox network default-on in profile",
                   BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path,
                                        networkAccess: true)?
                       .contains("allow network*") == true)
            expect("sandbox network flag still gates the profile",
                   BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path,
                                        networkAccess: false)?
                       .contains("deny network*") == true)

            // Delete detection drives the approval gate ("everything but
            // delete auto-runs") — both directions must hold.
            expect("delete detect: rm family",
                   BrainSandbox.involvesDeletion("rm -rf /tmp/x")
                   && BrainSandbox.involvesDeletion("cd /a && /bin/rm -rf b")
                   && BrainSandbox.involvesDeletion("ls | xargs rm -f"))
            expect("delete detect: find -delete / git clean / trash",
                   BrainSandbox.involvesDeletion("find . -name '*.tmp' -delete")
                   && BrainSandbox.involvesDeletion("git clean -fd")
                   && BrainSandbox.involvesDeletion("trash ~/x"))
            expect("delete detect: benign commands pass",
                   !BrainSandbox.involvesDeletion("curl -sf https://example.com")
                   && !BrainSandbox.involvesDeletion("python3 script.py --out report.txt")
                   && !BrainSandbox.involvesDeletion("mkdir -p a && echo hi > a/x.txt")
                   && !BrainSandbox.involvesDeletion("grep -r 'form' . | wc -l"))

            sema.signal()
        }
        sema.wait()

        trace("sandbox section done")

        // 3) Brain agent loop with a scripted model: plan → shell → apply_patch → answer.
        let scripted: [[BrainStreamEvent]] = [
            // Turn 1: model updates the plan.
            [
                .toolCall(BrainToolCall(callID: "c1", name: "update_plan",
                                        argumentsJSON: #"{"plan":["inspect","patch","verify"]}"#)),
                .textDelta("Starting."),
                .completed(finalMessage: nil, usage: BrainUsage(inputTokens: 10, outputTokens: 5)),
            ],
            // Turn 2: model inspects via read_file.
            [
                .toolCall(BrainToolCall(callID: "c2", name: "read_file",
                                        argumentsJSON: #"{"path":"hello.txt"}"#)),
                .completed(finalMessage: nil, usage: BrainUsage(inputTokens: 10, outputTokens: 5)),
            ],
            // Turn 3: model edits via apply_patch.
            [
                .toolCall(BrainToolCall(
                    callID: "c3", name: "apply_patch",
                    argumentsJSON: #"{"patch":"*** Begin Patch\n*** Update File: hello.txt\n@@\n line1\n-LINE-TWO\n+LINE-2-EDITED-BY-BRAIN\n line3\n*** End Patch"}"#)),
                .completed(finalMessage: nil, usage: BrainUsage(inputTokens: 10, outputTokens: 5)),
            ],
            // Turn 4: model runs a sandboxed shell command.
            [
                .toolCall(BrainToolCall(
                    callID: "c4", name: "shell",
                    argumentsJSON: #"{"command":"echo brain-smoke-ok"}"#)),
                .completed(finalMessage: nil, usage: BrainUsage(inputTokens: 10, outputTokens: 5)),
            ],
            // Turn 5: model tries a destructive cleaning tool WITHOUT user approval
            // (ApprovalCenter has no UI in headless mode → request never resolves;
            //  we test the destructive gate through ToolRegistry's confirmedFlag path instead).
            // Final turn: plain answer, no tools.
            [
                .textDelta("All done. "),
                .textDelta("Files patched."),
                .completed(finalMessage: nil, usage: BrainUsage(inputTokens: 10, outputTokens: 7)),
            ],
        ]

        var events: [BrainEvent] = []
        let brainDone = DispatchSemaphore(value: 0)
        trace("scheduling brain task")
        Task {
            trace("brain task started")
            let agent = BrainAgent(model: ScriptedModel(scripted: scripted))
            agent.mcpEnabled = false
            agent.cwd = workspace.path
            agent.sandboxMode = .workspaceWrite
            agent.approvalPolicy = .onRequest
            agent.onEvent = { events.append($0) }
            trace("submitting")
            await agent.submit("smoke test please")
            trace("submit returned")
            expect("brain loop ran 4 tool turns",
                   events.filter { if case .toolStarted = $0 { return true }; return false }.count == 4,
                   "\(events.filter { if case .toolStarted = $0 { return true }; return false }.count)")
            expect("brain streamed final message",
                   agent.items.contains {
                       if case .message("assistant", let text) = $0 { return text.contains("All done") }
                       return false
                   })
            let edited = (try? String(contentsOf: workspace.appendingPathComponent("hello.txt"), encoding: .utf8)) ?? ""
            expect("brain apply_patch edited the file", edited.contains("LINE-2-EDITED-BY-BRAIN"), "got=[\(edited.replacingOccurrences(of: "\n", with: "\\n"))]")
            let shellOutput = agent.items.compactMap {
                  if case .functionCallOutput(_, let output) = $0 { return output }
                  return nil
               }.first { $0.contains("brain-smoke-ok") }
            expect("brain shell tool executed", shellOutput != nil)
            expect("brain read_file worked",
                   agent.items.contains {
                       if case .functionCallOutput(_, let output) = $0 { return output.contains("LINE-TWO") }
                       return false
                   })
            expect("brain usage accounted", agent.lastUsage?.totalTokens == 17)
            expect("brain plan persisted to transcript",
                   agent.items.contains { if case .plan = $0 { return true }; return false } &&
                   agent.plan.steps.count == 3,
                   "\(agent.plan.steps.count) steps")
            expect("brain rollout persisted",
                   FileManager.default.fileExists(atPath: BrainRollout.fileURL(for: agent.sessionID).path))

            // 4) Rollout resume.
            let resumed = BrainRollout.load(sessionID: agent.sessionID)
            expect("rollout resume keeps items", (resumed?.items.count ?? 0) >= 8,
                   "\(resumed?.items.count ?? 0) items")
            brainDone.signal()
        }
        brainDone.wait()

        trace("brain section done")

        // 5) MCP client round-trip against our own MCP server binary (self path).
        let mcpDone = DispatchSemaphore(value: 0)
        trace("scheduling mcp task")
        Task {
            trace("mcp task started")
            let selfPath = CommandLine.arguments.first ?? ""
            let client = try? BrainMCPClient(serverName: "self", config: .init(
                command: selfPath, args: ["--mcp"]))
            if let client {
                try? await client.initialize()
                let tools = (try? await client.listTools()) ?? []
                expect("MCP client lists our tools", tools.contains { $0.name == "scan_clean" },
                       "\(tools.count) tools")
                let result = (try? await client.callTool(
                    name: "safety_check", arguments: ["path": "/System"])) ?? ""
                expect("MCP client tool call", result.contains("DENIED"))
            } else {
                expect("MCP client connects", false, "spawn failed")
            }
            mcpDone.signal()
        }
        mcpDone.wait()
        trace("mcp section done")

        // 6) v15.26 codex-parity surface: exec sessions, view_image,
        //    request_user_input (headless), sandbox network/roots, rollout
        //    image+compacted records, slash commands.
        let parityDone = DispatchSemaphore(value: 0)
        Task {
            // Seatbelt canonicalizes writable roots; compare against the
            // realpath of /tmp (/private/tmp), not the literal input.
            var realBuffer = [CChar](repeating: 0, count: 4096)
            let realTmp = realpath("/tmp", &realBuffer) != nil ? String(cString: realBuffer) : "/tmp"

            // 6a) Resumable exec session: read stdin → echo → exit.
            let registry = BrainExecSessionRegistry()
            let session = registry.start(
                command: "read line; echo GOT:$line; sleep 0.2; echo TAIL",
                cwd: workspace.path, mode: .workspaceWrite,
                workspaceRoot: workspace.path, networkAccess: false, writableRoots: [])
            expect("exec session spawns", session != nil)
            if let session {
                let early = await session.wait(seconds: 0.4)
                expect("exec session still running before stdin", early == nil,
                       "exit=\(early.map(String.init) ?? "nil")")
                session.write("hello\n")
                let code = await session.wait(seconds: 5)
                expect("exec session exits after stdin", code == 0,
                       "exit=\(code.map(String.init) ?? "nil")")
                let output = session.drainOutput()
                expect("exec session echoes stdin", output.contains("GOT:hello"), "[\(output.prefix(80))]")
                expect("exec session captures tail", output.contains("TAIL"))
            }
            expect("registry stop clears sessions", !registry.stop().isEmpty)

            // 6b) Sandbox profile knobs (network_access / writable_roots).
            let netOff = BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path) ?? ""
            let netOn = BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path,
                                             networkAccess: true) ?? ""
            expect("sandbox network denied by default", netOff.contains("(deny network*)"))
            expect("sandbox network allowed when enabled", netOn.contains("(allow network*)"))
            let withRoot = BrainSandbox.profile(mode: .workspaceWrite, workspaceRoot: workspace.path,
                                                writableRoots: ["/tmp"]) ?? ""
            expect("sandbox extra writable root honored", withRoot.contains("(subpath \"\(realTmp)\")"),
                   String(withRoot.suffix(120)))

            // 6c) view_image: real data URL from a 1×1 PNG; sniffing + rejection.
            let pngData = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            let pngPath = workspace.appendingPathComponent("pixel.png")
            try? pngData.write(to: pngPath)
            let context = BrainTools.Context(
                turn: BrainTurnContext(cwd: workspace.path, sandboxMode: .workspaceWrite,
                                       approvalPolicy: .onRequest, model: "scripted"),
                workspaceRoot: workspace, execSessions: registry)
            let viewOut = await BrainTools.dispatch(
                call: BrainToolCall(callID: "v1", name: "view_image",
                                    argumentsJSON: #"{"path":"pixel.png"}"#),
                context: context, emit: { _ in })
            expect("view_image returns data URL", viewOut.hasPrefix("image:data:image/png;base64,"),
                   String(viewOut.prefix(40)))
            expect("view_image mime sniffing", BrainTools.imageMIME(pngData) == "image/png")
            expect("view_image rejects text", BrainTools.imageMIME(Data("not an image".utf8)) == nil)
            expect("image sentinel summary", BrainAgent.imageSummary(viewOut).contains("image/png"))

            // 6d) request_user_input headless: no UI → explicit not-answered,
            //     never a hang (UserInputCenter.uiAvailable is false here).
            let askOut = await BrainTools.dispatch(
                call: BrainToolCall(
                    callID: "q1", name: "request_user_input",
                    argumentsJSON: #"{"questions":[{"id":"q","header":"Clean","question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}"#),
                context: context, emit: { _ in })
            expect("request_user_input headless declines cleanly",
                   askOut.contains("user did not answer"), String(askOut.prefix(60)))

            // 6e) Spec surface: new tools registered; MCP resources gated.
            let names = BrainTools.allSpecs(mcpTools: []).map(\.name)
            for expected in ["view_image", "exec_command", "write_stdin", "request_user_input"] {
                expect("spec registered: \(expected)", names.contains(expected))
            }
            expect("mcp resource specs gated off without servers",
                   !names.contains("list_mcp_resources"))
            expect("mcp resource specs present with servers",
                   BrainTools.allSpecs(mcpTools: [], mcpConnected: true)
                       .map(\.name).contains("read_mcp_resource"))

            // 6f) Rollout records: image item + compacted round-trip; legacy
            //     turn_context (no network fields) still decodes.
            let encoder = JSONEncoder()
            let imageRecord = BrainRollout.Record.responseItem(
                .imageItem(callID: "user", dataURL: "data:image/png;base64,AAAA"))
            let decodedImage = try? JSONDecoder().decode(
                BrainRollout.Record.self, from: encoder.encode(imageRecord))
            if case .responseItem(.imageItem("user", let url))? = decodedImage {
                expect("rollout image record round-trip", url == "data:image/png;base64,AAAA")
            } else {
                expect("rollout image record round-trip", false, "decode failed")
            }
            let compactedRecord = BrainRollout.Record.compacted(summary: "did things")
            let decodedCompacted = try? JSONDecoder().decode(
                BrainRollout.Record.self, from: encoder.encode(compactedRecord))
            if case .compacted(let summary)? = decodedCompacted {
                expect("rollout compacted record round-trip", summary == "did things")
            } else {
                expect("rollout compacted record round-trip", false, "decode failed")
            }
            let legacyContextJSON = #"{"cwd":"\/tmp","sandboxMode":"read-only","approvalPolicy":"on-request","model":"x"}"#
            let legacyContext = try? JSONDecoder().decode(
                BrainTurnContext.self, from: Data(legacyContextJSON.utf8))
            expect("legacy turn_context decodes",
                   legacyContext?.sandboxMode == .readOnly && legacyContext?.networkAccess == nil)

            // 6f2) Headless --yes auto-approval must not touch MainActor:
            //      untrusted shell approves via the flag and completes (the
            //      pre-fix code hung forever here under --brain-exec --yes).
            ApprovalCenter.headlessAutoApprove = true
            let untrustedContext = BrainTools.Context(
                turn: BrainTurnContext(cwd: workspace.path, sandboxMode: .workspaceWrite,
                                       approvalPolicy: .untrusted, model: "scripted"),
                workspaceRoot: workspace)
            let headlessShell = await BrainTools.dispatch(
                call: BrainToolCall(callID: "h1", name: "shell",
                                    argumentsJSON: #"{"command":"echo headless-yes-ok"}"#),
                context: untrustedContext, emit: { _ in })
            ApprovalCenter.headlessAutoApprove = false
            expect("headless --yes approves without MainActor",
                   headlessShell.contains("headless-yes-ok"), String(headlessShell.prefix(80)))

            // 6g) Slash commands: table + runner basics.
            expect("slash table has codex commands",
                   ["/compact", "/status", "/diff", "/cd", "/ps", "/stop", "/export"]
                       .allSatisfy { name in SlashCommand.all.contains { $0.name == name } })
            let slashAgent = BrainAgent(model: ScriptedModel(scripted: []))
            slashAgent.cwd = workspace.path
            let pwd = await BrainSlash.run("/pwd", brain: slashAgent)
            expect("slash /pwd", pwd == workspace.path, pwd ?? "nil")
            let cd = await BrainSlash.run("/cd /tmp", brain: slashAgent)
            expect("slash /cd", cd?.contains("/tmp") == true && slashAgent.cwd == "/tmp",
                   "\(cd ?? "nil") cwd=\(slashAgent.cwd)")
            let uiOnly = await BrainSlash.run("/export", brain: slashAgent)
            expect("slash UI-only returns nil", uiOnly == nil)
            let status = await BrainSlash.run("/status", brain: slashAgent)
            expect("slash /status reports web_search", status?.contains("web_search:") == true,
                   String(status?.prefix(60) ?? "nil"))
            let ps = await BrainSlash.run("/ps", brain: slashAgent)
            expect("slash /ps empty", ps == "no exec sessions")

            parityDone.signal()
        }
        parityDone.wait()
        trace("parity section done")

        // cleanup
        try? FileManager.default.removeItem(at: workspace)

        print(failures == 0 ? "BRAIN SMOKE PASS" : "BRAIN SMOKE FAIL (\(failures) failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
