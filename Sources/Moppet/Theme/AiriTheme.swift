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
    /// Secondary text. Light mode is `#525252` (7.3:1 on a white card) rather
    /// than Tailwind's `#737373` (4.4:1) — captions are small, so they sit
    /// below the AA threshold at the lighter step.
    static let neutral500 = dynamicColor(light: "#525252", dark: "#A3A3A3")
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

    /// Text-safe variants. The 500-level hues above are fill/indicator
    /// colours (2:1 on white); these hold 4.5:1+ for small captions and
    /// badges while keeping the same hue family.
    static let warningStrong = dynamicColor(light: "#92400E", dark: "#FBBF24")
    static let successStrong = dynamicColor(light: "#15803D", dark: "#4ADE80")

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

    // MARK: - Sidebar ladder
    //
    // The nav panel's geometry and surfaces. Kept here (not inline in the
    // view) so row height, insets and washes stay a single system: every
    // value below is measured from the same 4pt rhythm.

    /// Row target height — macOS list rows live at 28–32; 32 keeps the click
    /// target comfortable without the list looking airy.
    static let sidebarRowHeight: CGFloat = 32
    /// Seam between rows inside a band: enough to separate targets, not
    /// enough to break the band into loose items.
    static let sidebarRowGap: CGFloat = 1
    /// Whitespace between bands — this is what groups the list, so it is
    /// deliberately ~3× the row seam.
    static let sidebarBandGap: CGFloat = 14
    /// Horizontal inset of the row list inside the column (pill safe area).
    static let sidebarListInset: CGFloat = 10
    /// Inner horizontal padding of a row (pill edge → icon).
    static let sidebarRowPadding: CGFloat = 12
    static let sidebarRowRadius: CGFloat = 8
    /// Brand row / footer inset: sits a touch outside the pills so the header
    /// and footer read as panel chrome rather than as list content.
    static let sidebarEdgeInset: CGFloat = 16
    /// Top inset for the brand row. Under `hiddenTitleBar` the traffic lights
    /// occupy roughly the top 28pt; anything less than this and the app icon
    /// crowds the window controls.
    static let sidebarBrandTopInset: CGFloat = 26

    /// Selected-row wash: a low-alpha accent tint (System Settings style)
    /// instead of a saturated capsule. The accent still carries the state,
    /// but through hue, not through contrast.
    static let sidebarSelectionFill = dynamicColor(
        light: NSColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 0.08),
        dark: NSColor(srgbRed: 0.40, green: 0.66, blue: 1, alpha: 0.22)
    )
    /// Hover wash — a black veil in light mode, a white one in dark (a black
    /// wash is invisible on dark glass).
    static let sidebarHoverFill = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.04),
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    /// Group header colour: the platform secondary label (#8E8E93). Quieter
    /// than `neutral500` so the headers recede below the row titles.
    static let sidebarSectionLabel = dynamicColor(light: "#8E8E93", dark: "#9C9CA3")
    /// 1px separator that reads as light, not as a seam — used for the footer
    /// rule (and any future inset divider).
    static let hairline = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.white.withAlphaComponent(0.09)
    )

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
    /// Dashboard metric ladder — big rounded numerals. Keep the two sizes
    /// here so the cards cannot drift apart again (30 / 19 were inline).
    static let metricFont = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let metricSmallFont = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let cardTitleFont = Font.system(size: 14, weight: .medium)
    static let bodyFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 12)
    static let footnoteFont = Font.system(size: 11)
    static let caption2Font = Font.system(size: 10)

    /// Monospaced data face at the fine-print size (paths, chips, output).
    static let monoCaption2Font = Font.system(size: 10, design: .monospaced)

    // Sidebar type: the group header sits below the row in both size and
    // weight (11 regular vs 13), so hierarchy comes from the ladder rather
    // than from colour alone.
    static let sidebarSectionFont = Font.system(size: 11, weight: .regular)
    static let sidebarRowFont = Font.system(size: 13, weight: .regular)
    static let sidebarRowActiveFont = Font.system(size: 13, weight: .medium)
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

    /// Fixed one-decimal size string for dashboard metrics.
    ///
    /// `ByteCountFormatter` is adaptive: the same screen showed `60.1 GB`,
    /// `52.92 GB` and `383.67 GB`, and `383.67 + 110.72` visibly failed to
    /// equal the displayed `494.38` total. One decimal on every component
    /// makes the card close arithmetically (`383.7 + 110.7 = 494.4`).
    ///
    /// Uses decimal units (1000) to match ByteCountFormatter's `.file` style.
    private static let oneDecimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = true
        return formatter
    }()
    private static let oneDecimalLock = NSLock()

    var bytesFormatted1: String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(self)
        var unit = 0
        while abs(value) >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        guard unit > 0 else { return "\(self) B" }
        return Self.oneDecimal(value) + " " + units[unit]
    }

    private static func oneDecimal(_ value: Double) -> String {
        oneDecimalLock.lock()
        defer { oneDecimalLock.unlock() }
        return oneDecimalFormatter.string(from: NSNumber(value: value))
            ?? String(format: "%.1f", value)
    }

    /// Disk triple formatted so the rounded numbers still close:
    /// `used + free == total` in the strings the card actually shows.
    ///
    /// Rounding each component independently is not enough — a real disk
    /// rendered as `382.0 + 112.3 = 494.3` against a `494.4` total. The
    /// larger side (used) is therefore derived from the two rounded anchors.
    static func diskDisplay(total: Int64, free: Int64)
        -> (used: String, free: String, total: String) {
        guard total > 0 else { return ("0 B", "0 B", "0 B") }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var unit = 0
        var totalValue = Double(total)
        while totalValue >= 1000, unit < units.count - 1 {
            totalValue /= 1000
            unit += 1
        }
        let unitName = units[unit]
        guard unit > 0 else { return ("\(total - free) B", "\(free) B", "\(total) B") }

        let scale = pow(1000.0, Double(unit))
        func rounded1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        let totalRounded = rounded1(totalValue)
        // Qualify min/max: inside an Int64 extension the unqualified names
        // resolve to Int64.min / Int64.max, not the global functions.
        let freeRounded = Swift.min(totalRounded,
                                    rounded1(Swift.min(free, total) > 0 ? Double(free) / scale : 0))
        let usedRounded = Swift.max(0, totalRounded - freeRounded)

        func text(_ rounded: Double, raw: Int64) -> String {
            // Keep a tiny non-zero share visible instead of rounding to 0.0.
            if raw > 0 && rounded == 0 { return "<0.1 \(unitName)" }
            return oneDecimal(rounded) + " " + unitName
        }
        return (text(usedRounded, raw: Swift.max(0, total - free)),
                text(freeRounded, raw: free),
                oneDecimal(totalRounded) + " " + unitName)
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
