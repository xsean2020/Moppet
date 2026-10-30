import Foundation
import AppKit

/// TCC permission probes — the "why does the scan look empty?" answer.
///
/// Without Full Disk Access the sandbox-less app cannot read the TCC-protected
/// trees (`~/Library/Mail`, `~/Library/Messages`, Safari data, iOS backups…),
/// so scans silently report nothing there. A user reasonably reads that as
/// "the app is broken" — the gap analysis calls for detection + a one-click
/// jump into the right System Settings pane instead.
enum Permissions {

    private static let lock = NSLock()
    private static var cachedResult: (value: Bool, at: Date)?
    /// FDA state changes only in System Settings; a short cache avoids
    /// re-probing on every view appear without going stale mid-session.
    private static let cacheTTL: TimeInterval = 10

    /// Drops the FDA cache the moment the user returns to the app. Granting
    /// FDA happens in System Settings, so the ONLY way back is activating
    /// this app — the old TTL alone kept reporting "no permission" for up to
    /// 10 s after the grant, reading as "I granted it and it still says no".
    private static let activationHook: Void = {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            lock.lock()
            cachedResult = nil
            lock.unlock()
        }
    }()

    /// True when the process can read the user TCC database. Reading
    /// `TCC.db` is the canonical probe: it is the most TCC-protected file a
    /// granted app can open, and a denied read throws errno 1 immediately.
    static var hasFullDiskAccess: Bool {
        lock.lock()
        if let cachedResult, Date().timeIntervalSince(cachedResult.at) < cacheTTL {
            let value = cachedResult.value
            lock.unlock()
            return value
        }
        lock.unlock()

        _ = activationHook
        let value = probeFullDiskAccess()
        lock.lock()
        cachedResult = (value, Date())
        lock.unlock()
        return value
    }

    private static func probeFullDiskAccess() -> Bool {
        let tccDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        // O_RDONLY + close, no contents read — existence of the permission,
        // not the file's data, is what we are testing.
        let fd = open(tccDB.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Opens Privacy → Full Disk Access. The `x-apple.systempreferences:`
    /// URL is the documented deep link; NSWorkspace.shared.open from a
    /// non-main thread can crash AppKit, hence MainActor.
    @MainActor
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS 15 (Sequoia) split app-bundle modification into its own TCC
    /// permission. Full Disk Access is READ-ONLY — it never grants delete
    /// rights — so from Sequoia on, trashing another app's .app bundle in
    /// /Applications fails with EPERM even with FDA granted and even when
    /// the bundle is user-owned. This is the "FDA on but uninstall still
    /// denied" answer.
    static var needsAppManagement: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    /// Opens Privacy → App Management. There is no public read API for the
    /// App Management state (any write probe would itself trigger the TCC
    /// prompt), so the app detects it from delete failures instead — this
    /// deep link is the actionable follow-up.
    @MainActor
    static func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Benign App Management probe: touch another app bundle's modification
    /// date. A granted environment answers success immediately; a denied or
    /// undecided one fails. NOT a reliable prompt trigger by itself — the
    /// system prompt is raised by the failed bundle-modification attempt
    /// itself (removeItem) when the TCC decision is still undecided; once a
    /// decision (especially a deny) is recorded, macOS never re-prompts and
    /// only `openAppManagementSettings` can recover.
    static func probeAppManagement(bundleURL: URL) -> Bool {
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: bundleURL.path)
            return true
        } catch {
            return false
        }
    }

    /// Reveals a folder in Finder — used by the read-only hog reports
    /// (iOS backups, Mail) that this app deliberately never deletes.
    @MainActor
    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
