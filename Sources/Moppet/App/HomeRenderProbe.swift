import AppKit
import SwiftUI

/// `--probe-home <path> [light|dark] [width] [height]`: renders the dashboard
/// into a PNG offscreen.
///
/// The dashboard is a pixel judgement call (card row heights, the metric
/// ladder, badge legibility) and `screencapture` needs a screen-recording
/// grant a terminal-launched binary usually lacks. Hosting the view directly
/// lets us inspect the real layout without a visible window.
@MainActor
enum HomeRenderProbe {

    static func run(outputPath: String, appearance: String = "light",
                    width: CGFloat = 780, height: CGFloat = 640) {
        let size = NSSize(width: width, height: height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

        // Real window: the glass sits on the app's page background. Offscreen
        // the NSWindow default is white, which made every dark-mode render
        // look washed out, so paint the page colour behind the dashboard.
        let host = NSHostingView(rootView: ZStack {
            Airi.pageBackground
            HomeView(navigate: { _ in }, openChat: {})
        })
        host.appearance = window.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)

        // SwiftUI builds its tree (and the async history/session loads)
        // on later runloop passes.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("probe-home: no bitmap rep\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("probe-home: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-home: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-home: \(rep.pixelsWide)x\(rep.pixelsHigh) → \(outputPath)")
        exit(0)
    }
}
