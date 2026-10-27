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

        let value = probeFullDiskAccess()
        lock.lock()
        cachedResult = (value, Date())
        lock.unlock()
        return value
    }

    /// Drops the cached verdict so a just-completed Settings grant is picked
    /// up on the next read instead of ten seconds later.
    static func invalidate() {
        lock.lock()
        cachedResult = nil
        lock.unlock()
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

    /// Reveals a folder in Finder — used by the read-only hog reports
    /// (iOS backups, Mail) that this app deliberately never deletes.
    @MainActor
    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
