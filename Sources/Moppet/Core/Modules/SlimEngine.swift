import Foundation
import AppKit

/// `mo slim` parity — remove Intel code from universal (arm64 + x86_64) apps
/// on Apple Silicon. Safety model mirrors mole: only user-writable,
/// non-App-Store, non-Apple, non-running apps; each app is slimmed on a COPY;
/// the copy must keep its arm64 slice and pass code-signing verification
/// before the original is trashed and replaced.
///
/// Fat headers are parsed in place (no `lipo` subprocess per file — scanning
/// reads only the first 8 + 20×n bytes of each Mach-O); `lipo -remove` and
/// `codesign` only run during the actual slim.
enum SlimEngine {

    // MARK: - Mach-O fat parsing

    /// CPU types as they appear in (big-endian) fat_arch entries.
    static let cpuI386: UInt32 = 7
    static let cpuX86_64: UInt32 = 0x0100_0007
    static let cpuArm64: UInt32 = 0x0100_000C

    struct FatSlice {
        let cpuType: UInt32
        let offset: UInt32
        let size: Int64
    }

    /// Slices of a fat (universal) Mach-O, or nil for thin / non-Mach-O
    /// files. Fat headers are big-endian regardless of host endianness.
    static func fatSlices(at url: URL) -> [FatSlice]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let h = [UInt8](header)
        // FAT_MAGIC 0xcafebabe stored big-endian → bytes ca fe ba be.
        guard h[0] == 0xCA, h[1] == 0xFE, h[2] == 0xBA, h[3] == 0xBE else { return nil }
        func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
            UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
        let count = Int(be32(h, 4))
        guard count > 0, count <= 32 else { return nil }
        guard let archData = try? handle.read(upToCount: count * 20),
              archData.count == count * 20 else { return nil }
        let a = [UInt8](archData)
        var slices: [FatSlice] = []
        for index in 0..<count {
            let base = index * 20
            slices.append(FatSlice(
                cpuType: be32(a, base),
                offset: be32(a, base + 8),
                size: Int64(be32(a, base + 12))))
        }
        return slices
    }

    static func isIntel(_ cpu: UInt32) -> Bool {
        cpu == cpuI386 || cpu == cpuX86_64
    }

    /// "x86_64" / "i386" for lipo -remove.
    static func archName(_ cpu: UInt32) -> String? {
        switch cpu {
        case cpuX86_64: return "x86_64"
        case cpuI386: return "i386"
        default: return nil
        }
    }

    /// A binary is slimmable only when an arm64 slice survives the removal.
    static func isSlimmable(_ slices: [FatSlice]) -> Bool {
        let hasArm64 = slices.contains { $0.cpuType == cpuArm64 }
        let hasIntel = slices.contains { isIntel($0.cpuType) }
        return hasArm64 && hasIntel
    }

    static func intelBytes(_ slices: [FatSlice]) -> Int64 {
        slices.filter { isIntel($0.cpuType) }.reduce(0) { $0 + $1.size }
    }

    // MARK: - Candidates

    struct Candidate: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let bundleID: String?
        let intelBytes: Int64
        /// Bundle-relative paths of universal binaries that carry Intel code.
        let binaries: [String]
    }

    struct Outcome: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let success: Bool
        let savedBytes: Int64
        let message: String
    }

    static var applicationDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Slimming strips Intel slices and keeps arm64 — the result only runs
    /// on Apple Silicon. On an Intel host the feature is a foot-gun, so both
    /// scan and slim hard-gate on the real CPU (runtime sysctl, not the
    /// compile-time arch, so a universal binary behaves identically).
    static var hostIsAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Pure filter predicates (smoke-tested): apps we must never touch.
    static func isProtected(bundleID: String?, hasMASReceipt: Bool, isRunning: Bool,
                            isAppleBundle: Bool = false) -> Bool {
        if hasMASReceipt { return true }                       // App Store
        if let bundleID, bundleID.hasPrefix("com.apple.") { return true }
        if isAppleBundle { return true }
        return isRunning
    }

    /// Scans application directories for universal apps and their Intel-code
    /// size. Read-only; progress gets the app currently being inspected.
    /// Returns nothing on Intel hosts (slimming there would break apps).
    static func scan(progress: ((String) -> Void)? = nil) async -> [Candidate] {
        guard hostIsAppleSilicon else { return [] }
        let running = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleURL?.standardizedFileURL.path })

        var candidates: [Candidate] = []
        for directory in applicationDirectories {
            guard let contents = try? FileManager.default
                .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for appURL in contents where appURL.hasDirectoryPath && appURL.pathExtension == "app" {
                let standardized = appURL.standardizedFileURL
                progress?(standardized.lastPathComponent)
                guard !running.contains(standardized.path),
                      FileManager.default.isWritableFile(atPath: standardized.path) else { continue }

                let contentsURL = standardized.appendingPathComponent("Contents")
                let masReceipt = contentsURL.appendingPathComponent("_MASReceipt/receipt")
                let plist = contentsURL.appendingPathComponent("Info.plist")
                let bundleID = (try? PropertyListSerialization.propertyList(
                    from: (try? Data(contentsOf: plist)) ?? Data(), options: [], format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
                guard !isProtected(bundleID: bundleID,
                                   hasMASReceipt: FileManager.default.fileExists(atPath: masReceipt.path),
                                   isRunning: false) else { continue }

                var intelTotal: Int64 = 0
                var binaries: [String] = []
                for binary in universalBinaries(under: contentsURL) {
                    guard let slices = fatSlices(at: binary), isSlimmable(slices) else { continue }
                    intelTotal += intelBytes(slices)
                    binaries.append(binary.path.replacingOccurrences(
                        of: standardized.path + "/", with: ""))
                }
                guard intelTotal > 0 else { continue }
                candidates.append(Candidate(
                    name: standardized.deletingPathExtension().lastPathComponent,
                    path: standardized.path,
                    bundleID: bundleID,
                    intelBytes: intelTotal,
                    binaries: binaries))
            }
        }
        return candidates.sorted { $0.intelBytes > $1.intelBytes }
    }

    /// Mach-O files under a bundle's Contents with both arm64 and Intel
    /// slices (executables, frameworks, dylibs, helpers, fat static libs —
    /// everything whose bytes shrink).
    private static func universalBinaries(under root: URL) -> [URL] {
        var result: [URL] = []
        // No .skipsPackageDescendants: frameworks, XPC services and helper
        // .app bundles inside Contents are where most Intel bytes live —
        // skipping them made every scan massively under-report.
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: nil)
        while let next = enumerator?.nextObject() as? URL {
            // Skip obvious non-code trees cheaply.
            let ext = next.pathExtension.lowercased()
            if ["lproj", "nib", "car", "png", "jpg", "tiff", "icns", "pdf",
                "strings", "plist", "html", "css", "js", "json", "md", "txt",
                "wav", "mp3", "aiff", "mov", "mp4", "zip", "gz", "dmg"].contains(ext) {
                continue
            }
            guard let values = try? next.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            result.append(next)
        }
        return result
    }

    // MARK: - Slimming

    /// Slims selected apps: copy → lipo -remove Intel → re-sign → verify →
    /// trash original → move copy into place. `dryRun` reports the plan only.
    static func slim(_ candidates: [Candidate], dryRun: Bool = false,
                     progress: ((String) -> Void)? = nil) async -> [Outcome] {
        guard hostIsAppleSilicon else {
            // Hard refuse on Intel hosts — even dryRun misleads here.
            return candidates.map {
                Outcome(name: $0.name, path: $0.path, success: false, savedBytes: 0,
                        message: "refused: this Mac is Intel — removing x86_64 slices would leave the app unusable here")
            }
        }
        if dryRun {
            return candidates.map {
                Outcome(name: $0.name, path: $0.path, success: true, savedBytes: 0,
                        message: "would remove \($0.binaries.count) Intel slice(s), ~\($0.intelBytes) bytes")
            }
        }
        guard tryBeginSlim() else {
            return candidates.map {
                Outcome(name: $0.name, path: $0.path, success: false, savedBytes: 0,
                        message: "another slim is already running — wait for it to finish")
            }
        }
        defer { endSlim() }
        var outcomes: [Outcome] = []
        for candidate in candidates {
            progress?(candidate.name)
            outcomes.append(await slimOne(candidate))
        }
        return outcomes
    }

    private static func run(_ command: String, _ arguments: [String],
                            timeout: TimeInterval = 300) -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "spawn failed: \(error.localizedDescription)")
        }
        // Drain concurrently (read-after-exit deadlocks once the child fills
        // the pipe buffer), with a watchdog: lipo/codesign hanging must not
        // park the slim job forever.
        let drained = DispatchGroup()
        drained.enter()
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            drained.wait()
            return (124, "command timed out after \(Int(timeout))s")
        }
        drained.wait()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Cross-slim mutual exclusion: navigating away mid-slim used to leave an
    /// orphaned task the fresh page could race with a second slim on the same
    /// bundle.
    private static let inFlight = NSLock()
    private static var slimming = false

    private static func tryBeginSlim() -> Bool {
        inFlight.lock(); defer { inFlight.unlock() }
        if slimming { return false }
        slimming = true
        return true
    }
    private static func endSlim() {
        inFlight.lock(); defer { inFlight.unlock() }
        slimming = false
    }

    private static func slimOne(_ candidate: Candidate) async -> Outcome {
        let source = URL(fileURLWithPath: candidate.path)
        // TOCTOU guards re-run at execution time: the app may have been
        // launched (or protected) between the scan and this click.
        let runningNow = NSWorkspace.shared.runningApplications
            .contains { $0.bundleURL?.standardizedFileURL.path == source.path }
        if runningNow {
            return fail(candidate, "refused: \(candidate.name) is running now — quit it first")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("moppet-slim-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return fail(candidate, "cannot create scratch dir: \(error.localizedDescription)")
        }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)

        // 1) Copy the bundle.
        let cp = run("/bin/cp", ["-pR", source.path, copy.path])
        guard cp.exit == 0 else {
            try? FileManager.default.removeItem(at: scratch)
            return fail(candidate, "copy failed: \(cp.output.prefix(160))")
        }
        // The slimmed copy carries a NEW ad-hoc/replicated signature — the
        // original quarantine xattr would make Gatekeeper reject it as
        // "damaged" on first launch. Strip it from the copy only.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", copy.path])

        // 2) Remove Intel slices from every universal binary in the copy.
        for relative in candidate.binaries {
            let target = copy.appendingPathComponent(relative)
            guard let slices = fatSlices(at: target), isSlimmable(slices) else { continue }
            let archs = Set(slices.filter { isIntel($0.cpuType) }.compactMap { archName($0.cpuType) })
            guard !archs.isEmpty else { continue }
            let thin = scratch.appendingPathComponent("thin-\(UUID().uuidString)")
            // lipo's documented multi-arch form: one -remove flag per arch.
            var args: [String] = []
            for arch in archs.sorted() { args += ["-remove", arch] }
            args += ["-output", thin.path, target.path]
            let lipo = run("/usr/bin/lipo", args)
            guard lipo.exit == 0 else {
                try? FileManager.default.removeItem(at: scratch)
                return fail(candidate, "lipo failed on \(relative): \(lipo.output.prefix(160))")
            }
            do {
                // Preserve the original mode (lipo output may drop the x bit).
                let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: thin, to: target)
                if let mode {
                    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
                }
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                return fail(candidate, "replace failed on \(relative): \(error.localizedDescription)")
            }
        }

        // 3) Re-sign. Prefer the app's original Developer ID identity when
        // the matching signing certificate exists in this keychain; ad-hoc
        // otherwise (macOS may then ask to allow the app on first launch).
        let identity = signingIdentity(for: source) ?? "-"
        let sign = run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity,
                                             "--preserve-metadata=entitlements", copy.path])
        var signNote = ""
        if sign.exit != 0, identity != "-" {
            let minimal = run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", copy.path])
            if minimal.exit != 0 {
                try? FileManager.default.removeItem(at: scratch)
                return fail(candidate, "re-sign failed: \(sign.output.prefix(160))")
            }
            signNote = " (re-signed ad-hoc — original identity unavailable)"
        } else if sign.exit != 0 {
            try? FileManager.default.removeItem(at: scratch)
            return fail(candidate, "re-sign failed: \(sign.output.prefix(160))")
        }

        // 4) Verify signature integrity before swapping anything.
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy.path])
        guard verify.exit == 0 else {
            try? FileManager.default.removeItem(at: scratch)
            return fail(candidate, "verification failed: \(verify.output.prefix(160))")
        }

        // 5) Swap: original → Trash, slimmed copy → its place.
        do {
            var recycled: NSURL? = nil
            try FileManager.default.trashItem(at: source, resultingItemURL: &recycled)
            do {
                try FileManager.default.moveItem(at: copy, to: source)
            } catch {
                // Roll the ORIGINAL back out of the Trash — without this the
                // app was gone from /Applications with its only good copy in
                // a temp dir the OS wipes on reboot.
                var restoreNote = ""
                if let trashed = recycled as URL? {
                    do {
                        try FileManager.default.moveItem(at: trashed, to: source)
                        restoreNote = "original restored from Trash"
                    } catch {
                        restoreNote = "RESTORE FAILED — original is in the Trash at \(trashed.path), copy at \(copy.path)"
                    }
                }
                return Outcome(
                    name: candidate.name, path: candidate.path, success: false,
                    savedBytes: 0,
                    message: "installing the slimmed copy failed (\(error.localizedDescription)) — \(restoreNote)")
            }
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            return fail(candidate, "cannot trash original: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: scratch)

        HistoryStore.append(CleanRecord(
            date: Date(),
            sectionTitles: [candidate.name],
            requestedBytes: candidate.intelBytes,
            freedBytes: candidate.intelBytes,
            itemCount: 1,
            items: [CleanRecordItem(path: candidate.path, bytes: candidate.intelBytes,
                                    mode: .trash, success: true, error: nil)], source: .slim))

        return Outcome(name: candidate.name, path: candidate.path, success: true,
                       savedBytes: candidate.intelBytes,
                       message: "slimmed\(identity == "-" ? " (ad-hoc re-signed)" : signNote)")
    }

    private static func fail(_ candidate: Candidate, _ message: String) -> Outcome {
        HistoryStore.append(CleanRecord(
            date: Date(),
            sectionTitles: [candidate.name],
            requestedBytes: candidate.intelBytes,
            freedBytes: 0,
            itemCount: 1,
            items: [CleanRecordItem(path: candidate.path, bytes: 0,
                                    mode: .trash, success: false, error: message)], source: .slim))
        return Outcome(name: candidate.name, path: candidate.path, success: false,
                       savedBytes: 0, message: message)
    }

    /// "Developer ID Application: NAME (TEAM)" from the app's current
    /// signature, when a matching codesigning identity exists locally.
    private static func signingIdentity(for appURL: URL) -> String? {
        let info = run("/usr/bin/codesign", ["-dv", appURL.path])
        guard let authority = info.output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("Authority=Developer ID Application:") })?
            .dropFirst("Authority=".count)
            .trimmingCharacters(in: .whitespaces) else { return nil }
        let identities = run("/usr/bin/security",
                             ["find-identity", "-v", "-p", "codesigning"])
        guard identities.output.contains(authority) else { return nil }
        return authority
    }
}
