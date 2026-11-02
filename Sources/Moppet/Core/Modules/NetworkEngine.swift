import Foundation
import Darwin
import Network
import CoreWLAN

/// Network measurement kernel.
///
/// Everything here is *measurement*, not judgement: it produces numbers with
/// their sample counts and dispersion, and deliberately does not decide what
/// they mean. The rule engine consumes these; so does the `--net-probe` CLI.
/// Keeping them apart is what lets the CLI validate the measurement before any
/// UI exists.
///
/// **Why not URLSession for the phases.** It was the obvious choice —
/// `URLSessionTaskMetrics` hands you DNS/TCP/TLS/TTFB from one request. On a
/// machine with a system PAC proxy it also routes the request through the
/// tunnel, and the numbers become a measurement of the proxy: TCP reported
/// 1454ms while a direct `connect()` to the same IP took 1.0ms. Neither
/// `connectionProxyDictionary` nor unsetting `*_PROXY` changed it.
/// `Network.framework` never consults the system proxy, so these phases are
/// phases of the *network*. (URLSession is still used by the app itself — the
/// point is that a diagnostic must not measure the user's tunnel and call it
/// "your network".)
///
/// Other constraints, each learned from a measurement that lied:
/// - **Phases, never one number.** "Slow" is not actionable; "DNS 3ms, TCP 1ms,
///   TLS 2255ms" is.
/// - **Cold DNS.** A cached lookup returns in 0.1ms and hides a 96ms resolver.
///   Cold samples use a random label under `example.com` (guaranteed NXDOMAIN,
///   never cached) — the NXDOMAIN is irrelevant, the round trip is the point.
/// - **TCP measured against an IP**, so DNS never leaks into the handshake and
///   the two phases stay independently comparable.
/// - **Dispersion is part of the result.** A median without MAD invites reading
///   noise as signal, so every aggregate carries `n` and MAD.
enum NetworkEngine {

    // MARK: - Sample types

    /// One TLS + HTTP transaction, split into phases (milliseconds).
    struct PhaseSample: Sendable {
        var dns: Double?
        var tcp: Double?
        var tls: Double?
        var ttfb: Double?
        var total: Double
        var httpVersion: String?

        /// TLS ÷ TCP. The most useful derived number in this file: TLS 1.3 costs
        /// one round trip, so anything above ~4× means the handshake is being
        /// retried — loss on the path, not slow DNS and not low bandwidth.
        var handshakeAmplification: Double? {
            guard let tcp, let tls, tcp > 0, tls > 0 else { return nil }
            return tls / tcp
        }
    }

    /// Aggregated column: median plus dispersion. `n` is always reported — a
    /// median of one sample is an anecdote.
    struct Stats: Sendable {
        var n: Int
        var median: Double
        var mad: Double        // median absolute deviation
        var p95: Double

        static func of(_ values: [Double]) -> Stats? {
            let xs = values.filter { $0.isFinite && $0 >= 0 }.sorted()
            guard !xs.isEmpty else { return nil }
            // Qualify: inside `Stats`, a bare `median` resolves to the stored
            // property, not to NetworkEngine.median(_:).
            let med = NetworkEngine.median(xs)
            let deviations = xs.map { abs($0 - med) }
            return Stats(n: xs.count, median: med,
                         mad: NetworkEngine.median(deviations),
                         p95: NetworkEngine.percentile(xs, 0.95))
        }
    }

    // MARK: - TLS + first byte

    /// Full handshake and one HTTP/1.1 GET over `Network.framework`.
    ///
    /// ALPN is pinned to `http/1.1` on purpose: with h2 the server answers in
    /// binary frames and "time to first byte" stops meaning "time to the
    /// response head", which is the thing users actually feel.
    ///
    /// Returns `ready` = time from `start()` until the TLS session is usable
    /// (DNS + TCP + TLS), and `ttfb` = time from sending the request until the
    /// first response byte.
    ///
    /// `ready` deliberately includes TCP: the caller already measured the bare
    /// handshake with `tcpConnectMilliseconds`, and TLS is the difference of the
    /// two. Splitting them here would mean a second connection per sample.
    static func measureHandshake(host: String, port: UInt16 = 443, path: String = "/",
                                 timeout: Double = 20)
        async -> (ready: Double, ttfb: Double?, httpVersion: String?) {

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return (0, nil, nil) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let queue = DispatchQueue(label: "moppet.netprobe.tls")
        let start = DispatchTime.now().uptimeNanoseconds
        let state = Attempt()

        return await withCheckedContinuation { continuation in
            func finish(_ value: (Double, Double?, String?)) {
                guard state.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    state.readyAt = DispatchTime.now().uptimeNanoseconds
                    let request = "GET \(path) HTTP/1.1\r\n"
                        + "Host: \(host)\r\n"
                        + "User-Agent: MoppetProbe/1.0\r\n"
                        + "Accept: */*\r\n"
                        + "Connection: close\r\n\r\n"
                    state.sentAt = DispatchTime.now().uptimeNanoseconds
                    connection.send(content: Data(request.utf8),
                                    completion: .contentProcessed { _ in })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 96) {
                        data, _, _, error in
                        let now = DispatchTime.now().uptimeNanoseconds
                        guard error == nil, let data, !data.isEmpty else {
                            finish((state.readyMilliseconds(from: start), nil, nil))
                            return
                        }
                        let ttfb = Double(now - state.sentAt) / 1_000_000
                        finish((state.readyMilliseconds(from: start), ttfb, httpVersion(of: data)))
                    }
                case .failed, .cancelled:
                    finish((0, nil, nil))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish((0, nil, nil)) }
        }
    }

    /// Mutable per-attempt bookkeeping. `NWConnection`'s handlers run on its own
    /// queue while the `await` resumes elsewhere, so this needs the lock; the
    /// `claimed` flag is what stops a late timeout from resuming twice (which is
    /// a hard crash, not a warning).
    private final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        var readyAt: UInt64 = 0
        var sentAt: UInt64 = 0

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }

        func readyMilliseconds(from start: UInt64) -> Double {
            readyAt > start ? Double(readyAt - start) / 1_000_000 : 0
        }
    }

    private static func httpVersion(of data: Data) -> String? {
        guard let line = String(data: data, encoding: .utf8)?
            .split(separator: "\r\n").first else { return nil }
        if line.hasPrefix("HTTP/1.1") { return "h1.1" }
        if line.hasPrefix("HTTP/1.0") { return "h1.0" }
        return line.hasPrefix("HTTP/") ? "h1" : nil
    }

    // MARK: - DNS

    /// Resolver round trip for a name that cannot be cached.
    ///
    /// `getaddrinfo` on purpose: it is the exact path every app pays, including
    /// mDNSResponder. `dig` would query the resolver directly and quietly skip
    /// the system daemon that actually adds the latency.
    static func coldDNSMilliseconds() -> Double? {
        let label = "r" + UUID().uuidString.prefix(10).lowercased()
        return resolveMilliseconds(host: "\(label).example.com")
    }

    /// Timed `getaddrinfo`. Returns the duration even when resolution fails — a
    /// NXDOMAIN answered in 4ms is a perfectly good RTT sample.
    static func resolveMilliseconds(host: String) -> Double? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let start = DispatchTime.now().uptimeNanoseconds
        getaddrinfo(host, "443", &hints, &result)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if let result { freeaddrinfo(result) }
        // NXDOMAIN (EAI_NONAME) still consumed a resolver round trip; only a
        // zero-duration reading is meaningless.
        return elapsed > 0 ? elapsed : nil
    }

    /// First IPv4 address for a host, used to build the DNS-free control target.
    static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                          &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    // MARK: - TCP handshake

    /// Non-blocking `connect()` timed with the monotonic clock.
    ///
    /// Returns nil on timeout/refusal. A value landing near 1s, 3s or 7s is a
    /// SYN retransmission (exponential backoff) — which is why the caller keeps
    /// the raw samples and not just the median.
    /// `countRefused` keeps the timing of an actively refused connection: a
    /// RST still cost one round trip, which is exactly what a control probe on
    /// a host with no listener needs to report.
    static func tcpConnectMilliseconds(ip: String, port: UInt16 = 443,
                                       timeout: TimeInterval = 5,
                                       countRefused: Bool = false) -> Double? {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }

        let start = DispatchTime.now().uptimeNanoseconds
        let rc = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        guard errno == EINPROGRESS else { return nil }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return nil }
        if error == 0 { return elapsed }
        return (countRefused && error == ECONNREFUSED) ? elapsed : nil
    }

    /// Counts SYN retransmissions relative to the observed baseline.
    ///
    /// The first version compared against absolute 1s/3s/7s with a 25% window.
    /// That misreads a genuinely slow link: a normal 900ms connect sits inside
    /// "1s ± 25%". A retransmission is not an absolute time, it is **one extra
    /// RTO on top of the base RTT** — macOS starts at ~1s and doubles — so the
    /// steps are measured from the baseline, and the window is 15% of the step
    /// (150ms for the first), which still absorbs jitter.
    ///
    /// Baseline = fastest sample: retries can only add time, so the floor is
    /// the best estimate of the true handshake cost.
    static func synRetryCount(_ handshakes: [Double]) -> Int {
        guard let baseline = handshakes.min(), handshakes.count >= 3 else { return 0 }
        let steps = [1000.0, 3000.0, 7000.0]
        return handshakes.filter { sample in
            steps.contains { step in
                abs(sample - (baseline + step)) < step * 0.15
            }
        }.count
    }

    // MARK: - One measurement round

    // Async bridges for the blocking probes below. `getaddrinfo` and
    // `connect(2)` have no cancellation and can block for seconds (DNS alone
    // up to 30s). On the cooperative pool that stalls every other task in the
    // process — tolerable in the headless CLI, unacceptable once an MCP tool
    // calls this from the app — so the async path hops to the global queue.

    static func coldDNSMillisecondsAsync() async -> Double? {
        await Task.detached(priority: .utility) { Self.coldDNSMilliseconds() }.value
    }

    static func resolveMillisecondsAsync(host: String) async -> Double? {
        await Task.detached(priority: .utility) { Self.resolveMilliseconds(host: host) }.value
    }

    static func resolveIPv4Async(_ host: String) async -> String? {
        await Task.detached(priority: .utility) { Self.resolveIPv4(host) }.value
    }

    static func tcpConnectMillisecondsAsync(ip: String, port: UInt16 = 443,
                                            timeout: TimeInterval = 5,
                                            countRefused: Bool = false) async -> Double? {
        await Task.detached(priority: .utility) {
            Self.tcpConnectMilliseconds(ip: ip, port: port, timeout: timeout,
                                        countRefused: countRefused)
        }.value
    }

    /// One round of every metric, measured back to back so a pair sees the
    /// same network weather. Shared by `--net-probe --compare` and the
    /// optimiser's before/after loop.
    struct RoundSample: Sendable {
        var dns: Double
        var tcp: Double
        var tls: Double
        var ttfb: Double
        var control: Double
    }

    /// `controlIP` should be something the change under test cannot touch
    /// (the gateway: no DNS, no WAN). Pass nil to skip the control.
    static func sampleRound(host: String, ip: String?,
                            controlIP: String?) async -> RoundSample? {
        // Cold DNS per round: the resolver caches after the first lookup, so a
        // warm reading would report 0.1ms no matter what DNS server is set —
        // and DNS is precisely what a resolver change targets.
        let dns = await coldDNSMillisecondsAsync() ?? 0
        var tcp: Double?
        if let ip { tcp = await tcpConnectMillisecondsAsync(ip: ip) }
        var control: Double?
        if let controlIP {
            control = await tcpConnectMillisecondsAsync(ip: controlIP, countRefused: true)
        }
        let (ready, ttfb, _) = await measureHandshake(host: host)
        guard ready > 0, let ttfb, let tcp else { return nil }
        return RoundSample(dns: dns, tcp: tcp, tls: max(0, ready - tcp),
                           ttfb: ttfb, control: control ?? 0)
    }

    // MARK: - Throughput

    struct Throughput: Sendable {
        var mbps: Double
        var bytes: Int64
        var seconds: Double
        var streams: Int
        var endpoint: String
    }

    /// Multi-stream download over `Network.framework`, steady-state only.
    ///
    /// Three rules, each fixing a way the naive version lies:
    /// - **4–8 streams.** One stream is bounded by its congestion window and
    ///   reports 30–50% below link capacity.
    /// - **Discard the warm-up.** TCP slow start makes the first 1–2s
    ///   unrepresentative; only bytes arriving after `warmup` count.
    /// - **A fresh connection and a unique URL per request, repeated until the
    ///   deadline.** The first version sent one request per stream: a 2MB file
    ///   on a 100 Mbps link finished inside the warm-up, and dividing its
    ///   bytes by the nominal 6.5s window reported ~2 Mbps. Looping keeps the
    ///   pipe full for the whole window and defeats edge caches.
    ///
    /// The rate divides by the window the bytes actually covered, not the
    /// nominal one, so an early-ending endpoint still reports honestly.
    static func measureDownload(host: String, path: String, streams: Int = 4,
                                seconds: Double = 8, warmup: Double = 1.5,
                                timeout: Double = 30) async -> Throughput? {
        let start = Date()
        let windowStart = start.addingTimeInterval(warmup)
        let deadline = start.addingTimeInterval(seconds)
        let counter = ByteCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    await streamRequests(host: host, path: path,
                                         windowStart: windowStart, deadline: deadline,
                                         timeout: timeout, counter: counter)
                }
            }
            await group.waitForAll()
        }

        guard let window = counter.window(from: windowStart, closingAt: deadline),
              let bytes = counter.bytes, bytes > 0 else { return nil }
        return Throughput(mbps: Double(bytes) * 8 / window / 1_000_000,
                          bytes: bytes, seconds: window, streams: streams,
                          endpoint: "https://\(host)\(path)")
    }

    /// One stream = repeated requests until the deadline, a fresh connection
    /// each time. Returns after the first request that fails to start (a
    /// refused or reset connection will not improve by hammering it).
    private static func streamRequests(host: String, path: String,
                                       windowStart: Date, deadline: Date,
                                       timeout: Double, counter: ByteCounter) async {
        while Date() < deadline {
            // Unique query parameter per request: a CDN answering the second
            // identical GET from edge cache is measuring its memory.
            let separator = path.contains("?") ? "&" : "?"
            let unique = path + separator + "r=" + UUID().uuidString.prefix(8).lowercased()
            let progressed = await StreamReader.run(host: host, path: unique,
                                                    windowStart: windowStart,
                                                    deadline: deadline,
                                                    timeout: timeout, counter: counter)
            if !progressed { return }
        }
    }

    /// One request over a fresh connection: connect, send, receive until the
    /// response completes, the deadline, or a failure.
    ///
    /// This is a class rather than a local closure because the receive loop is
    /// recursive and gets called from three places (state handler, receive
    /// callback, timeout). Written as nested local functions, the compiler
    /// flags each of them as concurrently-executed and non-`@Sendable`.
    private final class StreamReader: @unchecked Sendable {
        /// `true` = the link moved at least one byte (the request completed,
        /// or the deadline cut it mid-stream); `false` = the connection failed
        /// before any byte arrived, so the caller's request loop should stop.
        static func run(host: String, path: String, windowStart: Date, deadline: Date,
                        timeout: Double, counter: ByteCounter) async -> Bool {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(
                tlsOptions.securityProtocolOptions, "http/1.1")
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            guard let port = NWEndpoint.Port(rawValue: 443) else { return false }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port,
                                          using: parameters)

            return await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                let reader = StreamReader(connection: connection,
                                          continuation: continuation,
                                          counter: counter, windowStart: windowStart,
                                          deadline: deadline, host: host, path: path)
                reader.start(on: DispatchQueue(label: "moppet.netprobe.stream"),
                             timeout: timeout)
            }
        }

        private let connection: NWConnection
        private let continuation: CheckedContinuation<Bool, Never>
        private let counter: ByteCounter
        private let windowStart: Date
        private let deadline: Date
        private let host: String
        private let path: String
        private let lock = NSLock()
        private var finished = false
        /// Any byte at all — including warm-up bytes outside the counting
        /// window. A request that completes entirely during warm-up still
        /// proves the link works and the next request is worth making.
        private var receivedAny = false

        init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>,
             counter: ByteCounter, windowStart: Date, deadline: Date,
             host: String, path: String) {
            self.connection = connection
            self.continuation = continuation
            self.counter = counter
            self.windowStart = windowStart
            self.deadline = deadline
            self.host = host
            self.path = path
        }

        func start(on queue: DispatchQueue, timeout: Double) {
            // Strong captures on purpose: the only owner of this reader is the
            // connection's own handlers, so `[weak self]` would deallocate it
            // the moment the continuation closure returns — the handlers would
            // then do nothing and the continuation would never resume (a hang,
            // not a leak). `finish()` nils the handler to break the cycle.
            connection.stateUpdateHandler = { update in
                switch update {
                case .ready: self.send()
                case .failed: self.finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { self.finish() }
        }

        private func send() {
            let request = "GET \(path) HTTP/1.1\r\n"
                + "Host: \(host)\r\n"
                + "User-Agent: MoppetProbe/1.0\r\n"
                + "Accept: */*\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            receiveNext()
        }

        private func receiveNext() {
            // No deadline guard here on purpose: a request whose handshake is
            // still in flight when the window closes must run to completion
            // (its own timeout bounds it). Aborting mid-handshake made the
            // whole measurement give up on links where TLS alone outlasts the
            // window. Bytes outside [windowStart, deadline) are simply not
            // counted, so the rate stays honest.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    self.receivedAny = true
                    let now = Date()
                    if now >= self.windowStart, now < self.deadline {
                        // Synchronous add: this callback is not async, and a
                        // spawned Task could race the continuation that ends
                        // the measurement — the final chunks would land after
                        // the rate was computed (observed as an empty result).
                        self.counter.add(data.count, at: now)
                    }
                }
                if error != nil || isComplete { self.finish() } else { self.receiveNext() }
            }
        }

        func finish() {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            lock.unlock()
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(returning: receivedAny)
        }
    }

    /// Bytes counted, with when the last one landed — the window the rate
    /// divides by is what the bytes actually covered, not the nominal plan.
    /// A lock, not an actor: the add comes from NWConnection's receive
    /// callback, which is not async, and a spawned `Task` could race the
    /// continuation that ends the measurement (reads could miss final chunks).
    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        private var lastCountedAt: Date?

        func add(_ n: Int, at date: Date) {
            lock.lock(); defer { lock.unlock() }
            value += Int64(n)
            lastCountedAt = date
        }

        func window(from windowStart: Date, closingAt deadline: Date) -> Double? {
            lock.lock(); defer { lock.unlock() }
            guard let last = lastCountedAt else { return nil }
            return max(0.001, min(last, deadline).timeIntervalSince(windowStart))
        }

        var bytes: Int64? {
            lock.lock(); defer { lock.unlock() }
            return value > 0 ? value : nil
        }
    }

    // MARK: - L5 per-process flows (nettop)

    /// Per-process traffic delta over one sampling interval.
    struct ProcFlow: Sendable, Codable {
        var name: String
        var pid: Int
        var bytesIn: Int64
        var bytesOut: Int64

        var totalBytes: Int64 { bytesIn + bytesOut }
    }

    /// Pure parser for `nettop -P -L 1 -x -J bytes_in,bytes_out`.
    ///
    /// **macOS 26 reality check:** the design doc assumed `-L` emits JSON; on
    /// this machine it emits CSV (verified live):
    ///
    ///     ,bytes_in,bytes_out,
    ///     kernel_task.0,84567535382,237963299772,
    ///     remoted.129,9061717,12635831,
    ///
    /// Columns are located by header name, not position. Process names may
    /// carry dots (`com.apple.WebKit.Networking.1234`) — the pid is everything
    /// after the LAST dot. Duplicate `name.pid` rows (one per interface) are
    /// summed. Counters are cumulative since boot, so the caller subtracts
    /// two snapshots to get interval traffic.
    static func parseNettopCSV(_ output: String) -> [ProcFlow] {
        var columns: [String] = []
        var flows: [String: ProcFlow] = [:]
        for raw in output.split(separator: "\n") {
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            guard !fields.isEmpty else { continue }
            // Header rows start with an empty field (the process column).
            if fields[0].isEmpty {
                columns = fields
                continue
            }
            guard !columns.isEmpty, fields.count > 1 else { continue }
            let key = fields[0]
            guard let lastDot = key.lastIndex(of: ".") else { continue }
            let name = String(key[key.startIndex..<lastDot])
            let pid = Int(String(key[key.index(after: lastDot)...])) ?? -1
            guard !name.isEmpty else { continue }
            // Out-of-range or unparseable numbers → treat as 0, the row still
            // exists so the delta against a later snapshot stays balanced.
            func count(_ column: String) -> Int64 {
                guard let index = columns.firstIndex(of: column),
                      index < fields.count, let value = Int64(fields[index])
                else { return 0 }
                return value
            }
            let flow = ProcFlow(name: name, pid: pid,
                                bytesIn: count("bytes_in"), bytesOut: count("bytes_out"))
            flows[key, default: ProcFlow(name: name, pid: pid, bytesIn: 0, bytesOut: 0)].bytesIn += flow.bytesIn
            flows[key]?.bytesOut += flow.bytesOut
        }
        return flows.values.sorted { $0.totalBytes > $1.totalBytes }
    }

    /// One cumulative snapshot of per-process byte counters.
    static func procFlowSnapshot() async -> [ProcFlow]? {
        guard let output = try? await OptimizeEngine.shell(
            "/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out", timeout: 30)
        else { return nil }
        let flows = parseNettopCSV(output)
        return flows.isEmpty ? nil : flows
    }

    /// Interval traffic per process: two cumulative snapshots, subtracted.
    /// This is the only way to answer "what is eating the uplink *right now*"
    /// — `nettop` counters alone say nothing about the present.
    static func procFlowDeltas(interval: TimeInterval = 5) async -> [ProcFlow]? {
        guard let first = await procFlowSnapshot() else { return nil }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard let second = await procFlowSnapshot() else { return nil }
        var before: [String: ProcFlow] = [:]
        for flow in first { before["\(flow.name).\(flow.pid)"] = flow }
        var deltas: [ProcFlow] = []
        for flow in second {
            guard let previous = before["\(flow.name).\(flow.pid)"] else { continue }
            let inDelta = flow.bytesIn - previous.bytesIn
            let outDelta = flow.bytesOut - previous.bytesOut
            // A negative value means the counter was reset (restart) — not
            // traffic; skip rather than report a phantom download.
            guard inDelta >= 0, outDelta >= 0, inDelta > 0 || outDelta > 0 else { continue }
            deltas.append(ProcFlow(name: flow.name, pid: flow.pid,
                                   bytesIn: inDelta, bytesOut: outDelta))
        }
        return deltas.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: - Wi-Fi snapshot (CoreWLAN)

    struct WiFiInfo: Sendable, Codable {
        var interface: String?
        /// nil without location permission on macOS 14+ — degrade to "current
        /// network" (design §7); RSSI/noise/channel need no permission.
        var ssid: String?
        var rssi: Int?
        var noise: Int?
        var channel: Int?
        var band5GHz: Bool?
        var txRate: Double?
    }

    /// Read-only Wi-Fi quality snapshot. Never configures anything.
    static func wifiSnapshot() async -> WiFiInfo? {
        let info: WiFiInfo? = await Task.detached(priority: .utility) { () -> WiFiInfo? in
            guard let iface = CWWiFiClient.shared().interface() else { return nil }
            let channel = iface.wlanChannel()?.channelNumber
            return WiFiInfo(
                interface: iface.interfaceName,
                ssid: iface.ssid(),
                // rssiValue()/noiseMeasurement() are methods, not properties —
                // and a fresh interface can answer 0, which means "unknown",
                // not "perfect signal".
                rssi: { let v = iface.rssiValue(); return v < 0 ? v : nil }(),
                noise: { let v = iface.noiseMeasurement(); return v <= 0 ? v : nil }(),
                channel: channel,
                // CWChannelBand's Swift-imported case names don't compile as
                // documented; the channel number is the reliable band signal
                // for display (>14 = 5/6 GHz).
                band5GHz: channel.map { $0 > 14 },
                txRate: { let v = iface.transmitRate(); return v > 0 ? v : nil }())
        }.value
        return info
    }

    // MARK: - L4 app-path probe (URLSessionTaskMetrics)

    /// One request measured the way apps actually make it — through
    /// URLSession, which DOES consult the system proxy/PAC. Deliberately
    /// different from `measureHandshake` (Network.framework, proxy-free):
    /// the *difference* between the two is what the tunnel costs.
    struct AppPathProbe: Sendable, Codable {
        var host: String
        var dnsMs: Double?
        var tcpMs: Double?
        var tlsMs: Double?
        var ttfbMs: Double?
        /// True when the system proxy carried the request (expected with a
        /// PAC configured — this is the "what the tunnel adds" signal).
        var proxy: Bool
        var reused: Bool
        var protocolName: String?
        var seconds: Double
    }

    /// Pure extraction from the metric's date pairs — smoke-testable without
    /// constructing (unconstructible) URLSessionTaskMetric instances.
    static func appPhases(lookupStart: Date?, lookupEnd: Date?,
                          connectStart: Date?, connectEnd: Date?,
                          secureStart: Date?, secureEnd: Date?,
                          requestStart: Date?, responseStart: Date?)
        -> (dns: Double?, tcp: Double?, tls: Double?, ttfb: Double?) {
        func ms(_ a: Date?, _ b: Date?) -> Double? {
            guard let a, let b else { return nil }
            let value = b.timeIntervalSince(a) * 1000
            return value.isFinite && value >= 0 ? value : nil
        }
        return (ms(lookupStart, lookupEnd), ms(connectStart, connectEnd),
                ms(secureStart, secureEnd), ms(requestStart, responseStart))
    }

    static func appPathProbe(host: String, timeout: TimeInterval = 15) async -> AppPathProbe? {
        // URLSessionTaskMetrics is not Sendable, so the delegate reduces it to
        // a Sendable value tuple ON the delegate queue before anything hops.
        final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            struct Reduced: Sendable {
                var lookupStart: Date?, lookupEnd: Date?
                var connectStart: Date?, connectEnd: Date?
                var secureStart: Date?, secureEnd: Date?
                var requestStart: Date?, responseStart: Date?
                var proxy: Bool, reused: Bool
                var proto: String?
            }
            let onMetrics: @Sendable (Reduced) -> Void
            init(onMetrics: @escaping @Sendable (Reduced) -> Void) { self.onMetrics = onMetrics }

            func urlSession(_ session: URLSession, task: URLSessionTask,
                            didFinishCollecting metrics: URLSessionTaskMetrics) {
                guard let t = metrics.transactionMetrics.last else { return }
                onMetrics(Reduced(
                    lookupStart: t.domainLookupStartDate, lookupEnd: t.domainLookupEndDate,
                    connectStart: t.connectStartDate, connectEnd: t.connectEndDate,
                    secureStart: t.secureConnectionStartDate, secureEnd: t.secureConnectionEndDate,
                    requestStart: t.requestStartDate, responseStart: t.responseStartDate,
                    proxy: t.isProxyConnection, reused: t.isReusedConnection,
                    proto: t.networkProtocolName))
            }
        }

        let start = Date()
        // Single-shot gate: whichever of the three paths lands first resumes;
        // everyone else is a no-op (same shape as the probe's ResumeGate).
        let gate = ProbeGate()
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<AppPathProbe?, Never>) in
            // Called from three escaping closures — the @Sendable marking is
            // what keeps Swift 6 mode happy; the gate makes double-resume a
            // no-op rather than a crash.
            @Sendable func complete(_ probe: AppPathProbe?) {
                guard gate.claim() else { return }
                continuation.resume(returning: probe)
            }

            let cfg = URLSessionConfiguration.ephemeral
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = timeout
            let delegate = Collector { reduced in
                let phases = appPhases(lookupStart: reduced.lookupStart,
                                       lookupEnd: reduced.lookupEnd,
                                       connectStart: reduced.connectStart,
                                       connectEnd: reduced.connectEnd,
                                       secureStart: reduced.secureStart,
                                       secureEnd: reduced.secureEnd,
                                       requestStart: reduced.requestStart,
                                       responseStart: reduced.responseStart)
                complete(AppPathProbe(
                    host: host, dnsMs: phases.dns, tcpMs: phases.tcp,
                    tlsMs: phases.tls, ttfbMs: phases.ttfb,
                    proxy: reduced.proxy, reused: reduced.reused,
                    protocolName: reduced.proto,
                    seconds: Date().timeIntervalSince(start)))
            }
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: URL(string: "https://\(host)/")!)
            request.timeoutInterval = timeout
            let task = session.dataTask(with: request) { _, _, _ in
                // didFinishCollecting fires before the completion handler, so
                // this only wins when the task failed with no metrics at all.
                complete(nil)
            }
            task.resume()
            // Holds the session (and with it the delegate and task) alive for
            // the whole flight; also the hard ceiling if neither path fires.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
                _ = session
                complete(nil)
            }
        }
    }

    /// Single-shot claim gate shared by the app-path probe's three finishers.
    private final class ProbeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
