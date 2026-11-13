import Foundation

/// Per-user LaunchAgent bootstrap/bootout, shared by the scheduler and the
/// network checkup agent.
enum Launchd {
    static func bootout(_ label: String) async {
        _ = try? await OptimizeEngine.shell(
            "launchctl bootout gui/\(getuid())/\(label) 2>/dev/null || true")
    }

    static func bootstrap(_ label: String, plistURL: URL) async throws {
        _ = try await OptimizeEngine.shell(
            "launchctl bootstrap gui/\(getuid()) '\(plistURL.path)'")
    }

    static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}