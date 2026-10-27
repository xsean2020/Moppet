import AppKit

/// Browser cache rules and the running browsers that must quit before their
/// caches can be removed cleanly: a live browser keeps rewriting and holding
/// open its cache files, so deleting them while it runs is incomplete (and
/// the browser often recreates them immediately).
enum BrowserProcesses {

    struct Browser: Identifiable, Hashable {
        let id: String        // CleanItem id
        let name: String
        let bundleID: String
    }

    static let all: [Browser] = [
        Browser(id: "safari-cache", name: "Safari", bundleID: "com.apple.Safari"),
        Browser(id: "chrome-cache", name: "Google Chrome", bundleID: "com.google.Chrome"),
        Browser(id: "edge-cache", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        Browser(id: "brave-cache", name: "Brave", bundleID: "com.brave.Browser"),
        Browser(id: "arc-cache", name: "Arc", bundleID: "company.thebrowser.Browser"),
    ]

    /// Browsers among `itemIDs` that are currently running.
    static func running(for itemIDs: Set<String>) -> [Browser] {
        all.filter { itemIDs.contains($0.id) && isRunning($0.bundleID) }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Quit the browsers: graceful first, then force after `gracefulTimeout`
    /// so the cache files are actually released before the clean runs.
    @MainActor
    static func quit(_ browsers: [Browser], gracefulTimeout: TimeInterval = 4,
                     forceTimeout: TimeInterval = 2) async {
        func apps() -> [NSRunningApplication] {
            browsers.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID)
            }
        }
        for app in apps() { _ = app.terminate() }
        if await waitUntilStopped(browsers, timeout: gracefulTimeout) { return }
        for app in apps() { _ = app.forceTerminate() }
        _ = await waitUntilStopped(browsers, timeout: forceTimeout)
    }

    private static func waitUntilStopped(_ browsers: [Browser],
                                         timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if browsers.allSatisfy({ !isRunning($0.bundleID) }) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return browsers.allSatisfy({ !isRunning($0.bundleID) })
    }
}
