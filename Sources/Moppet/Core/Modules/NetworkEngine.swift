import Foundation
import Darwin
import Network

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
        let dns = coldDNSMilliseconds() ?? 0
        let tcp = ip.flatMap { tcpConnectMilliseconds(ip: $0) }
        let control = controlIP.flatMap {
            tcpConnectMilliseconds(ip: $0, countRefused: true)
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
    /// - **A fresh connection per stream.** Otherwise a CDN edge cache answers
    ///   from memory and the "speed" is the loopback.
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
                    await streamBytes(host: host, path: path,
                                      windowStart: windowStart, deadline: deadline,
                                      timeout: timeout, counter: counter)
                }
            }
            await group.waitForAll()
        }

        let steady = seconds - warmup
        let bytes = await counter.value
        guard steady > 0, bytes > 0 else { return nil }
        return Throughput(mbps: Double(bytes) * 8 / steady / 1_000_000,
                          bytes: bytes, seconds: steady, streams: streams,
                          endpoint: "https://\(host)\(path)")
    }

    /// One stream: connect, request, then count bytes until the deadline.
    ///
    /// This is a class rather than a local closure because the receive loop is
    /// recursive and gets called from three places (state handler, receive
    /// callback, timeout). Written as nested local functions, the compiler
    /// flags each of them as concurrently-executed and non-`@Sendable`.
    private final class StreamReader: @unchecked Sendable {
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Void, Never>
        private let counter: ByteCounter
        private let windowStart: Date
        private let deadline: Date
        private let host: String
        private let path: String
        private let lock = NSLock()
        private var finished = false

        init(connection: NWConnection, continuation: CheckedContinuation<Void, Never>,
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
            guard Date() < deadline else { finish(); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, isComplete, error in
                if let data, !data.isEmpty, Date() >= self.windowStart {
                    let count = data.count
                    Task { await self.counter.add(count) }
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
            continuation.resume()
        }
    }

    private static func streamBytes(host: String, path: String,
                                    windowStart: Date, deadline: Date,
                                    timeout: Double, counter: ByteCounter) async {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(
            tlsOptions.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        guard let port = NWEndpoint.Port(rawValue: 443) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reader = StreamReader(connection: connection, continuation: continuation,
                                      counter: counter, windowStart: windowStart,
                                      deadline: deadline, host: host, path: path)
            reader.start(on: DispatchQueue(label: "moppet.netprobe.stream"), timeout: timeout)
        }
    }

    private actor ByteCounter {
        private(set) var value: Int64 = 0
        func add(_ n: Int) { value += Int64(n) }
    }

    // MARK: - Statistics

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
