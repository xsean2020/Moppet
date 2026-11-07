import AppKit
import SwiftUI

/// Set by the render probes: macOS 26's Glass `NSSwitch` paints no ON fill
/// into an offscreen layer tree (`cacheDisplay` draws only the knob-less
/// track), so every probe render showed enabled switches stuck off — a bug
/// report against the app that is really a report against the probe. Toggle
/// call sites render the hand-drawn `ProbeSwitch` stand-in while this is on;
/// on screen the system control is untouched.
@MainActor
enum ProbeRendering {
    nonisolated(unsafe) static var enabled = false
}

/// Offscreen stand-in for `.toggleStyle(.switch)`: capsule track + white knob
/// at the system `.small` metrics, drawn from colors that survive
/// `cacheDisplay` (Airi tokens — the same ones every other card renders with).
struct ProbeSwitch: View {
    let isOn: Bool
    var tint: Color = .accentColor
    var controlSize: ControlSize = .small

    var body: some View {
        let trackSize: (CGFloat, CGFloat) = {
            switch controlSize {
            case .mini: return (36, 18)
            case .small: return (38, 22)
            default: return (44, 26)
            }
        }()
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.10)))
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            Circle()
                .fill(Color.white)
                .frame(width: trackSize.1 - 4, height: trackSize.1 - 4)
                .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: trackSize.0, height: trackSize.1)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

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
        let root = makeRoot(page: page, expandFirst: expandFirst)
        render(root, outputPath: outputPath, appearance: appearance,
               width: 1180, height: max(600, height))
    }

    /// Shared page builder: `--probe-render` (bare page) and `--probe-window`
    /// (sidebar + page) both come through here, so a new probe page only
    /// lands once.
    static func makeRoot(page: String, expandFirst: Bool) -> AnyView {
        switch page {
        case "home", "dashboard":
            // Demo identity + demo numbers: a published screenshot must not
            // carry the local account name, provider roster or audit log.
            HomeView.debugSeed = true
            HomeView.debugUserName = "Alex"
            return AnyView(HomeView(navigate: { _ in }, openChat: {}))
        case "clean":
            if expandFirst { CleanView.debugExpandFirstSection = true }
            return AnyView(CleanView())
        case "optimize":
            return AnyView(OptimizeView())
        case "status":
            StatusView.debugSeed = true
            // `expanded` pre-selects the CPU quadrant so the render also
            // covers the click-through detail card.
            if expandFirst { StatusView.debugSelectedQuadrant = .cpu }
            return AnyView(StatusView())
        case "spacehogs":
            SystemHogsView.debugSeed = true
            return AnyView(SystemHogsView())
        case "startup":
            LaunchItemsView.debugSeed = true
            return AnyView(LaunchItemsView())
        case "settings":
            return AnyView(SettingsView())
        default:
            FileHandle.standardError.write(
                Data("probe-render: unknown page '\(page)' — use clean|optimize|status|spacehogs|startup|settings\n".utf8))
            exit(2)
        }
    }

    /// Offscreen window + bitmap + PNG write, shared by both probes.
    static func render(_ root: AnyView, outputPath: String, appearance: String,
                       width: CGFloat, height: CGFloat) {
        ProbeRendering.enabled = true   // NSSwitch paints no ON fill offscreen
        let size = NSSize(width: width, height: max(600, height))
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
        print("probe-render: \(rep.pixelsWide)x\(rep.pixelsHigh) → \(outputPath)")
        exit(0)
    }
}

/// `--probe-window <page> <png> [light|dark] [h=N]`: renders the complete
/// window — sidebar navigation beside the page — into a PNG offscreen.
///
/// `NavigationSplitView` never lays out its sidebar column offscreen (see
/// SidebarRenderProbe for that investigation), so the window is assembled by
/// hand: the real `SidebarPanel` beside the real page over the app's page
/// background. This is the shape the README gallery uses, where readers need
/// to see where each page lives in the navigation.
@MainActor
enum WindowRenderProbe {

    static func run(page: String, outputPath: String, appearance: String = "light",
                    height: CGFloat = 820, expandFirst: Bool = false) {
        let route: Route
        switch page {
        case "home", "dashboard": route = .dashboard
        case "clean": route = .clean
        case "optimize": route = .optimize
        case "status": route = .status
        case "spacehogs": route = .hogs
        case "startup": route = .startup
        case "settings": route = .settings
        default:
            FileHandle.standardError.write(
                Data("probe-window: unknown page '\(page)' — use clean|optimize|status|spacehogs|startup|settings\n".utf8))
            exit(2)
        }

        let root = PageRenderProbe.makeRoot(page: page, expandFirst: expandFirst)
        let sidebarWidth: CGFloat = 224
        let contentWidth: CGFloat = 960
        let totalHeight = max(600, height)
        PageRenderProbe.render(
            AnyView(
                HStack(spacing: 0) {
                    SidebarPanel(route: .constant(route))
                        .frame(width: sidebarWidth)
                    Divider()
                    ZStack {
                        Airi.pageBackground
                        root
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: sidebarWidth + contentWidth, height: totalHeight)
            ),
            outputPath: outputPath, appearance: appearance,
            width: sidebarWidth + contentWidth, height: totalHeight)
    }
}
