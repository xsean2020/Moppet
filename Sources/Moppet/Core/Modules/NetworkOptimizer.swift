import Foundation
import Darwin

/// The write half of the network module: a small catalogue of fixes, each with
/// a pre-flight read, an apply step, a verification step and a rollback.
///
/// Design rules that are not negotiable:
/// - **Nothing is applied without a plan.** `plan(...)` is pure and prints the
///   exact commands plus their inverse, so the user (or `--net-fix --dry-run`)
///   sees what will happen to their machine before it happens.
/// - **Every change is verified, then measured, then kept only if it worked.**
///   "Applied successfully" is not success. If the measurement says the change
///   did nothing, the config is restored — silently leaving a no-op edit behind
///   is how cleaners earn their reputation.
/// - **Rollback is generated from the pre-flight read**, not from assumptions:
///   if DNS was `Empty` (DHCP) we restore `Empty`, not a guessed resolver.
/// - **No user-supplied strings reach a shell.** Addresses are validated with
///   `inet_pton`; the service name comes from the system and is rejected if it
///   contains quoting characters.
enum NetworkOptimizer {

    // MARK: - Model

    struct Service: Sendable, Equatable {
        var name: String
        var device: String
        var disabled: Bool
    }

    enum Action: String, CaseIterable, Sendable {
        case dnsSwitch = "dns-switch"
        case dnsFlush = "dns-flush"
        case proxyOff = "proxy-off"
        case mtuFix = "mtu-fix"
        /// Applies `true` and measures anyway. The A/A test for this whole
        /// loop: it must report "no improvement" and change nothing, which is
        /// exactly what makes the other four actions trustworthy.
        case noop = "noop"

        var title: String {
            switch self {
            case .dnsSwitch: return "Switch DNS servers"
            case .dnsFlush: return "Flush DNS cache"
            case .proxyOff: return "Turn off stale PAC/proxy"
            case .mtuFix: return "Lower interface MTU"
            case .noop: return "No-op (self test)"
            }
        }

        /// Which measurement decides whether the change earned its keep.
        var primaryMetric: String {
            switch self {
            case .dnsSwitch, .dnsFlush: return "dns"
            case .proxyOff, .mtuFix, .noop: return "ttfb"
            }
        }

        var requiresAdmin: Bool { self != .noop }
    }

    struct Plan: Sendable {
        var action: Action
        var service: Service?
        var currentSummary: String
        var targetSummary: String
        var applyCommands: [String]
        var rollbackCommands: [String]
        var requiresAdmin: Bool
        var warnings: [String]

        /// Nothing to undo and nothing to do — used to refuse a plan early.
        var isNoop: Bool { applyCommands.allSatisfy { $0 == "true" } }
    }

    struct FixReport: Sendable {
        var plan: Plan
        var applied: Bool
        var before: [NetworkEngine.RoundSample]
        var after: [NetworkEngine.RoundSample]
        var changes: [NetworkReference.MetricChange]
        var kept: Bool
        var rolledBack: Bool
        var notes: [String]
    }

    enum FixError: LocalizedError {
        case needsAdmin(String)
        case noService(String)
        case invalidTarget(String)
        case verificationFailed(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .needsAdmin(let hint): return "administrator rights required — \(hint)"
            case .noService(let device): return "no network service found for \(device)"
            case .invalidTarget(let value): return "not an IP address: \(value)"
            case .verificationFailed(let detail): return "change did not take effect: \(detail)"
            case .commandFailed(let detail): return "command failed: \(detail)"
            }
        }
    }

    // MARK: - Parsing (pure, asserted in --smoke)

    /// `networksetup -listnetworkserviceorder` prints a pair of lines per
    /// service:
    ///
    ///     (1) Ethernet
    ///     (Hardware Port: Ethernet, Device: en0)
    ///
    /// A `(*)` in place of the index marks a disabled service. Service *names*
    /// are free text (they contain spaces, slashes and dots), so the name is
    /// everything after the index, not a whitespace-delimited token.
    static func parseServices(_ output: String) -> [Service] {
        var services: [Service] = []
        var pendingName: String?
        var pendingDisabled = false

        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("(") {
                // Device line for the service collected on the previous pass.
                if line.contains("Device:") {
                    if let name = pendingName {
                        let device = line
                            .components(separatedBy: "Device:")
                            .last?
                            .trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                            ?? ""
                        services.append(Service(name: name, device: device,
                                                disabled: pendingDisabled))
                        pendingName = nil
                    }
                    continue
                }
                // Index line: "(1) Ethernet" or "(*) Wi-Fi".
                guard let close = line.firstIndex(of: ")") else { continue }
                let index = line[line.index(after: line.startIndex)..<close]
                pendingDisabled = index == "*"
                pendingName = String(line[line.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return services
    }

    /// `networksetup -getdnsservers` answers either a list of addresses or the
    /// sentence "There aren't any DNS Servers set on X." — the latter means
    /// "automatic", which is the state we must restore to, not an empty list.
    static func parseDNS(_ output: String) -> [String] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("There aren't any DNS Servers") else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `networksetup -getautoproxyurl` prints "URL: …" then "Enabled: Yes|No".
    static func parsePAC(_ output: String) -> (url: String, enabled: Bool) {
        var url = ""
        var enabled = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("URL:") {
                url = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Enabled:") {
                enabled = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                    .lowercased() == "yes"
            }
        }
        return (url, enabled)
    }

    /// Only real addresses get near a shell command.
    static func isValidAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let isV4 = inet_pton(AF_INET, value, &v4) == 1
        let isV6 = inet_pton(AF_INET6, value, &v6) == 1
        return isV4 || isV6
    }

    /// Service names come from the system, but they still get quoted and
    /// sanity-checked: a name containing a quote would break out of the
    /// command string.
    static func isSafeServiceName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("\"") && !name.contains("\\") && !name.contains("\n")
    }

    // MARK: - Planning (pure)

    /// Builds the exact commands for an action, given the state read in
    /// pre-flight. Pure so `--smoke` can assert both the apply and the rollback
    /// string without touching the machine.
    static func plan(action: Action, service: Service?, device: String,
                     target: [String], currentDNS: [String],
                     currentPAC: (url: String, enabled: Bool)? = nil,
                     currentMTU: Int? = nil,
                     desiredMTU: Int = 1400) -> Plan {
        var warnings: [String] = []
        var apply: [String] = []
        var rollback: [String] = []
        var current = "—"
        var goal = "—"

        switch action {
        case .noop:
            apply = ["true"]
            rollback = ["true"]
            current = "unchanged"
            goal = "unchanged"

        case .dnsSwitch:
            guard let service, isSafeServiceName(service.name) else {
                warnings.append("no usable network service")
                break
            }
            guard !target.isEmpty, target.allSatisfy(isValidAddress) else {
                warnings.append("target must be one or more IP addresses")
                break
            }
            let svc = "\"\(service.name)\""
            current = currentDNS.isEmpty ? "automatic (DHCP)" : currentDNS.joined(separator: ", ")
            goal = target.joined(separator: ", ")
            if currentDNS == target {
                warnings.append("already set to the requested servers")
            }
            apply = ["networksetup -setdnsservers \(svc) \(target.joined(separator: " "))"]
            // Restore exactly what was there: `Empty` means "back to DHCP",
            // which is a different state from "no servers configured".
            rollback = [currentDNS.isEmpty
                        ? "networksetup -setdnsservers \(svc) Empty"
                        : "networksetup -setdnsservers \(svc) \(currentDNS.joined(separator: " "))"]

        case .dnsFlush:
            apply = ["dscacheutil -flushcache; killall -HUP mDNSResponder"]
            rollback = []
            current = "cache contents unknown by design"
            goal = "empty cache"

        case .proxyOff:
            guard let service, isSafeServiceName(service.name) else {
                warnings.append("no usable network service")
                break
            }
            let svc = "\"\(service.name)\""
            let pac = currentPAC ?? (url: "", enabled: false)
            current = pac.enabled ? "PAC enabled (\(pac.url.isEmpty ? "no URL" : pac.url))" : "disabled"
            goal = "PAC disabled"
            if !pac.enabled {
                warnings.append("PAC is already off")
            }
            apply = ["networksetup -setautoproxystate \(svc) off"]
            // The URL is left in place, so turning it back on is the whole
            // rollback — no need to re-enter the address.
            rollback = ["networksetup -setautoproxystate \(svc) on"]

        case .mtuFix:
            guard !device.isEmpty else {
                warnings.append("no active device")
                break
            }
            current = currentMTU.map { "\($0)" } ?? "unknown"
            goal = "\(desiredMTU)"
            if let currentMTU, currentMTU <= desiredMTU {
                warnings.append("current MTU \(currentMTU) is already <= \(desiredMTU)")
            }
            // MTU is set on the *device*, unlike DNS/PAC which take a service.
            apply = ["networksetup -setMTU \(device) \(desiredMTU)"]
            rollback = ["networksetup -setMTUAndMediaAutomatically \(device)"]
        }

        return Plan(action: action, service: service,
                    currentSummary: current, targetSummary: goal,
                    applyCommands: apply, rollbackCommands: rollback,
                    requiresAdmin: action.requiresAdmin, warnings: warnings)
    }

    // MARK: - Execution

    enum Privilege: Sendable {
        /// Running as root, or a no-op that needs no rights.
        case direct
        /// GUI path: AppleScript administrator prompt.
        case appleScript
    }

    static func execute(_ commands: [String], as privilege: Privilege) async throws -> String {
        var output = ""
        for command in commands where command != "true" {
            do {
                let result: String
                switch privilege {
                case .direct:
                    result = try await OptimizeEngine.shell(command, timeout: 60)
                case .appleScript:
                    result = try await OptimizeEngine.shellWithAdmin(command)
                }
                output += result
            } catch {
                throw FixError.commandFailed("\(command) — \(error.localizedDescription)")
            }
        }
        return output
    }

    // MARK: - Read current state

    static func readServices() async -> [Service] {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/sbin/networksetup -listnetworkserviceorder", timeout: 10) else { return [] }
        return parseServices(output)
    }

    static func readDNS(service: String) async -> [String] {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/sbin/networksetup -getdnsservers \"\(service)\"", timeout: 10) else { return [] }
        return parseDNS(output)
    }

    static func readPAC(service: String) async -> (url: String, enabled: Bool) {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/sbin/networksetup -getautoproxyurl \"\(service)\"", timeout: 10) else {
            return ("", false)
        }
        return parsePAC(output)
    }

    static func readMTU(device: String) async -> Int? {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/sbin/networksetup -getMTU \(device)", timeout: 10),
              let range = output.range(of: "Active MTU: ") else { return nil }
        return Int(output[range.upperBound...].prefix { $0.isNumber })
    }

    /// Verifies the change actually took, by re-reading the same source the
    /// plan was built from. A command exiting 0 is not evidence.
    static func verify(action: Action, service: Service?, device: String,
                       target: [String], desiredMTU: Int) async -> String? {
        switch action {
        case .noop:
            return nil
        case .dnsSwitch:
            guard let service else { return "no service" }
            let now = await readDNS(service: service.name)
            return now == target ? nil : "DNS is \(now.joined(separator: ", "))"
        case .dnsFlush:
            return nil
        case .proxyOff:
            guard let service else { return "no service" }
            let pac = await readPAC(service: service.name)
            return pac.enabled ? "PAC still enabled" : nil
        case .mtuFix:
            let now = await readMTU(device: device)
            return now == desiredMTU ? nil : "MTU is \(now.map(String.init) ?? "?")"
        }
    }

    // MARK: - The loop

    /// pre-flight → baseline → apply → verify → re-measure → keep or roll back.
    ///
    /// `rounds` is per side. Unpaired comparison, because a persistent config
    /// change cannot be flipped back and forth between paired samples — the
    /// weaker test is the honest one here, and its MDD is correspondingly wide.
    static func run(action: Action, target: [String], rounds: Int, host: String,
                    apply: Bool, privilege: Privilege,
                    desiredMTU: Int = 1400) async -> FixReport {
        let services = await readServices()
        let route = await NetworkRouterInfo.current()
        let service = services.first { $0.device == route.device && !$0.disabled }
        let device = route.device ?? ""

        // Pre-flight reads: these are what the rollback is built from, so they
        // must happen before anything changes.
        var dns: [String] = []
        var pacState: (url: String, enabled: Bool) = (url: "", enabled: false)
        if let service {
            dns = await readDNS(service: service.name)
            pacState = await readPAC(service: service.name)
        }
        let mtu = device.isEmpty ? nil : await readMTU(device: device)

        let plan = plan(action: action, service: service, device: device,
                        target: target, currentDNS: dns,
                        currentPAC: pacState, currentMTU: mtu,
                        desiredMTU: desiredMTU)

        var report = FixReport(plan: plan, applied: false, before: [], after: [],
                               changes: [], kept: false, rolledBack: false, notes: [])

        guard apply else {
            report.notes.append("dry run — nothing changed")
            return report
        }
        guard !plan.applyCommands.isEmpty else {
            report.notes.append("nothing to do")
            return report
        }
        guard !plan.warnings.contains(where: { $0.hasPrefix("no usable") }) else {
            report.notes.append("plan incomplete, refusing to run")
            return report
        }

        let ip = NetworkEngine.resolveIPv4(host)
        let control = route.gateway
        let controlIP = (control == ip) ? nil : control

        for _ in 0..<rounds {
            if let sample = await NetworkEngine.sampleRound(host: host, ip: ip,
                                                            controlIP: controlIP) {
                report.before.append(sample)
            }
        }

        do {
            _ = try await execute(plan.applyCommands, as: privilege)
        } catch {
            report.notes.append("apply failed: \(error.localizedDescription)")
            return report
        }
        report.applied = true

        if let problem = await verify(action: action, service: service, device: device,
                                      target: target, desiredMTU: desiredMTU) {
            report.notes.append("verification failed — \(problem); rolling back")
            _ = try? await execute(plan.rollbackCommands, as: privilege)
            report.rolledBack = true
            return report
        }

        for _ in 0..<rounds {
            if let sample = await NetworkEngine.sampleRound(host: host, ip: ip,
                                                            controlIP: controlIP) {
                report.after.append(sample)
            }
        }

        let metrics: [(String, (NetworkEngine.RoundSample) -> Double)] = [
            ("dns", { $0.dns }), ("ttfb", { $0.ttfb }),
            ("tls", { $0.tls }), ("tcp", { $0.tcp }),
        ]
        for (name, key) in metrics {
            if let change = NetworkReference.unpaired(before: report.before.map(key),
                                                      after: report.after.map(key),
                                                      metric: name) {
                report.changes.append(change)
            }
        }

        // Keep only a measured improvement. "unchanged" means we edited the
        // user's configuration and bought nothing — that gets rolled back too.
        let primary = report.changes.first { $0.metric == action.primaryMetric }
        report.kept = primary?.verdict == .improved
        if !report.kept, !plan.rollbackCommands.isEmpty {
            _ = try? await execute(plan.rollbackCommands, as: privilege)
            report.rolledBack = true
            report.notes.append("no measured improvement — configuration restored")
        } else if report.kept {
            report.notes.append("kept: \(plan.rollbackCommands.joined(separator: "; ")) undoes it")
        }
        return report
    }
}

/// Where the traffic actually goes. Kept separate from the probe's own parser
/// because the optimiser only needs three fields and must not spawn the extra
/// processes the full probe runs.
enum NetworkRouterInfo {
    struct Info: Sendable {
        var device: String?
        var gateway: String?
    }

    static func current() async -> Info {
        guard let output = try? await OptimizeEngine.shell("/sbin/route -n get default",
                                                           timeout: 5) else { return Info() }
        var info = Info()
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "interface": info.device = value
            case "gateway": info.gateway = value
            default: break
            }
        }
        return info
    }
}
