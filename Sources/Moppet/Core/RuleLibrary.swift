import Foundation

/// Built-in rule library — the SwiftUI counterpart of mole's `lib/clean/*.sh`
/// section registry. Every pattern is confined to the user's home directory;
/// `SafetyGuard` re-validates each expanded path before deletion.
enum RuleLibrary {

    /// Cache subtrees owned by dedicated rules — the generic user-cache rule
    /// skips these so sizes are not double counted.
    private static let dedicatedCachePrefixes = [
        "com.apple.Safari", "Google/Chrome", "Microsoft Edge", "BraveSoftware", "Arc",
        "Homebrew", "Yarn", "pip", "uv", "go-build", "pnpm",
    ]

    static let sections: [CleanSection] = [
        CleanSection(
            id: "system-user",
            title: "System & User",
            subtitle: "User caches, logs and the Trash",
            icon: "paintbrush",
            items: [
                CleanItem(
                    id: "user-caches",
                    name: "User Caches",
                    detail: "Regenerable app caches in ~/Library/Caches",
                    pattern: "~/Library/Caches/*",
                    mode: .permanent,
                    excludedPrefixes: dedicatedCachePrefixes
                ),
                CleanItem(
                    id: "user-logs",
                    name: "User Logs",
                    detail: "Rotated logs in ~/Library/Logs",
                    pattern: "~/Library/Logs/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "trash",
                    name: "Trash",
                    detail: "Everything currently in the Trash",
                    pattern: "~/.Trash/*",
                    mode: .permanent,
                    warning: "PERMANENTLY empties the Trash — anything you parked there \"just in case\" is unrecoverable.",
                    defaultSelected: false
                ),
            ]
        ),
        CleanSection(
            id: "developer",
            title: "Developer",
            subtitle: "Build artifacts, toolchains and package caches",
            icon: "hammer",
            items: [
                CleanItem(
                    id: "xcode-derived",
                    name: "Xcode DerivedData",
                    detail: "Build products & index — rebuilt on next build",
                    pattern: "~/Library/Developer/Xcode/DerivedData/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "xcode-devicesupport",
                    name: "iOS Device Support",
                    detail: "Symbol files for devices you no longer connect",
                    pattern: "~/Library/Developer/Xcode/iOS DeviceSupport/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "xcode-archives",
                    name: "Xcode Archives",
                    detail: "Archived builds (.xcarchive)",
                    pattern: "~/Library/Developer/Xcode/Archives/*",
                    mode: .trash,
                    warning: "Moved to Trash — recover it if you still ship these builds.",
                    defaultSelected: false
                ),
                CleanItem(
                    id: "sim-caches",
                    name: "Simulator Caches",
                    detail: "CoreSimulator caches (simulators themselves untouched)",
                    pattern: "~/Library/Developer/CoreSimulator/Caches/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "npm",
                    name: "npm Cache",
                    detail: "~/.npm download cache",
                    pattern: "~/.npm",
                    mode: .permanent
                ),
                CleanItem(
                    id: "pnpm-store",
                    name: "pnpm Store",
                    detail: "Content-addressable store (~/Library/pnpm/store)",
                    pattern: "~/Library/pnpm/store",
                    mode: .permanent,
                    warning: "Projects will re-download dependencies on next install.",
                    defaultSelected: false
                ),
                CleanItem(
                    id: "yarn-cache",
                    name: "Yarn Cache",
                    detail: "Yarn package cache",
                    pattern: "~/Library/Caches/Yarn/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "gradle-cache",
                    name: "Gradle Cache",
                    detail: "~/.gradle/caches artifacts & transforms",
                    pattern: "~/.gradle/caches/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "cargo-cache",
                    name: "Cargo Registry Cache",
                    detail: "Downloaded .crate archives only",
                    pattern: "~/.cargo/registry/cache/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "pip-cache",
                    name: "pip Cache",
                    detail: "Pip wheel cache",
                    pattern: "~/Library/Caches/pip/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "uv-cache",
                    name: "uv Cache",
                    detail: "Astral uv wheel cache",
                    pattern: "~/Library/Caches/uv/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "go-build-cache",
                    name: "Go Build Cache",
                    detail: "Compiled package cache (go clean -cache equivalent)",
                    pattern: "~/Library/Caches/go-build/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "brew-cache",
                    name: "Homebrew Cache",
                    detail: "Downloaded bottles & source tarballs",
                    pattern: "~/Library/Caches/Homebrew/*",
                    mode: .permanent
                ),
            ]
        ),
        CleanSection(
            id: "browsers",
            title: "Browsers",
            subtitle: "Cache subtrees only — history, cookies and profiles stay",
            icon: "safari",
            items: [
                CleanItem(
                    id: "safari-cache",
                    name: "Safari Cache",
                    detail: "com.apple.Safari caches (no history/cookies)",
                    pattern: "~/Library/Caches/com.apple.Safari/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "chrome-cache",
                    name: "Chrome Cache",
                    detail: "Google Chrome caches",
                    pattern: "~/Library/Caches/Google/Chrome/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "edge-cache",
                    name: "Edge Cache",
                    detail: "Microsoft Edge caches",
                    pattern: "~/Library/Caches/Microsoft Edge/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "brave-cache",
                    name: "Brave Cache",
                    detail: "Brave caches",
                    pattern: "~/Library/Caches/BraveSoftware/*",
                    mode: .permanent
                ),
                CleanItem(
                    id: "arc-cache",
                    name: "Arc Cache",
                    detail: "Arc caches",
                    pattern: "~/Library/Caches/Arc/*",
                    mode: .permanent
                ),
            ]
        ),
        CleanSection(
            id: "installers",
            title: "Installers",
            subtitle: "Leftover disk images & packages in Downloads",
            icon: "shippingbox",
            items: [
                CleanItem(
                    id: "dmg",
                    name: "DMG Images",
                    detail: "~/**/*.dmg (whole home, protected dirs skipped)",
                    pattern: "~",
                    mode: .trash,
                    warning: "Deep-scans the whole home folder — the first scan may take a while.",
                    defaultSelected: false,
                    deepExtensions: ["dmg"]
                ),
                CleanItem(
                    id: "pkg",
                    name: "Packages",
                    detail: "~/**/*.pkg (whole home, protected dirs skipped)",
                    pattern: "~",
                    mode: .trash,
                    defaultSelected: false,
                    deepExtensions: ["pkg"]
                ),
                CleanItem(
                    id: "iso",
                    name: "ISO Images",
                    detail: "~/**/*.iso (whole home, protected dirs skipped)",
                    pattern: "~",
                    mode: .trash,
                    defaultSelected: false,
                    deepExtensions: ["iso"]
                ),
            ]
        ),
    ]
}
