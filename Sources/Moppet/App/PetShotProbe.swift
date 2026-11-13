import AppKit
import MatePet

/// `--probe-pet-shot <png> [width height]`: renders the MatePet WKWebView into
/// a transparent PNG offscreen.
///
/// The old probe used `SCNView.snapshot()`; the MatePet renderer is WebGL
/// inside WKWebView, so the equivalent is `WKWebView.takeSnapshot`. A real
/// (but transparent, mouse-ignoring) window is required because WebKit only
/// paints views attached to a window. No screen-recording permission is
/// involved: the snapshot comes from the web view's own compositor.
@MainActor
enum PetShotProbe {

    static func run(outputPath: String,
                    width: CGFloat = 460,
                    height: CGFloat = 540,
                    state: String? = nil,
                    chibi: Bool = false) {
        let engine = MatePetEngine()
        var pngData: Data?
        var finished = false
        engine.onSnapshot = { data in
            pngData = data
            finished = true
        }
        var modelReady = false
        var failure: String?
        engine.onEvent = { event in
            switch event {
            case .modelReady:
                modelReady = true
                print("probe-pet-shot: model ready")
            case .loadError(let message):
                failure = message
            case .ready:
                print("probe-pet-shot: page ready")
            case .log(let message):
                print("probe-pet-shot: log: \(message)")
            default:
                break
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        engine.webView.frame = container.bounds
        engine.webView.autoresizingMask = [.width, .height]
        container.addSubview(engine.webView)
        window.contentView = container

        // Park it on-screen while the compositor warms up; it is fully
        // transparent and ignores clicks, so it cannot disturb the user.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 24,
                                          y: screen.visibleFrame.minY + 24))
        }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        engine.startIfNeeded(probeMode: true, probeState: state, probeChibi: chibi)

        let deadline = Date().addingTimeInterval(30)
        while !modelReady && failure == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let failure {
            FileHandle.standardError.write(Data("probe-pet-shot: \(failure)\n".utf8))
            engine.stop()
            window.close()
            exit(1)
        }
        guard modelReady else {
            FileHandle.standardError.write(Data("probe-pet-shot: VRM did not finish loading\n".utf8))
            engine.stop()
            window.close()
            exit(1)
        }

        // Let the first animation frame and the camera easing settle.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        // The page self-captures when loaded with ?probe=1; no native → JS
        // command is involved (see mate-pet.html captureCanvas()).
        let snapshotDeadline = Date().addingTimeInterval(25)
        while !finished && Date() < snapshotDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        defer {
            engine.stop()
            window.close()
        }

        guard let pngData, !pngData.isEmpty else {
            FileHandle.standardError.write(Data("probe-pet-shot: snapshot failed\n".utf8))
            exit(1)
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write(
                Data("probe-pet-shot: write failed — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("probe-pet-shot: \(Int(width))x\(Int(height)) → \(outputPath)")
        exit(0)
    }
}