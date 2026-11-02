import AppKit
import SwiftUI

/// `--probe-render <page> <png> [light|dark] [expanded]`: renders a page into
/// a PNG offscreen. Pages: `clean`, `optimize`, `status`, `spacehogs`, `startup`, `settings`.
///
/// Same rationale as `AnalyzeRenderProbe`: a terminal-launched binary often
/// lacks screen-recording permission, so `screencapture` fails. Rendering the
/// hosting view's own layer tree needs no permission and no visible window —
/// the only way to check a layout (grouped lists, row density, alignment)
/// without driving the real UI by hand.
@MainActor
enum PageRenderProbe {

    static func run(page: String, outputPath: String, appearance: String = "dark",
                    expandFirst: Bool = false, height: CGFloat = 860) {
        let root: AnyView
        switch page {
        case "clean":
            if expandFirst { CleanView.debugExpandFirstSection = true }
            root = AnyView(CleanView())
        case "optimize":
            root = AnyView(OptimizeView())
        case "status":
            StatusView.debugSeed = true
            // `expanded` pre-selects the CPU quadrant so the render also
            // covers the click-through detail card.
            if expandFirst { StatusView.debugSelectedQuadrant = .cpu }
            root = AnyView(StatusView())
        case "spacehogs":
            SystemHogsView.debugSeed = true
            root = AnyView(SystemHogsView())
        case "startup":
            LaunchItemsView.debugSeed = true
            root = AnyView(LaunchItemsView())
        case "settings":
            root = AnyView(SettingsView())
        default:
            FileHandle.standardError.write(
                Data("probe-render: unknown page '\(page)' — use clean|optimize|status|spacehogs|startup|settings\n".utf8))
            exit(2)
        }

        let size = NSSize(width: 1180, height: max(600, height))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Dynamic tokens resolve inconsistently without an explicit
        // appearance, so pin it — otherwise the render lies about the theme.
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        // The page fill is near-transparent (the real window sits on dark
        // vibrancy), so an offscreen host would composite over the default
        // WHITE window and every light-mode text token would vanish. Paint the
        // page colour behind the content to reproduce the app's backdrop.
        window.backgroundColor = appearance == "light"
            ? NSColor.white : NSColor(hex: "#121212")
        window.isOpaque = true
        let host = NSHostingView(rootView: root)
        host.appearance = window.appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.backgroundColor = window.backgroundColor.cgColor
        window.contentView = host
        window.setContentSize(size)

        // SwiftUI builds its tree on the next runloop passes; the phase
        // animation needs one more beat to settle, and the status page's first
        // ps sample has to land or the process list renders empty.
        RunLoop.main.run(until: Date().addingTimeInterval(2.4))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("probe-render: no bitmap rep\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("probe-render: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-render: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-render: \(page) \(rep.pixelsWide)x\(rep.pixelsHigh) → \(outputPath)")
        exit(0)
    }
}
