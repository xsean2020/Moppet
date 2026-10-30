import Foundation
import Network

/// `--net-probe`: the headless half of the network module.
///
/// The GUI is not built yet on purpose. Measurement is the part that can be
/// wrong in ways nobody notices — a cached DNS lookup, a reused connection, a
/// speed test that actually timed TLS — so it gets validated in a terminal
/// first, where every number is visible and diffable between runs.
///
///     Moppet --net-probe
///     Moppet --net-probe --samples 9 --json
///     Moppet --net-probe --hosts speed.cloudflare.com,www.apple.com --throughput
///
/// What it prints, and why each part exists:
/// 1. environment — which interface/gateway/MTU the numbers belong to; without
///    this a result is unattributable and cannot be compared to a later run;
/// 2. phase table — DNS / TCP / TLS / TTFB per target, median + MAD + n, plus
///    the TLS÷TCP amplification that localises handshake loss;
/// 3. control — TCP to a fixed IP, the measurement that does *not* touch DNS,
///    so a later "did my DNS change help?" has something to subtract;
/// 4. cold DNS — uncached resolver round trip;
/// 5. optional throughput — multi-stream, warm-up discarded;
/// 6. findings — the two or three things that are already conclusive.
enum NetworkProbeCLI {

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)

        let args = CommandLine.arguments
        let samples = intValue(args, "--samples") ?? 5
        let wantJSON = args.contains("--json")
        let wantThroughput = args.contains("--throughput")
        let hosts = stringValue(args, "--hosts")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            ?? ["speed.cloudflare.com", "www.apple.com", "www.baidu.com"]

        let compare = args.contains("--compare")
        let command = stringValue(args, "--run")
        let rounds = intValue(args, "--rounds") ?? 6
        let controlIP = stringValue(args, "--control-ip")
        let record = !args.contains("--no-record")

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if compare {
                let text = await runComparison(host: hosts.first ?? "www.apple.com",
                                               rounds: rounds, command: command,
                                               controlIP: controlIP)
                print(text)
            } else {
                let report = await collect(hosts: hosts, samples: samples,
                                           throughput: wantThroughput, record: record)
                if wantJSON {
                    print(report.jsonString)
                } else {
                    print(render(report))
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    // MARK: - Collection

    struct Report: Codable {
        struct Environment: Codable {
            var interface: String?
            var interfaceKind: String?
            var expensive: Bool?
            var constrained: Bool?
            var ipv4: String?
            var gateway: String?
            var mtu: Int?
            var proxy: String?
            var startedAt: String
        }
        struct ThroughputResult: Codable {
            var mbps: Double
            var bytes: Int64
            var seconds: Double
            var streams: Int
            var endpoint: String
        }

        var environment: Environment
        var targets: [TargetRow]
        var control: ControlRow?
        var coldDNS: StatsRow?
        var throughput: ThroughputResult?
        var history: HistoryRow?
        var findings: [String]
    }

    struct TargetRow: Codable {
        var host: String
        var n: Int
        var failures: Int
        var dns: StatsRow?
        var tcp: StatsRow?
        var tls: StatsRow?
        var ttfb: StatsRow?
        var amplification: Double?
        var proto: String?
    }

    struct StatsRow: Codable {
        var n: Int
        var median: Double
        var mad: Double
        var p95: Double
    }

    /// Historical bucket for the first target: what "normal" looks like on this
    /// interface at this hour.
    struct HistoryRow: Codable {
        var host: String
        var n: Int
        var ttfbP50: Double
        var ttfbP10: Double
        var ttfbP90: Double
    }

    struct ControlRow: Codable {
        var ip: String
        var tcp: StatsRow?
        var synRetries: Int
    }

    private static func collect(hosts: [String], samples: Int,
                                throughput: Bool, record: Bool) async -> Report {
        let path = await currentPath()
        let route = await defaultRoute()
        let proxy = await systemProxy()

        // MTU comes from the route table itself; the networksetup fallback only
        // runs when that parse fails, so the steady state spawns no extra
        // process. Either way it happens once per run, never per sample.
        var mtu = route.mtu
        if mtu == nil, let iface = route.interface { mtu = await interfaceMTU(iface) }

        let environment = Report.Environment(
            interface: route.interface,
            interfaceKind: path?.kind,
            expensive: path?.expensive,
            constrained: path?.constrained,
            ipv4: route.interface.flatMap { ipv4Address(of: $0) },
            gateway: route.gateway,
            mtu: mtu,
            proxy: proxy,
            startedAt: ISO8601DateFormatter().string(from: Date())
        )

        // 1. Phase table, one target at a time. Sequential on purpose: parallel
        //    requests contend for the same link and inflate each other's RTT.
        var rows: [TargetRow] = []
        for host in hosts {
            // DNS once per name, not per sample: the resolver caches after the
            // first lookup, so a per-sample median would always read ~0 and
            // hide the cold cost entirely.
            let dnsOnce = NetworkEngine.resolveMilliseconds(host: host)
            let ip = NetworkEngine.resolveIPv4(host)

            var phases: [NetworkEngine.PhaseSample] = []
            var failures = 0
            for _ in 0..<samples {
                let tcp = ip.flatMap { NetworkEngine.tcpConnectMilliseconds(ip: $0) }
                let (ready, ttfb, version) = await NetworkEngine.measureHandshake(host: host)
                guard ready > 0 else { failures += 1; continue }
                // TLS is the difference, not the whole handshake: `ready`
                // already contains DNS + TCP.
                let tls = tcp.map { max(0, ready - $0) } ?? ready
                phases.append(NetworkEngine.PhaseSample(
                    dns: dnsOnce, tcp: tcp, tls: tls, ttfb: ttfb,
                    total: ready, httpVersion: version))
            }
            rows.append(TargetRow(
                host: host,
                n: phases.count,
                failures: failures,
                // One lookup per name, so n=1 — reporting it as 5 would claim
                // five independent DNS samples where there was one.
                dns: dnsOnce.map { StatsRow(n: 1, median: $0, mad: 0, p95: $0) },
                tcp: stats(phases.compactMap(\.tcp)),
                tls: stats(phases.compactMap(\.tls)),
                ttfb: stats(phases.compactMap(\.ttfb)),
                amplification: {
                    guard let tcp = stats(phases.compactMap(\.tcp))?.median, tcp > 0,
                          let tls = stats(phases.compactMap(\.tls))?.median, tls > 0
                    else { return nil }
                    return tls / tcp
                }(),
                proto: phases.compactMap(\.httpVersion).first
            ))
        }

        // 2. Control: same measurement with DNS removed from the equation.
        var control: ControlRow?
        if let host = hosts.first, let ip = NetworkEngine.resolveIPv4(host) {
            var handshakes: [Double] = []
            for _ in 0..<samples {
                if let ms = NetworkEngine.tcpConnectMilliseconds(ip: ip) { handshakes.append(ms) }
            }
            control = ControlRow(ip: ip,
                                 tcp: stats(handshakes),
                                 synRetries: NetworkEngine.synRetryCount(handshakes))
        }

        // 3. Cold DNS: never cached, so it measures the resolver rather than
        //    mDNSResponder's memory.
        var coldSamples: [Double] = []
        for _ in 0..<samples {
            if let ms = NetworkEngine.coldDNSMilliseconds() { coldSamples.append(ms) }
        }
        let coldDNS = stats(coldSamples)

        // 4. Throughput is opt-in: it moves real data.
        var throughputResult: Report.ThroughputResult?
        if throughput,
           let result = await NetworkEngine.measureDownload(
               host: "speed.cloudflare.com", path: "/__down?bytes=2000000") {
            throughputResult = Report.ThroughputResult(
                mbps: result.mbps, bytes: result.bytes, seconds: result.seconds,
                streams: result.streams, endpoint: result.endpoint)
        }

        // Historical reference: what this interface looked like at this hour.
        // Silent until there are enough samples — a "baseline" of two readings
        // is worse than none, because it looks authoritative.
        var history: HistoryRow?
        if let first = rows.first, let iface = environment.interface {
            let hour = Calendar.current.component(.hour, from: Date())
            if let bucket = NetworkReference.NetworkSampleStore.bucket(
                interface: iface, host: first.host, hour: hour) {
                history = HistoryRow(host: first.host, n: bucket.n,
                                     ttfbP50: bucket.ttfbMedian,
                                     ttfbP10: bucket.ttfbP10,
                                     ttfbP90: bucket.ttfbP90)
            }
        }

        if record, let iface = environment.interface {
            let hour = Calendar.current.component(.hour, from: Date())
            for row in rows {
                guard let dns = row.dns?.median, let tcp = row.tcp?.median,
                      let tls = row.tls?.median, let ttfb = row.ttfb?.median else { continue }
                NetworkReference.NetworkSampleStore.append(.init(
                    at: Date(), interface: iface, ssid: nil, hour: hour,
                    host: row.host, dns: dns, tcp: tcp, tls: tls, ttfb: ttfb))
            }
        }

        return Report(environment: environment, targets: rows, control: control,
                      coldDNS: coldDNS, throughput: throughputResult,
                      history: history,
                      findings: findings(rows: rows, control: control, coldDNS: coldDNS))
    }

    // MARK: - Comparison (the reference frame)

    /// A/A (no `--run`): rounds alternate A,B,A,B so drift cancels in the paired
    /// difference. A/B (`--run`): measure, change, measure — unpaired, wider
    /// MDD, and labelled as the weaker test it is.
    private static func runComparison(host: String, rounds: Int, command: String?,
                                      controlIP: String?) async -> String {
        guard let ip = NetworkEngine.resolveIPv4(host) else {
            return "cannot resolve \(host)"
        }
        // Control defaults to the gateway: no DNS, no WAN, nothing a resolver
        // or proxy change can touch. If it equals the target IP the correction
        // would cancel the very metric being measured, so it is dropped.
        let route = await defaultRoute()
        let resolvedControl = controlIP ?? route.gateway
        let control = (resolvedControl == ip) ? nil : resolvedControl

        var before: [NetworkEngine.RoundSample] = []
        var after: [NetworkEngine.RoundSample] = []
        let paired = command == nil

        if paired {
            for _ in 0..<rounds {
                if let a = await NetworkEngine.sampleRound(host: host, ip: ip, controlIP: control) {
                    before.append(a)
                }
                if let b = await NetworkEngine.sampleRound(host: host, ip: ip, controlIP: control) {
                    after.append(b)
                }
            }
        } else {
            for _ in 0..<rounds {
                if let a = await NetworkEngine.sampleRound(host: host, ip: ip, controlIP: control) {
                    before.append(a)
                }
            }
            if let command {
                _ = try? await OptimizeEngine.shell(command, timeout: 120)
            }
            for _ in 0..<rounds {
                if let b = await NetworkEngine.sampleRound(host: host, ip: ip, controlIP: control) {
                    after.append(b)
                }
            }
        }

        guard before.count >= 2, after.count >= 2 else {
            return "not enough samples (before \(before.count), after \(after.count))"
        }

        let metrics: [(String, (NetworkEngine.RoundSample) -> Double)] = [
            ("ttfb", { $0.ttfb }), ("tls", { $0.tls }),
            ("tcp", { $0.tcp }), ("dns", { $0.dns }),
        ]
        var changes: [NetworkReference.MetricChange] = []
        for (name, key) in metrics {
            let a = before.map(key)
            let b = after.map(key)
            let cb = before.map { $0.control }
            let ca = after.map { $0.control }
            let change = paired
                ? NetworkReference.paired(before: a, after: b,
                                          controlBefore: cb, controlAfter: ca, metric: name)
                : NetworkReference.unpaired(before: a, after: b, metric: name)
            if let change { changes.append(change) }
        }

        return renderComparison(host: host, control: control, paired: paired,
                                command: command, rounds: before.count,
                                changes: changes)
    }

    private static func renderComparison(host: String, control: String?, paired: Bool,
                                         command: String?, rounds: Int,
                                         changes: [NetworkReference.MetricChange]) -> String {
        var lines: [String] = []
        if paired {
            lines.append("A/A reference test · \(rounds) paired rounds · \(host)"
                         + (control.map { " · control \($0)" } ?? " · no control"))
            lines.append("nothing changes between rounds — every row should read 'unchanged'")
        } else {
            lines.append("A/B test · \(rounds) rounds per side · \(host)")
            lines.append("between rounds: \(command ?? "—")")
        }
        lines.append("")
        lines.append(pad("metric", 8) + pad("before", 11) + pad("after", 11)
                     + pad("Δ", 11) + pad("σ", 10) + pad("MDD", 10) + "verdict")
        lines.append(String(repeating: "─", count: 78))
        for change in changes {
            lines.append(
                pad(change.metric, 8)
                + pad(ms(change.before), 11) + pad(ms(change.after), 11)
                + pad(signed(change.delta), 11)
                + pad(ms(change.sigma), 10) + pad(ms(change.mdd), 10)
                + change.verdict.rawValue
            )
        }
        lines.append("")

        let improved = changes.filter { $0.verdict == .improved }.map(\.metric)
        let regressed = changes.filter { $0.verdict == .regressed }.map(\.metric)
        let unchanged = changes.filter { $0.verdict == .unchanged }.count
        if improved.isEmpty && regressed.isEmpty {
            lines.append("→ \(unchanged)/\(changes.count) unchanged — the pipeline does not "
                         + "invent improvement.")
        } else {
            if !improved.isEmpty { lines.append("→ improved: \(improved.joined(separator: ", "))") }
            if !regressed.isEmpty { lines.append("→ regressed: \(regressed.joined(separator: ", "))") }
            if unchanged > 0 { lines.append("→ unchanged: \(unchanged)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func signed(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    // MARK: - Interpretation (kept deliberately small)

    private static func findings(rows: [TargetRow], control: ControlRow?,
                                 coldDNS: StatsRow?) -> [String] {
        var out: [String] = []
        for row in rows {
            // Ratio alone over-triggers on fast hosts: TCP 4ms → TLS 100ms is
            // 24×, which is ordinary certificate work, not loss. Loss shows up
            // as an absolute stall, so require both signals.
            // n >= 5 for the same reason the verdict needs it: two samples and
            // a median is an average of two numbers, which is a coin flip
            // wearing a diagnosis.
            if row.n >= 5, let amp = row.amplification, let tls = row.tls?.median,
               tls > 400, amp > 10 {
                out.append("⚠ \(row.host): TLS \(Int(tls))ms = \(Int(amp))× the TCP "
                           + "handshake (normal 1–4×) → handshake is being retried; "
                           + "not DNS, not bandwidth")
            }
            if row.n >= 5, let ttfb = row.ttfb?.median, ttfb > 800 {
                out.append("⚠ \(row.host): TTFB \(Int(ttfb))ms — above the 800ms "
                           + "'feels broken' threshold")
            }
        }
        if let syn = control?.synRetries, syn > 0 {
            out.append("⚠ \(syn)/\(control?.tcp?.n ?? 0) TCP connects hit a SYN retransmission "
                       + "(connect ≈ 1s/3s/7s) — packets are being dropped")
        }
        if let cold = coldDNS, cold.n >= 5, cold.median > 100 {
            let dns = cold.median
            out.append("⚠ cold DNS \(Int(dns))ms — resolver is slow; a DNS change is worth measuring")
        }
        if out.isEmpty { out.append("no conclusive finding — every phase is within normal range") }
        return out
    }

    // MARK: - Rendering

    private static func render(_ report: Report) -> String {
        var lines: [String] = []
        let env = report.environment
        lines.append("Moppet network probe · \(env.startedAt)")
        lines.append("  interface  \(env.interface ?? "?")"
                     + (env.interfaceKind.map { " (\($0))" } ?? "")
                     + (env.ipv4.map { "  \($0)" } ?? ""))
        lines.append("  gateway    \(env.gateway ?? "?")   mtu \(env.mtu.map(String.init) ?? "?")")
        if let proxy = env.proxy {
            lines.append("  proxy      \(proxy)")
        }
        lines.append("")

        let header = pad("target", 26) + pad("n", 4) + pad("dns", 9) + pad("tcp", 9)
            + pad("tls", 11) + pad("ttfb", 11) + pad("tls/tcp", 10) + "http"
        lines.append(header)
        lines.append(String(repeating: "─", count: 82))
        for row in report.targets {
            lines.append(
                pad(row.host, 26)
                + pad("\(row.n)", 4)
                + pad(ms(row.dns), 9) + pad(ms(row.tcp), 9)
                + pad(ms(row.tls), 11) + pad(ms(row.ttfb), 11)
                + pad(amplification(row.amplification), 10)
                + (row.proto ?? "—")
            )
        }

        lines.append("")
        lines.append("dns is one cold lookup per host (the resolver caches after that);"
                     + " every other column is the median of n samples.")
        if let control = report.control {
            lines.append("")
            lines.append("control (fixed IP, DNS removed): \(control.ip)"
                         + "   tcp p50 \(ms(control.tcp))"
                         + "   mad \(fmt(control.tcp?.mad))"
                         + "   syn-retries \(control.synRetries)")
        }
        if let dns = report.coldDNS {
            lines.append("cold DNS (NXDOMAIN, uncached)  : p50 \(ms(dns))"
                         + "   p95 \(ms(StatsRow(n: dns.n, median: dns.p95, mad: dns.mad, p95: dns.p95)))"
                         + "   mad \(fmt(dns.mad))")
        }
        if let history = report.history {
            // The historical reference: what this interface looked like at this
            // hour. p10/p90 rather than a single number, because "normal" here
            // is a distribution, not a value.
            lines.append("history (same hour, n=\(history.n))  : ttfb p50 \(ms(history.ttfbP50))"
                         + "   p10 \(ms(history.ttfbP10))   p90 \(ms(history.ttfbP90))")
        }
        if let tp = report.throughput {
            lines.append("throughput                     : \(String(format: "%.1f", tp.mbps)) Mbps"
                         + "  (\(String(format: "%.1f", Double(tp.bytes) / 1_000_000)) MB"
                         + " over \(String(format: "%.1f", tp.seconds))s, \(tp.streams) streams)")
        }

        lines.append("")
        lines.append("findings")
        for finding in report.findings { lines.append("  \(finding)") }
        return lines.joined(separator: "\n")
    }

    /// `Int(0.99)` printed "0×", which reads as "no TLS at all". Under 10 the
    /// value is a ratio worth a decimal; above it the integer is the story.
    private static func amplification(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? "\(Int(value.rounded()))×" : String(format: "%.1f×", value)
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func ms(_ stats: StatsRow?) -> String {
        guard let stats else { return "—" }
        return String(format: "%.1f", stats.median)
    }

    private static func fmt(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        // Count characters, not bytes: host names are ASCII but the labels are
        // not, and a byte-count pad would misalign the header row.
        let count = text.count
        return count >= width ? text + " " : text + String(repeating: " ", count: width - count)
    }

    // MARK: - Environment

    struct RouteInfo {
        var interface: String?
        var gateway: String?
        var mtu: Int?
    }

    /// `route -n get default` is the only dependency-free way to learn which
    /// interface actually carries traffic — `NWPath` tells you the *type* but
    /// not the name, and "en1 vs en11" is exactly the ambiguity that produced
    /// the DNS-mismatch finding this module exists to catch.
    private static func defaultRoute() async -> RouteInfo {
        guard let output = try? await OptimizeEngine.shell("/sbin/route -n get default", timeout: 5)
        else { return RouteInfo() }
        return parseRoute(output)
    }

    /// Pure parser, so the one fragile thing here — a text format owned by
    /// `route(8)` — can be asserted in `--smoke` against a captured sample
    /// instead of only being exercised on a live machine.
    static func parseRoute(_ output: String) -> RouteInfo {
        var info = RouteInfo()
        var columns: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Key/value lines: "gateway: 192.168.0.1", "interface: en11".
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colon])
                let value = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                switch key {
                case "interface": info.interface = value
                case "gateway": info.gateway = value
                default: break
                }
                continue
            }

            // The trailing table has no keys, only a header naming the columns:
            // "recvpipe sendpipe ssthresh rtt,msec rttvar hopcount mtu expire".
            // Reading `mtu` by header index keeps this working if Apple ever
            // reorders or inserts a column; a fixed position would silently
            // report the wrong number.
            let tokens = trimmed.split(whereSeparator: { $0 == " " }).map(String.init)
            if tokens.contains("mtu") {
                columns = tokens
                continue
            }
            if !columns.isEmpty, tokens.count == columns.count,
               let index = columns.firstIndex(of: "mtu"), let value = Int(tokens[index]) {
                info.mtu = value
            }
        }
        return info
    }

    /// Reads the system proxy/PAC state. Not used to configure anything — it
    /// is reported because a tunnel changes what every other number means.
    private static func systemProxy() async -> String? {
        guard let output = try? await OptimizeEngine.shell("/usr/sbin/scutil --proxy", timeout: 5)
        else { return nil }
        var pac: String?
        var httpEnabled = false
        var socksEnabled = false
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "ProxyAutoConfigURLString": pac = parts[1]
            case "HTTPEnable", "HTTPSEnable": httpEnabled = httpEnabled || parts[1] == "1"
            case "SOCKSEnable": socksEnabled = parts[1] == "1"
            default: break
            }
        }
        if let pac { return "PAC \(pac)" }
        if httpEnabled { return "HTTP proxy enabled" }
        if socksEnabled { return "SOCKS proxy enabled" }
        return nil
    }

    /// Fallback only: `networksetup` prints the MTU as a sentence rather than a
    /// table column, which makes it easier to parse but costs a process launch.
    /// The route parser handles the normal case, so this runs at most once per
    /// probe — and it is async, so a slow launch never blocks a cooperative
    /// thread while the rest of the probe waits on it.
    private static func interfaceMTU(_ interface: String) async -> Int? {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/sbin/networksetup -getMTU \(interface)", timeout: 5),
              let range = output.range(of: "Active MTU: ") else { return nil }
        let digits = output[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Snapshot of the parts of `NWPath` this tool reports. `NWPath` itself
    /// isn't `Sendable`, and carrying it across the monitor queue is exactly
    /// the kind of sharing Swift 6 rejects — so the handler reduces it to value
    /// types before anyone else sees it.
    struct PathSummary: Sendable {
        var kind: String
        var expensive: Bool
        var constrained: Bool
    }

    /// Event-driven wait for the first path update, with a hard ceiling.
    ///
    /// This used to poll a lock-protected box 20 times at 50ms. Polling works,
    /// but it bounds the wait at 1s and spends a scheduling slot on every tick;
    /// on a loaded machine the first callback can land later than that and the
    /// caller silently loses `interfaceKind` / `isExpensive`. A continuation
    /// resumes the instant the monitor fires and only falls back to the
    /// timeout when it never does.
    ///
    /// `ResumeGate` is not optional: `pathUpdateHandler` fires on every path
    /// change, and a second `resume()` on the same continuation is a crash.
    private static func currentPath(timeout: TimeInterval = 2) async -> PathSummary? {
        let monitor = NWPathMonitor()
        let gate = ResumeGate()
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<PathSummary?, Never>) in
            monitor.pathUpdateHandler = { path in
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: describe(path))
            }
            monitor.start(queue: DispatchQueue(label: "moppet.netprobe.path"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Single-shot gate: whoever gets there first wins, everyone else is a
    /// no-op. Shared by the path probe and any future async bridge.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Interface *types* only. Cost/constraint flags stay separate fields —
    /// folding them into the label made `kind` read "wifi,expensive", which is
    /// two different facts wearing one string.
    private static func describe(_ path: NWPath) -> PathSummary {
        var parts: [String] = []
        if path.usesInterfaceType(.wifi) { parts.append("wifi") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("wired") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular") }
        if path.usesInterfaceType(.other) { parts.append("other") }
        if path.usesInterfaceType(.loopback) { parts.append("loopback") }
        return PathSummary(kind: parts.isEmpty ? "unknown" : parts.joined(separator: ","),
                           expensive: path.isExpensive,
                           constrained: path.isConstrained)
    }

    private static func ipv4Address(of interface: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: current.pointee.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            return String(cString: host)
        }
        return nil
    }

    // MARK: - Helpers

    private static func stats(_ values: [Double]) -> StatsRow? {
        guard let s = NetworkEngine.Stats.of(values) else { return nil }
        return StatsRow(n: s.n, median: s.median, mad: s.mad, p95: s.p95)
    }

    private static func intValue(_ args: [String], _ flag: String) -> Int? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return Int(args[index + 1])
    }

    private static func stringValue(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

extension NetworkProbeCLI.Report {
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
