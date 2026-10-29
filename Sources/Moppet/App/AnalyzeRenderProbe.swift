import AppKit
import SwiftUI

/// `--probe-analyze-render <path>`: renders the Analyze page — including the
/// centered delete-progress ring — into a PNG offscreen.
///
/// Screen recording is not always granted to a terminal-launched binary, so
/// `screencapture` fails ("could not create image from display"). Rendering the
/// hosting view's own layer tree needs no permission and no visible window,
/// which makes the ring's geometry checkable in CI and by hand.
@MainActor
enum AnalyzeRenderProbe {

    static func run(outputPath: String, appearance: String = "light") {
        // A synthetic in-flight batch: the ring is the whole point of the
        // probe, and a real delete would destroy files.
        AnalyzeView.debugSeed = (7, 12)

        let size = NSSize(width: 1180, height: 800)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        // Without an explicit appearance the dynamic theme tokens resolve
        // inconsistently offscreen (a light page with dark-mode ring colors),
        // so the render would not tell you what the app really looks like.
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: AnalyzeView())
        host.appearance = window.appearance
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)

        // SwiftUI builds its tree on the next runloop pass; the scan behind the
        // overlay is irrelevant to the ring, so two passes are plenty.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("probe-analyze-render: no bitmap rep\n".utf8))
            exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("probe-analyze-render: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-analyze-render: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-analyze-render: \(rep.pixelsWide)x\(rep.pixelsHigh) → \(outputPath)")
        exit(0)
    }
}
