import AppKit
import SwiftUI

/// `--probe-sidebar <path> [light|dark] [height]`: renders the navigation
/// panel into a PNG offscreen.
///
/// The sidebar's spacing ladder (brand-row clearance, band gaps, row height,
/// pill inset, icon stroke weight) is a pixel judgement call, and
/// `screencapture` needs a screen-recording grant a terminal-launched binary
/// usually lacks. A view can always render its own layer tree, so this needs
/// no permission and no visible window — every tweak can be checked by eye
/// instead of by guesswork.
///
/// The panel is hosted standalone rather than inside a `NavigationSplitView`:
/// an offscreen split view never lays out its sidebar column (empty column,
/// spinner in the detail). The panel is what this probe is about; the column's
/// chrome is the system's business. The host window still uses the app's own
/// style mask (`.fullSizeContentView` + transparent titlebar), so the render
/// carries the same 32pt titlebar safe-area inset the real sidebar sits under
/// — which is exactly the inset the brand row has to clear.
@MainActor
enum SidebarRenderProbe {

    static func runPanel(outputPath: String, appearance: String = "light",
                         height: CGFloat = 700) {
        let size = NSSize(width: 224, height: height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Without an explicit appearance the dynamic theme tokens resolve
        // inconsistently offscreen (light surface with dark-mode text), so the
        // render would not show what the app really looks like.
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

        let host = NSHostingView(rootView: SidebarPanel(route: .constant(.clean)))
        host.appearance = window.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)

        // SwiftUI builds its tree on the next runloop pass.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()

        guard let rep = bitmap(size: size, scale: 2) else {
            FileHandle.standardError.write(Data("probe-sidebar: no bitmap rep\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("probe-sidebar: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-sidebar: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-sidebar: \(rep.pixelsWide)x\(rep.pixelsHigh) → \(outputPath)")
        exit(0)
    }

    /// 2x bitmap: the app ships on Retina, where a 1.5pt symbol stroke lands on
    /// two device pixels and stops looking washed out. A 1x probe would make
    /// every thin glyph look lighter than it does in the real window, and the
    /// whole point here is judging stroke weight.
    private static func bitmap(size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        return rep
    }
}
