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
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return false }
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

    /// Parses `docker system df --format json` — one JSON object per line
    /// with type-specific keys (older Docker emits this NDJSON shape).
    static func parseDFJSONL(_ output: String) -> Usage {
        var usage = Usage()
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["Type"] as? String else { continue }
            let count = (obj["Containers"] as? Int)
                ?? (obj["Images"] as? Int)
                ?? (obj["Volumes"] as? Int)
                ?? (obj["BuildCache"] as? Int)
                ?? (Int(obj["Containers"] as? String ?? "") ?? 0)
            let bytes = (obj["Size"] as? Int64)
                ?? (Double(obj["Size"] as? String ?? "") ?? 0).roundedInt64
            switch type {
            case "images": usage.imagesCount = count; usage.imagesBytes = bytes
            case "containers": usage.containersCount = count; usage.containersBytes = bytes
            case "local Volumes", "volumes": usage.volumesCount = count; usage.volumesBytes = bytes
            case "build-cache", "build cache": usage.cacheCount = count; usage.cacheBytes = bytes
            default: break
            }
        }
        return usage
    }

    static func usage() async -> Usage? {
        guard installed else { return nil }
        // `docker system df --format json` needs the daemon; a dead daemon
        // returns a non-zero exit — report "installed but not running".
        guard let output = try? await OptimizeEngine.shell(
            "\(shellQuote(dockerBin())) system df --format json") else { return nil }
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
        return try await OptimizeEngine.shell("\(shellQuote(dockerBin())) system prune -f")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension Double {
    var roundedInt64: Int64 { Int64(self) }
}
