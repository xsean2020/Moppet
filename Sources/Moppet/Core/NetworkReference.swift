import Foundation

/// Reference frame for network measurements: the part that decides whether a
/// change *did* anything.
///
/// The whole module exists because "cleaned 3.2 GB" has a natural reference —
/// bytes are deterministic. Network numbers are not: the same host measured
/// twice a minute apart moves 20–40%, while a real optimisation moves 5–15%.
/// A single before/after pair therefore measures the weather, not the change.
///
/// Three references, each answering a different question:
/// - **paired (A/A)** — alternate A and B in the same window; the paired
///   difference cancels slow drift. Answers "did *this* change do anything".
/// - **control** — a measurement the change cannot touch (TCP to a fixed IP,
///   no DNS). Its drift is subtracted from the experiment's. Answers "or did
///   the network just get better on its own".
/// - **history** — a bucket of past runs for the same interface/hour. Answers
///   "is today worse than usual".
///
/// Everything here is pure except `NetworkSampleStore`, so the decision logic
/// can be asserted in `--smoke` without touching a socket.
enum NetworkReference {

    // MARK: - Verdict

    enum Verdict: String, Codable, Sendable {
        case improved
        case unchanged
        case regressed
        /// Not enough samples, or the control moved as much as the experiment.
        case inconclusive
    }

    struct MetricChange: Sendable {
        var metric: String
        var before: Double
        var after: Double
        /// Paired median difference, corrected for control drift.
        var delta: Double
        /// Robust sigma of the difference (1.4826 × MAD).
        var sigma: Double
        /// Minimum detectable difference at ~95%: 2.8σ/√n.
        var mdd: Double
        var n: Int
        var verdict: Verdict
    }

    /// Practical floor: a change must also clear this fraction of the baseline
    /// to be worth reporting. Below it the number is technically measurable but
    /// meaningless to a person ("improved by 0.4 ms").
    static let practicalFloor = 0.03

    /// Decide one metric. `lowerIsBetter` is true for every latency metric —
    /// all of them in this module are.
    ///
    /// Order matters: the sample-count check comes first, because with n < 5 a
    /// "significant" difference is usually one bad sample wearing a trend.
    static func verdict(delta: Double, sigma: Double, n: Int, baseline: Double,
                        lowerIsBetter: Bool = true, minimumSamples: Int = 5) -> Verdict {
        guard n >= minimumSamples, sigma.isFinite, sigma >= 0 else { return .inconclusive }
        let mdd = 2.8 * sigma / Double(n).squareRoot()
        guard abs(delta) > mdd else { return .unchanged }
        // Also require the change to clear the practical floor.
        guard baseline > 0, abs(delta) / baseline > practicalFloor else { return .unchanged }
        let gotBetter = lowerIsBetter ? delta < 0 : delta > 0
        return gotBetter ? .improved : .regressed
    }

    /// Robust sigma from median absolute deviation. MAD is used instead of the
    /// standard deviation because one 8-second stall should not be allowed to
    /// widen the noise band enough to hide a real 20% improvement.
    static func robustSigma(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let med = NetworkEngine.median(values.sorted())
        let deviations = values.map { abs($0 - med) }.sorted()
        return 1.4826 * NetworkEngine.median(deviations)
    }

    /// Paired comparison: one A sample and one B sample per round, measured
    /// back to back so both see the same network weather.
    static func paired(before: [Double], after: [Double],
                       controlBefore: [Double] = [], controlAfter: [Double] = [],
                       metric: String, minimumSamples: Int = 5) -> MetricChange? {
        let n = min(before.count, after.count)
        guard n > 0 else { return nil }
        let deltas = (0..<n).map { after[$0] - before[$0] }
        var delta = NetworkEngine.median(deltas.sorted())
        var sigma = robustSigma(deltas)

        // Control drift: whatever the untouched measurement did, the experiment
        // would have done anyway. Subtracting it is the difference between
        // "the network improved" and "my change improved it".
        if controlBefore.count >= n, controlAfter.count >= n {
            let controlDeltas = (0..<n).map { controlAfter[$0] - controlBefore[$0] }
            delta -= NetworkEngine.median(controlDeltas.sorted())
            // Uncertainty adds in quadrature; ignoring it would make the
            // corrected delta look more certain than either input.
            let controlSigma = robustSigma(controlDeltas)
            sigma = (sigma * sigma + controlSigma * controlSigma).squareRoot()
        }

        let baseline = NetworkEngine.median(before.sorted())
        return MetricChange(
            metric: metric,
            before: baseline,
            after: NetworkEngine.median(after.sorted()),
            delta: delta,
            sigma: sigma,
            mdd: 2.8 * sigma / Double(n).squareRoot(),
            n: n,
            verdict: verdict(delta: delta, sigma: sigma, n: n, baseline: baseline,
                             minimumSamples: minimumSamples)
        )
    }

    /// Unpaired comparison for changes that cannot be undone between rounds
    /// (editing a config is not something you flip back and forth). Weaker than
    /// the paired form, so the MDD is wider and it is labelled as such.
    static func unpaired(before: [Double], after: [Double],
                         metric: String, minimumSamples: Int = 5) -> MetricChange? {
        guard before.count >= 2, after.count >= 2 else { return nil }
        let beforeMedian = NetworkEngine.median(before.sorted())
        let afterMedian = NetworkEngine.median(after.sorted())
        let delta = afterMedian - beforeMedian
        // Conservative: take the noisier side rather than pooling, because the
        // two windows saw different weather by definition.
        let sigma = max(robustSigma(before), robustSigma(after))
        let n = min(before.count, after.count)
        let widened = 2.8 * sigma * (1.0 / Double(before.count)
                                     + 1.0 / Double(after.count)).squareRoot()
        return MetricChange(
            metric: metric,
            before: beforeMedian,
            after: afterMedian,
            delta: delta,
            sigma: sigma,
            mdd: widened,
            n: n,
            verdict: verdict(delta: delta, sigma: sigma, n: n, baseline: beforeMedian,
                             minimumSamples: minimumSamples)
        )
    }

    // MARK: - Stored samples (the historical reference)

    /// One run's medians for one host. Append-only, so history is never
    /// rewritten by a later reading.
    struct StoredSample: Codable, Sendable {
        var at: Date
        var interface: String
        var ssid: String?
        var hour: Int
        var host: String
        var dns: Double
        var tcp: Double
        var tls: Double
        var ttfb: Double
    }

    struct BucketStats: Sendable {
        var n: Int
        var ttfbMedian: Double
        var ttfbP10: Double
        var ttfbP90: Double
        var tlsMedian: Double
        var tcpMedian: Double
        var dnsMedian: Double
    }

    enum NetworkSampleStore {
        static var directory: URL {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".moppet", isDirectory: true)
                .appendingPathComponent("network", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return dir
        }

        static var fileURL: URL { directory.appendingPathComponent("samples.jsonl") }

        private static let lock = NSLock()

        static func append(_ sample: StoredSample) {
            lock.lock(); defer { lock.unlock() }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(sample),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            let url = fileURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
                // Measurements are not secrets, but they do reveal when the
                // machine is online — keep them owner-only like the rest.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
            }
        }

        static func load(limit: Int = 5000) -> [StoredSample] {
            lock.lock(); defer { lock.unlock() }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lines = text.split(separator: "\n").suffix(limit)
            return lines.compactMap { try? decoder.decode(StoredSample.self, from: Data($0.utf8)) }
        }

        /// History for the same interface and hour bucket. Deliberately narrow:
        /// pooling a 9am Wi-Fi run with a 9pm wired run produces a baseline that
        /// describes neither.
        static func bucket(interface: String, host: String, hour: Int,
                           minimumSamples: Int = 5) -> BucketStats? {
            let matching = load().filter {
                $0.interface == interface && $0.host == host && $0.hour == hour
            }
            guard matching.count >= minimumSamples else { return nil }
            let ttfb = matching.map(\.ttfb).sorted()
            let tls = matching.map(\.tls).sorted()
            let tcp = matching.map(\.tcp).sorted()
            let dns = matching.map(\.dns).sorted()
            return BucketStats(
                n: matching.count,
                ttfbMedian: NetworkEngine.median(ttfb),
                ttfbP10: NetworkEngine.percentile(ttfb, 0.10),
                ttfbP90: NetworkEngine.percentile(ttfb, 0.90),
                tlsMedian: NetworkEngine.median(tls),
                tcpMedian: NetworkEngine.median(tcp),
                dnsMedian: NetworkEngine.median(dns)
            )
        }
    }
}
