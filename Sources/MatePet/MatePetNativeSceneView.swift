import AppKit
import RealityKit
import SwiftUI

/// SwiftUI host for the native RealityKit renderer. Only compiled/instantiated
/// on macOS 15+, because VRMRealityKit's renderer has that deployment floor.
@available(macOS 15.0, *)
struct MatePetNativeSceneContent: View {
    let engine: MatePetNativeEngine

    var body: some View {
        RealityView { content in
            content.add(engine.renderRoot)
        }
        .background(Color.clear)
    }
}

@available(macOS 15.0, *)
final class MatePetNativeContainerView: NSView {
    private let host: NSHostingView<MatePetNativeSceneContent>
    private let spinner = NSProgressIndicator()

    init(engine: MatePetNativeEngine) {
        host = NSHostingView(rootView: MatePetNativeSceneContent(engine: engine))
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 270))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(spinner)
        spinner.startAnimation(nil)

        engine.onModelReady = { [weak self] in
            self?.spinner.stopAnimation(nil)
            self?.spinner.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}