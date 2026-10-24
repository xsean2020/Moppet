import Foundation
import AppKit

/// System maintenance tasks — SwiftUI cousin of `mo optimize`.
/// Tasks that need root run through an AppleScript administrator prompt
/// (the GUI equivalent of mole's per-operation sudo).
enum OptimizeEngine {

    struct OptimizeTask: Identifiable {
        let id: String
        let title: String
        let detail: String
        let category: String
        let requiresAdmin: Bool
        let run: () async throws -> String
    }

    /// Runs a shell command and requires exit 0 — a failing killall/defaults
    /// used to be reported as "✓ success" anyway. (The admin variant is
    /// shellWithAdmin; there is no admin parameter here.)
    @discardableResult
    static func shell(_ command: String) async throws -> String {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", command]
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        // Drain concurrently: reading only after exit deadlocks once the
        // child fills the ~64KB pipe buffer.
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }
        let output = String(data: await reader.value, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "exit \(proc.terminationStatus): \(output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).prefix(200))"])
        }
        return output
    }

    /// NONISOLATED on purpose: `catalog` is a static let whose closures call
    /// this. When the function was @MainActor, every closure inherited that
    /// isolation, which made the static initializer main-actor-isolated
    /// ("main actor-isolated default value in a nonisolated context" — a
    /// warning in Swift 5 and a hard ERROR in Swift 6 language mode).
    /// NSAppleScript itself still runs on the main thread via MainActor.run.
    static func shellWithAdmin(_ command: String) async throws -> String {
        try await MainActor.run {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            var error: NSDictionary?
            let output = NSAppleScript(source: script)?.executeAndReturnError(&error)
                .stringValue ?? ""
            if let error {
                throw NSError(domain: "admin", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "administrator authorization failed"])
            }
            return output
        }
    }

    static let catalog: [OptimizeTask] = [
        OptimizeTask(
            id: "finder-restart",
            title: "Restart Finder",
            detail: "Clears Finder cache & fixes UI glitches",
            category: "Finder", requiresAdmin: false
        ) {
            try await shell("killall Finder")
            return "Finder restarted"
        },
        OptimizeTask(
            id: "dock-restart",
            title: "Restart Dock",
            detail: "Refreshes Dock cache",
            category: "Finder", requiresAdmin: false
        ) {
            try await shell("killall Dock")
            return "Dock restarted"
        },
        OptimizeTask(
            id: "dns-flush",
            title: "Flush DNS Cache",
            detail: "dscacheutil + killall -HUP mDNSResponder",
            category: "Network", requiresAdmin: true
        ) {
            _ = try await shellWithAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder")
            return "DNS cache flushed"
        },
        OptimizeTask(
            id: "spotlight-reindex",
            title: "Rebuild Spotlight Index",
            detail: "Reindexes the boot volume",
            category: "Spotlight", requiresAdmin: true
        ) {
            _ = try await shellWithAdmin("mdutil -E /")
            return "Spotlight reindex requested"
        },
        OptimizeTask(
            id: "purge-memory",
            title: "Purge Disk Cache",
            detail: "Asks the kernel to drop clean pages (sudo purge)",
            category: "Memory", requiresAdmin: true
        ) {
            _ = try await shellWithAdmin("purge")
            return "Purge completed"
        },
        OptimizeTask(
            id: "ds-store-network",
            title: "Disable .DS_Store on Network Volumes",
            detail: "defaults write DesktopServices",
            category: "Finder", requiresAdmin: false
        ) {
            try await shell("defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true")
            return "Setting enabled"
        },
        OptimizeTask(
            id: "saved-state-cleanup",
            title: "Remove Stale Saved State (30d+)",
            detail: "Deletes app resume state older than 30 days",
            category: "Maintenance", requiresAdmin: false
        ) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = home.appendingPathComponent("Library/Saved Application State")
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
                return "No saved state directory"
            }
            var removed = 0
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            for entry in entries {
                let url = root.appendingPathComponent(entry)
                guard SafetyGuard.checkDeletable(url).allowed,
                      let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let modified = attrs[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
            return "Removed \(removed) stale saved-state folders"
        },
        OptimizeTask(
            id: "health-diagnostics",
            title: "Health Report",
            detail: "Disk + memory + uptime summary",
            category: "Diagnostics", requiresAdmin: false
        ) {
            let disk = DiskInfo.snapshot()
            let mem = SystemStatus.memory
            let uptime = SystemStatus.uptimeFormatted
            return """
            Uptime: \(uptime)
            Disk: \(disk.usedBytes.bytesFormatted) used / \(disk.totalBytes.bytesFormatted) (\(disk.freeBytes.bytesFormatted) free)
            Memory: \(mem.usedBytes.bytesFormatted) used of \(mem.totalBytes.bytesFormatted)
            """
        },
    ]

    @MainActor
    static func run(taskID: String) async throws -> String {
        guard let task = catalog.first(where: { $0.id == taskID }) else {
            throw NSError(domain: "optimize", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unknown task \(taskID)"])
        }
        PetBus.shared.setState(.cleaning)
        defer { PetBus.shared.settle() }
        return try await task.run()
    }
}
