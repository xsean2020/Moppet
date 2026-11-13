import AppKit
import SwiftUI

/// Hosts the engine's WKWebView inside SwiftUI. The web view is created by the
/// engine (so it survives SwiftUI view rebuilds) and pinned to this container's
/// bounds.
public struct MatePetSceneView: NSViewRepresentable {
    public let engine: any MatePetRendering

    public init(engine: any MatePetRendering) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> NSView {
        if #available(macOS 15.0, *), let native = engine as? MatePetNativeEngine {
            // Install the spinner callback before the load can finish.
            let container = MatePetNativeContainerView(engine: native)
            native.startIfNeeded()
            return container
        }
        engine.startIfNeeded()
        if let web = engine as? MatePetEngine {
            return MatePetContainerView(engine: web)
        }
        return NSView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        engine.startIfNeeded()
    }
}

final class MatePetContainerView: NSView {
    let engine: MatePetEngine

    init(engine: MatePetEngine) {
        self.engine = engine
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 270))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let web = engine.webView
        web.frame = bounds
        web.autoresizingMask = [.width, .height]
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        engine.webView.frame = bounds
    }

    /// The sibling interaction view sits above this container and owns all
    /// pointer handling; the web view itself never needs AppKit hits.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}