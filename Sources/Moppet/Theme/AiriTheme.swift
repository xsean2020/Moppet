import SwiftUI
import AppKit

/// Design tokens distilled from the AIRI design system (DESIGN.md):
/// neutral gray surfaces, a single dynamic accent (default hue ≈ 220),
/// a 8/12/capsule/32 corner-radius ladder, 4/8/16/20 spacing rhythm.
enum Airi {
    // MARK: - Dynamic color helper

    static func dynamicColor(light: String, dark: String) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Neutral scale (Tailwind "neutral")

    static let neutral50 = dynamicColor(light: "#FAFAFA", dark: "#0A0A0A")   // inputs / subtle fill
    static let neutral100 = dynamicColor(light: "#F5F5F5", dark: "#171717")  // cards
    static let neutral200 = dynamicColor(light: "#E5E5E5", dark: "#262626")  // borders
    static let neutral400 = dynamicColor(light: "#A3A3A3", dark: "#525252")  // watermark icons
    static let neutral500 = dynamicColor(light: "#737373", dark: "#A3A3A3")  // secondary text
    static let neutral700 = dynamicColor(light: "#404040", dark: "#D4D4D4")
    static let neutral800 = dynamicColor(light: "#262626", dark: "#E5E5E5")
    static let neutral900 = dynamicColor(light: "#171717", dark: "#F5F5F5")  // primary text
    static let neutral950 = dynamicColor(light: "#0A0A0A", dark: "#FAFAFA")

    /// Card fill — BOTH modes translucent glass so the wallpaper tints
    /// through (solid white cards made light mode read as an opaque sheet;
    /// dark was already AIRI `dark:bg-[rgba(0,0,0,0.3)]`).
    static let cardBackground = dynamicColor(
        light: NSColor.white.withAlphaComponent(0.6),
        dark: NSColor.black.withAlphaComponent(0.3)
    )
    static let pageBackground = dynamicColor(light: "#FFFFFF", dark: "#121212")

    // MARK: - Accent (single dynamic hue, default 220.44 → Tailwind blue approximation)

    static let primary300 = dynamicColor(light: "#93C5FD", dark: "#BFDBFE")
    static let primary400 = dynamicColor(light: "#60A5FA", dark: "#60A5FA")
    static let primary = dynamicColor(light: "#3B82F6", dark: "#60A5FA")
    static let primary600 = dynamicColor(light: "#2563EB", dark: "#93C5FD")

    static let success = dynamicColor(light: "#22C55E", dark: "#4ADE80")
    static let danger = dynamicColor(light: "#EF4444", dark: "#F87171")
    static let warning = dynamicColor(light: "#F59E0B", dark: "#FBBF24")

    // MARK: - Chart palette (sparklines & metric accents, dynamic like the
    // neutrals — hardcoded hex here would stay light-mode-only in dark mode)

    static let chartPurple = dynamicColor(light: "#8B5CF6", dark: "#A78BFA")
    static let chartAmber = dynamicColor(light: "#F59E0B", dark: "#FBBF24")
    static let chartGreen = dynamicColor(light: "#22C55E", dark: "#4ADE80")

    // MARK: - Radius ladder

    static let radiusControl: CGFloat = 8    // buttons / inputs
    static let radiusCard: CGFloat = 12     // cards / popovers
    static let radiusSheet: CGFloat = 32    // bottom sheets

    // MARK: - Spacing rhythm (4 / 8 / 16 / 20)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 16
    static let space4: CGFloat = 20

    // MARK: - Motion

    /// Spring everywhere: controls feel physical instead of linear-fading.
    static let controlAnimation = Animation.spring(response: 0.3, dampingFraction: 0.85)
    /// Slightly snappier spring for hover/press states.
    static let hoverAnimation = Animation.spring(response: 0.22, dampingFraction: 0.8)
    static let cardAnimation = Animation.easeInOut(duration: 0.4)
    static let entranceCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.25)

    // MARK: - Typography
    //
    // The full type ladder. Views previously hardcoded ~185
    // `.system(size:)` calls (down to 9pt — below comfortable legibility);
    // new code must use these tokens. 9pt is gone: the floor is 10.

    static let pageTitleFont = Font.system(size: 30, weight: .regular)
    static let titleFont = Font.system(size: 17, weight: .medium)
    static let emphasisFont = Font.system(size: 15, weight: .medium)
    static let cardTitleFont = Font.system(size: 14, weight: .medium)
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 12)
    static let footnoteFont = Font.system(size: 11)
    static let caption2Font = Font.system(size: 10)

    /// Monospaced data face at the fine-print size (paths, chips, output).
    static let monoCaption2Font = Font.system(size: 10, design: .monospaced)
}

/// macOS 26 "Tahoe" introduced Liquid Glass: the system now owns window and
/// sidebar material compositing. The pre-Tahoe workarounds this app relied on
/// (stacking an extra `ultraThinMaterial` on the sidebar, dialing vibrancy
/// alpha below 1) actively fight it on 26 and render as muddy / opaque slabs.
/// Gate those workarounds on this flag so 14–15 keep their tuned look.
enum OSCompat {
    static let usesLiquidGlass: Bool =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Int64 {
    /// One shared formatter, lock-guarded, instead of a fresh one per call.
    /// The class method `ByteCountFormatter.string(fromByteCount:countStyle:)`
    /// builds a formatter (and its ICU state) for every single size label —
    /// and Analyze/Clean render hundreds of labels per pass. NSFormatter is
    /// not documented as thread-safe, hence the lock: size strings are also
    /// built from background sizing/audit code.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private static let byteFormatterLock = NSLock()

    var bytesFormatted: String {
        Self.byteFormatterLock.lock()
        defer { Self.byteFormatterLock.unlock() }
        return Self.byteFormatter.string(fromByteCount: self)
    }
}

/// Shortens a home-absolute path to a `~`-prefixed display form. Shared by
/// LargeFilesView, OrphansView and any other list that shows full paths.
func pathDisplay(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

extension Double {
    var percentFormatted: String {
        String(format: "%.1f%%", self * 100)
    }
}

// MARK: - Floater color diagnostics

extension Airi {
    /// `Moppet --probe-floater`: offscreen-render a cardBackground swatch
    /// through an NSHostingView under inherited / forced-light / forced-dark
    /// appearances and print the sampled pixel. Diagnoses whether
    /// provider-based dynamic tokens resolve correctly inside hand-built
    /// borderless panels (floaters rendering LIGHT under a dark system).
    @MainActor
    static func probeFloaterColors() -> Never {
        struct Swatch: View {
            var body: some View {
                Rectangle().fill(Airi.cardBackground)
                    .frame(width: 120, height: 120)
            }
        }
        func sample(_ name: NSAppearance.Name?) {
            let host = NSHostingView(rootView: Swatch())
            if let name { host.appearance = NSAppearance(named: name) }
            host.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                print("probe \(name?.rawValue ?? "inherit"): no bitmap rep")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let c = rep.colorAt(x: 60, y: 60)
            print(String(
                format: "probe cardBackground appearance=%@ -> rgb(%.0f,%.0f,%.0f) a=%.2f",
                name?.rawValue ?? "inherit",
                (c?.redComponent ?? -1) * 255,
                (c?.greenComponent ?? -1) * 255,
                (c?.blueComponent ?? -1) * 255,
                c?.alphaComponent ?? -1))
        }
        sample(nil)
        sample(.aqua)
        sample(.darkAqua)
        exit(0)
    }
}
