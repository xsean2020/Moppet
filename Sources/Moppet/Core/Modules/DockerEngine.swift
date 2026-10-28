import Foundation

/// Docker disk usage reporter + pruner.
///
/// Docker's VM disk image (`Docker.raw` / `vms` in the VM runtime folder)
/// regularly holds tens of GB of unused images, stopped containers and build
/// cache that no file-level cleaner can reclaim. `docker system df` reports
/// it; `docker system prune -f` reclaims stopped containers, unused networks,
/// dangling images and build cache. It never touches running containers or
/// named volumes (those need an explicit `--volumes`, which this engine
/// deliberately does not pass — volume data is user data).
enum DockerEngine {

    struct Usage: Equatable {
        var imagesCount = 0
        var imagesBytes: Int64 = 0
        var containersCount = 0
        var containersBytes: Int64 = 0
        var volumesCount = 0
        var volumesBytes: Int64 = 0
        var cacheCount = 0
        var cacheBytes: Int64 = 0

        var totalBytes: Int64 { imagesBytes + containersBytes + volumesBytes + cacheBytes }
    }

    static var installed: Bool {
        // `which docker` through the shell every scan is slow; probe the
        // standard install points first (Docker Desktop, Homebrew, path).
        for candidate in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                          "/Applications/Docker.app/Contents/Resources/bin/docker"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return true }
        }
        return whichDocker() != nil
    }

    private static func whichDocker() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["docker"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// Prefers the Homebrew/Docker Desktop binary when the user's PATH (from
    /// launchd, not the shell profile) does not carry it.
    private static func dockerBin() -> String {
        whichDocker()
            ?? ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "docker"
    }

    // MARK: - df parsing (pure, smoke-tested)

    /// Parses `docker system df --format json` — NDJSON, one object per line.
    ///
    /// REAL shape (verified against Docker Desktop's output — the parser must
    /// handle exactly this):
    /// ```
    /// {"Active":"2","Reclaimable":"2.323GB (59%)","Size":"3.918GB",
    ///  "TotalCount":"3","Type":"Images"}
    /// {"Type":"Local Volumes", …} {"Type":"Build Cache", …}
    /// ```
    /// Types are Capitalized (with spaces in "Local Volumes"/"Build Cache"),
    /// counts are STRING numbers, sizes are human strings. Older builds emit
    /// lowercase types / numeric values / different count keys — all accepted.
    static func parseDFJSONL(_ output: String) -> Usage {
        var usage = Usage()
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawType = obj["Type"] as? String else { continue }
            let type = rawType.lowercased()
            let count = intValue(obj, ["TotalCount", "Count", "Images", "Containers",
                                       "Volumes", "BuildCache"])
            let bytes = bytesValue(obj["Size"])
            switch type {
            case "images": usage.imagesCount = count; usage.imagesBytes = bytes
            case "containers": usage.containersCount = count; usage.containersBytes = bytes
            case "local volumes", "volumes": usage.volumesCount = count; usage.volumesBytes = bytes
            case "build cache", "build-cache": usage.cacheCount = count; usage.cacheBytes = bytes
            default: break
            }
        }
        return usage
    }

    /// First key that carries a usable integer — string numbers included.
    private static func intValue(_ obj: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            guard let raw = obj[key] else { continue }
            if let n = raw as? Int { return n }
            if let n = raw as? NSNumber { return n.intValue }
            if let s = raw as? String, let n = Int(s.replacingOccurrences(of: ",", with: "")) {
                return n
            }
        }
        return 0
    }

    /// Size arrives as a human string ("3.918GB", "0B") or a raw number.
    private static func bytesValue(_ raw: Any?) -> Int64 {
        if let n = raw as? NSNumber { return n.int64Value }
        guard let s = raw as? String else { return 0 }
        return parseHumanBytes(s)
    }

    /// Docker human sizes: decimal units, lowercase kB possible ("131.1kB"),
    /// optional " (59%)" suffixes and thousand separators. Case-insensitive.
    static func parseHumanBytes(_ input: String) -> Int64 {
        var token = input.trimmingCharacters(in: .whitespaces)
        if let paren = token.firstIndex(of: "(") { token = String(token[..<paren]) }
        token = token.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
        let units: [(suffixes: [String], multiplier: Int64)] = [
            (["tb"], 1_000_000_000_000),
            (["gb"], 1_000_000_000),
            (["mb"], 1_000_000),
            (["kb", "kib"], 1_000),
            (["b"], 1),
        ]
        let lower = token.lowercased()
        for (suffixes, multiplier) in units {
            for suffix in suffixes where lower.hasSuffix(suffix) {
                let numberPart = lower.dropLast(suffix.count)
                    .trimmingCharacters(in: .whitespaces)
                guard let value = Double(numberPart) else { return 0 }
                return Int64((value * Double(multiplier)).rounded())
            }
        }
        // Bare number → bytes (legacy API shapes emit raw integers).
        return Int64(Double(token) ?? 0)
    }

    static func usage() async -> Usage? {
        guard installed else { return nil }
        // `docker system df --format json` needs the daemon; a dead daemon
        // returns a non-zero exit — report "installed but not running".
        guard let output = try? await OptimizeEngine.shell(
            "\(shellQuote(dockerBin())) system df --format json", timeout: 30) else { return nil }
        let usage = parseDFJSONL(output)
        return usage.totalBytes > 0 || usage.imagesCount > 0 ? usage : Usage()
    }

    /// Reclaims stopped containers, unused networks, dangling images and
    /// build cache. `-f` skips the interactive prompt (the caller already
    /// confirmed). Returns Docker's human-readable removal list.
    static func prune() async throws -> String {
        guard installed else {
            throw NSError(domain: "docker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "docker is not installed"])
        }
        return try await OptimizeEngine.shell("\(shellQuote(dockerBin())) system prune -f",
                                              timeout: 300)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
