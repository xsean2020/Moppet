import Foundation

/// `Moppet --brain-exec "<prompt>"` — the codex `exec` parity: run one agent
/// turn headlessly (stdout transcript, no UI), print the final answer, exit
/// with the agent's success. Destructive tools still require approval, which
/// without a UI is denied by default — pass `--yes` to auto-approve.
enum BrainExec {
    static func run(prompt: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let autoApprove = CommandLine.arguments.contains("--yes")
        let settings = AISettings.load()
        guard settings.isConfigured else {
            FileHandle.standardError.write(Data("error: AI provider not configured\n".utf8))
            exit(2)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let agent = BrainAgent(model: SDKChatModel(settings: settings))
            agent.mcpEnabled = true
            agent.cwd = FileManager.default.currentDirectoryPath

            if autoApprove {
                // Headless auto-approval: the old MainActor polling task could
                // never run (the main thread is blocked below on the
                // semaphore) — the flag is checked inside the tool path
                // before any actor hop, so destructive tools proceed instead
                // of deadlocking.
                ApprovalCenter.headlessAutoApprove = true
            } else {
                // Same blocking-main-thread problem in reverse: an approval
                // request without --yes used to await a MainActor dialog that
                // could never run — declining inline is the honest behavior.
                ApprovalCenter.headlessDeny = true
            }

            agent.onEvent = { event in
                switch event {
                case .toolStarted(let name, _):
                    print("→ \(name)")
                case .toolFinished(let name, _, let output, let isError):
                    let mark = isError ? " (failed)" : ""
                    print("← \(name)\(mark): \(output.prefix(160))")
                case .approvalRequested(let name, _):
                    if !autoApprove {
                        print("⚠ approval required for \(name) — rerun with --yes (headless denies by default)")
                    }
                default:
                    break
                }
            }

            await agent.submit(prompt)

            if let final = agent.items.last(where: { item in
                if case .message("assistant", _) = item { return true }
                return false
            }), case .message(_, let text) = final {
                print("\n" + text)
            } else if let error = agent.lastError {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                semaphore.signal()
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
