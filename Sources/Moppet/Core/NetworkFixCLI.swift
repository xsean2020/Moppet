import Foundation
import Darwin

/// `--net-fix`: the headless entry to `NetworkOptimizer` — the write half of
/// the network module. `--net-probe` measures and explains; this one changes
/// configuration, and therefore carries the heavy guardrails:
///
/// - **Plan before power.** Every invocation first renders the exact commands
///   and their inverse. Without `--yes` nothing is applied, so the default
///   run is itself the "show the baseline first" step the design demands.
/// - **A measurement decides, not the exit code.** After applying, the change
///   is verified (re-read from the system) and measured (unpaired rounds).
///   No measured improvement → the pre-flight state is restored, and the
///   report says so instead of claiming success.
/// - **Rollback comes from the pre-flight read.** DNS set to `Empty` is
///   restored to `Empty` (DHCP), not to a guessed resolver.
///
///     Moppet --net-fix                          # current state + actions
///     Moppet --net-fix --action dns-switch --dns 1.1.1.1 --dry-run
///     Moppet --net-fix --action dns-switch --dns 1.1.1.1 --yes
///     Moppet --net-fix --action noop --yes      # self test: must stay unchanged
///
/// Exit codes: 0 kept / plan only / nothing persistent changed, 1 rolled back
/// or apply failed, 2 usage error. `--json` carries the same facts for scripts.
enum NetworkFixCLI {

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)

        let args = CommandLine.arguments
        let actionName = CLIArgs.string(args, "--action")
        let dnsTargets = CLIArgs.string(args, "--dns")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let desiredMTU = CLIArgs.int(args, "--mtu") ?? 1400
        let dryRun = args.contains("--dry-run")
        let confirmed = args.contains("--yes")
        let rounds = max(2, CLIArgs.int(args, "--rounds") ?? 6)
        let host = CLIArgs.string(args, "--host") ?? "www.apple.com"
        let wantJSON = args.contains("--json")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            defer { semaphore.signal() }
            guard let name = actionName else {
                let state = await readState()
                print(wantJSON ? state.jsonString : renderState(state))
                return
            }
            guard let action = NetworkOptimizer.Action(rawValue: name) else {
                FileHandle.standardError.write(Data((
                    "error: unknown action '\(name)' — available: "
                    + NetworkOptimizer.Action.allCases.map(\.rawValue).joined(separator: ", ")
                    + "\n").utf8))
                exit(2)
            }
            if action == .dnsSwitch,
               dnsTargets.isEmpty || !dnsTargets.allSatisfy(NetworkOptimizer.isValidAddress) {
                FileHandle.standardError.write(Data(
                    "error: dns-switch needs --dns <ip>[,<ip>…] with valid addresses\n".utf8))
                exit(2)
            }
            if action == .mtuFix, !(1...1500).contains(desiredMTU) {
                FileHandle.standardError.write(Data(
                    "error: --mtu must be 1…1500 (got \(desiredMTU))\n".utf8))
                exit(2)
            }

            let applying = !dryRun && confirmed
            let privilege = privilegeForCurrentUser()

            let report = await NetworkOptimizer.run(
                action: action, target: dnsTargets, rounds: rounds, host: host,
                apply: applying, privilege: privilege, desiredMTU: desiredMTU)

            if wantJSON {
                print(fixJSON(report, action: action, applied: applying,
                              privilege: privilege, host: host, rounds: rounds))
            } else {
                print(render(report, action: action, applying: applying,
                             privilege: privilege, host: host, rounds: rounds))
            }

            // The audit trail gets one record per apply attempt that actually
            // reached the machine — a refused plan or a noop self-test wrote
            // nothing, and rows saying "nothing happened" would only bury the
            // records that matter.
            let applyFailed = report.notes.contains { $0.hasPrefix("apply failed") }
            if applying, !report.plan.isNoop, report.applied || applyFailed {
                writeHistory(report, action: action)
            }
            // Exit 1 is only for "a persistent edit was made and then undone,
            // or never took": that is what a script must react to. A noop that
            // measures unchanged, or a transient flush with no inverse, did
            // not change the machine — those stay 0.
            if report.rolledBack || applyFailed {
                exitCode = 1
            }
        }
        semaphore.wait()
        exit(exitCode)
    }

    // MARK: - Rendering

    private static func render(_ report: NetworkOptimizer.FixReport,
                               action: NetworkOptimizer.Action, applying: Bool,
                               privilege: NetworkOptimizer.Privilege,
                               host: String, rounds: Int) -> String {
        let plan = report.plan
        var lines: [String] = []
        lines.append("Moppet network fix · \(action.title)")
        lines.append("  current   \(plan.currentSummary)")
        lines.append("  target    \(plan.targetSummary)")
        lines.append("  privilege \(privilegeLabel(privilege, action: action, applying: applying))")
        for command in plan.applyCommands {
            lines.append("  apply     \(command)")
        }
        for command in plan.rollbackCommands {
            lines.append("  rollback  \(command)")
        }
        for warning in plan.warnings {
            lines.append("  ⚠ \(warning)")
        }
        if !applying {
            lines.append("")
            lines.append("plan only — nothing changed. Add --yes to apply this exact plan.")
        }

        if !report.changes.isEmpty {
            lines.append("")
            lines.append("measurement · \(host) · \(report.before.count)/\(report.after.count) rounds"
                         + " (unpaired) · kept only if '\(action.primaryMetric)' improves")
            lines.append(pad("metric", 8) + pad("before", 11) + pad("after", 11)
                         + pad("Δ", 11) + pad("σ", 10) + pad("MDD", 10) + "verdict")
            lines.append(String(repeating: "─", count: 72))
            for change in report.changes {
                lines.append(
                    pad(change.metric, 8)
                    + pad(fmt(change.before), 11) + pad(fmt(change.after), 11)
                    + pad(String(format: "%+.1f", change.delta), 11)
                    + pad(fmt(change.sigma), 10) + pad(fmt(change.mdd), 10)
                    + change.verdict.rawValue)
            }
        }

        if !report.notes.isEmpty {
            lines.append("")
            for note in report.notes { lines.append("→ \(note)") }
        } else if report.kept {
            lines.append("")
            lines.append("→ kept: measurement cleared the MDD bar; the rollback above undoes it")
        }
        return lines.joined(separator: "\n")
    }

    private static func privilegeLabel(_ privilege: NetworkOptimizer.Privilege,
                                       action: NetworkOptimizer.Action,
                                       applying: Bool) -> String {
        if !applying { return "— (plan only)" }
        switch privilege {
        case .direct: return "direct (root)"
        case .appleScript:
            return action.requiresAdmin
                ? "administrator prompt"
                : "direct (no rights needed)"
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let count = text.count
        return count >= width ? text + " " : text + String(repeating: " ", count: width - count)
    }

    // MARK: - State listing (read-only default mode)

    struct State: Codable {
        struct ServiceState: Codable {
            var name: String
            var device: String
            var disabled: Bool
            var dns: [String]
            var pacURL: String
            var pacEnabled: Bool
        }
        var device: String?
        var gateway: String?
        var mtu: Int?
        var runningAsRoot: Bool
        var services: [ServiceState]
        var actions: [String]
    }

    private static func readState() async -> State {
        let services = await NetworkOptimizer.readServices()
        let route = await NetworkRouterInfo.current()
        var mtu: Int?
        if let device = route.device { mtu = await NetworkOptimizer.readMTU(device: device) }

        var rows: [State.ServiceState] = []
        for service in services {
            // Per-service reads cost a process each; only the active service
            // gets the full picture, the rest are listed for orientation.
            var dns: [String] = []
            var pac = (url: "", enabled: false)
            if service.device == route.device, !service.disabled {
                dns = await NetworkOptimizer.readDNS(service: service.name)
                pac = await NetworkOptimizer.readPAC(service: service.name)
            }
            rows.append(State.ServiceState(
                name: service.name, device: service.device, disabled: service.disabled,
                dns: dns, pacURL: pac.url, pacEnabled: pac.enabled))
        }
        return State(device: route.device, gateway: route.gateway, mtu: mtu,
                     runningAsRoot: geteuid() == 0,
                     services: rows,
                     actions: NetworkOptimizer.Action.allCases.map(\.rawValue))
    }

    private static func renderState(_ state: State) -> String {
        var lines: [String] = []
        lines.append("Moppet network fix · current state")
        lines.append("  default route \(state.device ?? "?") via \(state.gateway ?? "?")"
                     + "   mtu \(state.mtu.map(String.init) ?? "?")"
                     + "   \(state.runningAsRoot ? "running as root" : "not root")")
        lines.append("")
        let header = pad("service", 28) + pad("device", 8) + "state"
        lines.append(header)
        lines.append(String(repeating: "─", count: 62))
        for service in state.services {
            var detail: String
            if service.disabled {
                detail = "disabled"
            } else if service.device == state.device {
                let dns = service.dns.isEmpty ? "automatic (DHCP)" : service.dns.joined(separator: ", ")
                detail = "active · dns \(dns) · pac \(service.pacEnabled ? service.pacURL : "off")"
            } else {
                detail = "idle"
            }
            lines.append(pad(service.name, 28) + pad(service.device, 8) + detail)
        }
        lines.append("")
        lines.append("actions (--action <name>): "
                     + state.actions.joined(separator: ", "))
        lines.append("  dns-switch needs --dns <ip>[,<ip>…] · mtu-fix takes --mtu <n> (default 1400)")
        lines.append("")
        lines.append("usage")
        lines.append("  Moppet --net-fix --action dns-switch --dns 1.1.1.1 --dry-run   # plan only")
        lines.append("  Moppet --net-fix --action dns-switch --dns 1.1.1.1 --yes       # apply + measure")
        lines.append("  Moppet --net-fix --action noop --yes                           # self test")
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON / history

    struct MetricJSON: Codable {
        var metric: String
        var before: Double
        var after: Double
        var delta: Double
        var sigma: Double
        var mdd: Double
        var verdict: String
    }

    struct FixJSON: Codable {
        var action: String
        var mode: String
        var privilege: String
        var host: String
        var roundsPlanned: Int
        var roundsBefore: Int
        var roundsAfter: Int
        var current: String
        var target: String
        var warnings: [String]
        var applyCommands: [String]
        var rollbackCommands: [String]
        var applied: Bool
        /// The design contract (§4.6) names this field: the caller gets a Bool
        /// that says "the change earned its keep", not "the command exited 0".
        var improved: Bool
        var kept: Bool
        var rolledBack: Bool
        var primaryMetric: String
        var primaryVerdict: String?
        var metrics: [MetricJSON]
        var notes: [String]
        var historyWritten: Bool
    }

    /// Shared with the `network_optimize` MCP tool — same JSON shape the CLI
    /// prints, so scripts and the AI read the same facts.
    static func fixJSON(_ report: NetworkOptimizer.FixReport,
                        action: NetworkOptimizer.Action, applied: Bool,
                        privilege: NetworkOptimizer.Privilege,
                        host: String, rounds: Int) -> String {
        let metrics = report.changes.map {
            MetricJSON(metric: $0.metric, before: $0.before, after: $0.after,
                       delta: $0.delta, sigma: $0.sigma, mdd: $0.mdd,
                       verdict: $0.verdict.rawValue)
        }
        let output = FixJSON(
            action: action.rawValue,
            mode: applied ? "applied" : "plan",
            privilege: applyingLabel(privilege, action: action, applied: applied),
            host: host, roundsPlanned: rounds,
            roundsBefore: report.before.count, roundsAfter: report.after.count,
            current: report.plan.currentSummary, target: report.plan.targetSummary,
            warnings: report.plan.warnings,
            applyCommands: report.plan.applyCommands,
            rollbackCommands: report.plan.rollbackCommands,
            applied: report.applied, improved: report.kept, kept: report.kept,
            rolledBack: report.rolledBack,
            primaryMetric: action.primaryMetric,
            primaryVerdict: report.changes.first { $0.metric == action.primaryMetric }?
                .verdict.rawValue,
            metrics: metrics, notes: report.notes,
            historyWritten: applied && !report.plan.isNoop)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(output),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Root runs the commands directly; otherwise the AppleScript prompt
    /// carries the elevation, same as LaunchItems.
    static func privilegeForCurrentUser() -> NetworkOptimizer.Privilege {
        geteuid() == 0 ? .direct : .appleScript
    }

    private static func applyingLabel(_ privilege: NetworkOptimizer.Privilege,
                                      action: NetworkOptimizer.Action,
                                      applied: Bool) -> String {
        if !applied { return "plan-only" }
        switch privilege {
        case .direct: return "direct"
        case .appleScript: return action.requiresAdmin ? "admin-prompt" : "direct"
        }
    }

    /// One audit row per apply attempt that reached the machine. `path` carries
    /// the exact command so the History page answers "what did it run?", not
    /// just "network happened". Shared with the `network_optimize` tool.
    static func writeHistory(_ report: NetworkOptimizer.FixReport,
                             action: NetworkOptimizer.Action) {
        let success = report.applied && report.kept && !report.rolledBack
        let message = report.notes.joined(separator: "; ")
        HistoryStore.append(CleanRecord(
            date: Date(),
            sectionTitles: [action.title],
            requestedBytes: 0,
            freedBytes: 0,
            itemCount: 1,
            items: [CleanRecordItem(
                path: report.plan.applyCommands.joined(separator: "; "),
                bytes: 0, mode: .permanent,
                success: success,
                error: success ? nil : (message.isEmpty ? "not kept" : message))],
            source: .network))
    }
}

extension NetworkFixCLI.State {
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
