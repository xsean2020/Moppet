import Foundation

/// P4 — the weekly network checkup: a LaunchAgent that runs `--net-report`
/// and nothing else.
///
/// Two hard rules, straight from the design's P4 acceptance gate:
/// - **The checkup never writes network configuration.** It is the same
///   read-only measurement pass `--net-probe` uses; the only bytes it puts on
///   disk are its own samples (the history baseline the trend reads) and the
///   log launchd captures. DNS, PAC and MTU are untouched — a scheduled task
///   with nobody watching must not decide to edit them.
/// - **The report answers "is today worse than usual", not "run a fix".** It
///   prints findings and a trend; actions stay interactive (`--net-fix`).
///
///     Moppet --net-checkup status
///     Moppet --net-checkup install      # weekly, Sunday 09:00 by default
///     Moppet --net-checkup uninstall
///     Moppet --net-report               # what the agent runs
///     Moppet --net-trend                # sample history by day
enum NetworkCheckup {

    static let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.moppet.netcheckup.plist")
    static let label = "com.moppet.netcheckup"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/moppet-net-checkup.log")

    // MARK: - Plist generation (pure, smoke-tested)

    /// launchd rejects JSON and wants XML (see Scheduler for the same trap);
    /// values are clamped so a bad UI value cannot corrupt the plist.
    static func plistXML(executablePath: String, weekday: Int, hour: Int) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Launchd.xmlEscaped(executablePath))</string>
                <string>--net-report</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Weekday</key><integer>\(max(1, min(weekday, 7)))</integer>
                <key>Hour</key><integer>\(max(0, min(hour, 23)))</integer>
                <key>Minute</key><integer>0</integer>
            </dict>
            <key>StandardOutPath</key><string>\(Launchd.xmlEscaped(logURL.path))</string>
            <key>StandardErrorPath</key><string>\(Launchd.xmlEscaped(logURL.path))</string>
        </dict>
        </plist>
        """
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install(weekday: Int = 1, hour: Int = 9) async throws {
        guard let executable = Bundle.main.executableURL?.path,
              executable.hasPrefix("/") else {
            throw NSError(domain: "netcheckup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "cannot determine the app binary path"])
        }
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plistXML(executablePath: executable, weekday: weekday, hour: hour)
            .write(to: plistURL, atomically: true, encoding: .utf8)
        // bootout ignores "not loaded"; bootstrap must succeed or the caller
        // sees why (same contract as Scheduler.install).
        await Launchd.bootout(label)
        try await Launchd.bootstrap(label, plistURL: plistURL)
    }

    static func uninstall() async {
        await Launchd.bootout(label)
        try? FileManager.default.removeItem(at: plistURL)
    }

    static func status() async -> String {
        guard isInstalled else { return "not installed (\(plistURL.path) missing)" }
        let uid = getuid()
        let loaded = (try? await OptimizeEngine.shell(
            "launchctl print gui/\(uid)/\(label) 2>/dev/null", timeout: 10))?
            .contains("state =") ?? false
        return "installed (\(plistURL.path))\(loaded ? " · loaded" : " · plist present, not loaded")"
    }
}

// MARK: - Trend (pure, smoke-tested)

extension NetworkReference {

    struct DayTrend: Codable, Sendable {
        var day: String          // yyyy-MM-dd, local calendar
        var n: Int
        var ttfbP50: Double
        var tlsP50: Double
        var tcpP50: Double
        var dnsP50: Double
    }

    /// Daily medians for one host over the trailing `days` days. Pure: the
    /// caller owns loading `NetworkSampleStore`. Host is a filter, not a
    /// guess — pooling hosts makes a trend that describes nothing.
    static func dailyTrend(from samples: [StoredSample], host: String?,
                           days: Int = 14) -> [DayTrend] {
        // Most-sampled host when unspecified: a trend for "whatever came last"
        // would mix hosts without saying so.
        let chosen = host ?? Dictionary(grouping: samples, by: \.host)
            .max { $0.value.count < $1.value.count }?.key
        guard let chosen else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var byDay: [String: [StoredSample]] = [:]
        for sample in samples where sample.host == chosen {
            byDay[formatter.string(from: sample.at), default: []].append(sample)
        }
        return byDay
            .map { day, group in
                let ttfb = group.map(\.ttfb).sorted()
                let tls = group.map(\.tls).sorted()
                let tcp = group.map(\.tcp).sorted()
                let dns = group.map(\.dns).sorted()
                return DayTrend(
                    day: day, n: group.count,
                    ttfbP50: NetworkEngine.median(ttfb),
                    tlsP50: NetworkEngine.median(tls),
                    tcpP50: NetworkEngine.median(tcp),
                    dnsP50: NetworkEngine.median(dns))
            }
            .sorted { $0.day > $1.day }   // newest first
            .prefix(days)
            .map { $0 }    }
}

// MARK: - CLI entries (--net-report / --net-trend / --net-checkup)

extension NetworkProbeCLI {

    /// One checkup pass: probe → trend → findings, printed. The LaunchAgent's
    /// StandardOutPath captures this into the checkup log; interactive runs
    /// see the same text. Writes nothing but its own samples.
    static func runReport() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            // Same defaults as the interactive probe; `record` stays on —
            // accumulating the baseline is the whole point of a checkup.
            let report = await collect(
                hosts: ["speed.cloudflare.com", "www.apple.com", "www.baidu.com"],
                samples: 5, throughput: false, record: true)
            var text = render(report, requestedThroughput: false)

            // The trend reads the sample store: pick the most-sampled host
            // explicitly so the label always names what the table shows.
            let samples = NetworkReference.NetworkSampleStore.load()
            let trendHost = Dictionary(grouping: samples, by: \.host)
                .max { $0.value.count < $1.value.count }?.key
            let trend = NetworkReference.dailyTrend(from: samples, host: trendHost)
            if !trend.isEmpty {
                text += "\n\n"
                text += "trend · daily medians · host \(trendHost ?? "?") · last \(trend.count) days"
                text += "\n" + pad("day", 12) + pad("n", 6) + pad("ttfb p50", 11)
                    + pad("tls p50", 11) + pad("tcp p50", 11) + "dns p50"
                text += "\n" + String(repeating: "─", count: 64)
                for day in trend {
                    text += "\n" + pad(day.day, 12) + pad("\(day.n)", 6)
                        + pad(fmt(day.ttfbP50), 11) + pad(fmt(day.tlsP50), 11)
                        + pad(fmt(day.tcpP50), 11) + fmt(day.dnsP50)
                }
            }
            print(text)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// The sample history as a table — the textual precursor to the GUI trend
    /// chart (design §5/P4). Read-only; never touches the network.
    static func runTrend() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        let host = CLIArgs.string(args, "--hosts")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.first
        let samples = NetworkReference.NetworkSampleStore.load()
        guard !samples.isEmpty else {
            print("no samples yet — run Moppet --net-probe a few times first "
                  + "(\(NetworkReference.NetworkSampleStore.fileURL.path))")
            exit(0)
        }
        let trend = NetworkReference.dailyTrend(from: samples, host: host)
        guard !trend.isEmpty else {
            print("no samples for host '\(host ?? "?")' — "
                  + "available: \(Set(samples.map(\.host)).sorted().joined(separator: ", "))")
            exit(0)
        }
        var lines: [String] = []
        lines.append("Moppet network trend · daily medians · host \(host ?? "(most sampled)")")
        lines.append(pad("day", 12) + pad("n", 6) + pad("ttfb p50", 11)
                     + pad("tls p50", 11) + pad("tcp p50", 11) + "dns p50")
        lines.append(String(repeating: "─", count: 64))
        for day in trend {
            lines.append(pad(day.day, 12) + pad("\(day.n)", 6)
                         + pad(fmt(day.ttfbP50), 11) + pad(fmt(day.tlsP50), 11)
                         + pad(fmt(day.tcpP50), 11) + fmt(day.dnsP50))
        }
        lines.append("")
        lines.append("source: \(NetworkReference.NetworkSampleStore.fileURL.path) "
                     + "(\(samples.count) samples)")
        print(lines.joined(separator: "\n"))
        exit(0)
    }

}

// MARK: - --net-checkup (install / uninstall / status)

enum NetworkCheckupCLI {
    static func run() -> Never {
        let args = CommandLine.arguments
        let sub = CLIArgs.string(args, "--net-checkup") ?? "status"
        let weekday = CLIArgs.int(args, "--weekday") ?? 1
        let hour = CLIArgs.int(args, "--hour") ?? 9
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            switch sub {
            case "install":
                do {
                    try await NetworkCheckup.install(weekday: weekday, hour: hour)
                    print("installed: weekly checkup (weekday \(weekday), \(hour):00) → "
                          + NetworkCheckup.logURL.path)
                } catch {
                    FileHandle.standardError.write(Data(
                        "error: install failed — \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            case "uninstall":
                await NetworkCheckup.uninstall()
                print("uninstalled (plist removed, agent booted out)")
            default:
                print(await NetworkCheckup.status())
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
