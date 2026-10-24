import Foundation

/// Safety layer inspired by mole's `lib/core/{file_ops,app_protection}.sh`.
///
/// Principles:
/// - Only paths under the user's home directory are ever deletable.
/// - Protected categories (keychains, cookies, messages, iCloud, mail,
///   browser profiles, preferences) are refused even inside the home.
/// - Symlink escape: the *resolved* path must still pass every check.
/// - A user-managed whitelist (~/.config/moppet/whitelist, one glob per
///   line — same format as mole's whitelist) always wins.
enum SafetyGuard {

    struct Verdict: Equatable {
        let allowed: Bool
        let reason: String?
        static func ok() -> Verdict { Verdict(allowed: true, reason: nil) }
        static func deny(_ reason: String) -> Verdict { Verdict(allowed: false, reason: reason) }
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Absolute home-relative paths (resolved, standardized) that must never
    /// be deleted. Mirrors mole's SAFETY categories.
    static let protectedHomeSubpaths: Set<String> = [
        // User-authored data tops — no clean rule targets these today; the
        // guard is the last line of defense if a pattern ever widens.
        // (Downloads stays out: the installers rule is extension-scoped.)
        "Documents",
        "Desktop",
        "Pictures",
        "Music",
        "Movies",
        "Library/Keychains",
        "Library/Cookies",
        "Library/Messages",
        "Library/Mail",
        "Library/Mobile Documents",          // iCloud Drive
        "Library/Application Support/MobileSync/Backup",   // iOS device backups (real location)
        "Library/Group Containers",
        "Library/Preferences",
        "Library/Accounts",
        "Library/IdentityServices",
        "Library/Safari",                    // history/cookies — cache lives in Caches/
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Microsoft Edge",
        "Library/Application Support/BraveSoftware",
        "Library/Application Support/Arc/User Data",
        "Library/Assistants",
        "Library/Services",
        "Library/Metadata",
        "Library/Containers/com.apple.Notes",
        "Library/Containers/com.apple.mail",
    ]

    /// Path prefixes under which deletion is always refused, whitelist or not.
    private static let hardDeniedPrefixes: [String] = [
        "/", "/System", "/bin", "/sbin", "/usr", "/etc", "/private/etc",
        "/Applications", "/Library", "/private/var/db", "/private/System",
    ]

    static let whitelistURL: URL = home
        .appendingPathComponent(".config/moppet/whitelist")

    // MARK: - Whitelist

    /// Lines are globs matched against the *resolved* absolute path.
    /// `~` at line start expands to the home directory.
    static func loadWhitelistPatterns() -> [String] {
        guard let text = try? String(contentsOf: whitelistURL, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func saveWhitelistPatterns(_ patterns: [String]) throws {
        let dir = whitelistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try patterns.joined(separator: "\n").appending("\n")
            .write(to: whitelistURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Glob matching (for whitelist)

    /// Simple glob: `*` matches any run of characters (not `/`), `?` one character.
    static func glob(_ pattern: String, matches path: String) -> Bool {
        func match(_ p: Substring, _ s: Substring) -> Bool {
            var p = p
            var s = s
            while !p.isEmpty {
                let pc = p.first!
                if pc == "*" {
                    p = p.dropFirst()
                    // Trailing '*' matches the rest of THIS segment only —
                    // `~/Library/*` must not cover `~/Library/a/b`.
                    if p.isEmpty { return !s.contains("/") }
                    var probe = s
                    while true {
                        if match(p, probe) { return true }
                        if probe.isEmpty { return false }
                        // `*` is single-segment: stop at the path separator.
                        if probe.first == "/" { return false }
                        probe = probe.dropFirst()
                    }
                }
                if s.isEmpty { return false }
                if pc == "?" || pc == s.first {
                    p = p.dropFirst()
                    s = s.dropFirst()
                } else {
                    return false
                }
            }
            return s.isEmpty
        }
        return match(pattern[...], path[...])
    }

    // MARK: - Core verdict

    static func checkDeletable(_ url: URL) -> Verdict {
        // 1. Must be absolute, no ".." components, no control characters.
        let raw = url.path
        guard raw.hasPrefix("/") else { return .deny("not an absolute path") }
        guard !raw.contains("..") else { return .deny("relative path components are not allowed") }
        guard raw.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint && $0 != "\0" }),
              raw.rangeOfCharacter(from: .controlCharacters) == nil
        else { return .deny("path contains control characters") }

        // 2. Resolve symlinks; the resolved path is what gets deleted.
        let resolved = url.resolvingSymlinksInPath()
        let rp = resolved.path

        // 3. Never touch system locations (checked before home containment so a
        //    symlinked home cannot smuggle a system path through).
        for prefix in hardDeniedPrefixes where rp == prefix || rp.hasPrefix(prefix + "/") {
            if rp == "/" { return .deny("refusing to delete a filesystem root") }
            return .deny("protected system location: \(prefix)")
        }
        // Home itself is not deletable either.
        if rp == home.path { return .deny("refusing to delete the home directory") }

        // 4. Must live inside the user's home.
        guard rp.hasPrefix(home.path + "/") else {
            return .deny("outside user home directory")
        }

        // 5. Protected categories inside the home.
        let homePrefix = home.path + "/"
        for sub in protectedHomeSubpaths {
            let protectedPath = homePrefix + sub
            if rp == protectedPath || rp.hasPrefix(protectedPath + "/") {
                return .deny("protected category: \(sub)")
            }
        }

        // 6. User whitelist always wins (pattern, its subtree, or any
        //    ancestor directory that matches the pattern).
        for pattern in loadWhitelistPatterns() {
            let expanded = pattern.hasPrefix("~") ? home.path + pattern.dropFirst() : pattern
            if globMatchesPathOrAncestor(expanded, rp) {
                return .deny("whitelisted by user: \(pattern)")
            }
        }

        return .ok()
    }

    /// Convenience used by the scan engine: returns nil when protected.
    static func deletableURL(_ url: URL) -> URL? {
        checkDeletable(url).allowed ? url : nil
    }

    /// Whitelist-only check (the "never touch" globs), without the
    /// home-containment policy — agent workspaces may legitimately live in
    /// /tmp or elsewhere; the user's whitelist still applies to them.
    static func isWhitelisted(_ url: URL) -> Bool {
        let rp = url.resolvingSymlinksInPath().path
        for pattern in loadWhitelistPatterns() {
            let expanded = pattern.hasPrefix("~") ? home.path + pattern.dropFirst() : pattern
            if globMatchesPathOrAncestor(expanded, rp) { return true }
        }
        return false
    }

    /// True when the pattern matches the path itself or any ancestor of it —
    /// whitelisting a folder protects its whole subtree (the old `pattern/*`
    /// fallback only covered ONE extra level).
    static func globMatchesPathOrAncestor(_ pattern: String, _ path: String) -> Bool {
        if glob(pattern, matches: path) { return true }
        var components = path.split(separator: "/").map(String.init)
        while !components.isEmpty {
            components.removeLast()
            let ancestor = "/" + components.joined(separator: "/")
            if components.isEmpty { break }
            if glob(pattern, matches: ancestor) { return true }
        }
        return false
    }
}
