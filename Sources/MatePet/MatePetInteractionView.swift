import AppKit
import SwiftUI

/// AppKit interaction layer that sits on top of the WKWebView. It owns every
/// pointer gesture so the pet behaves identically whether Moppet is active or
/// in the background (the panel is a non-activating floater):
///
/// - drag → moves the NSPanel and feeds velocity to the page's sway spring
/// - move → feeds normalized coordinates to the page's head/eye look-at
/// - click / double-click / right-click → host closures + poke reactions
/// - cursor → pointing hand, deterministically in every app-activation state
public struct MatePetInteractionView: NSViewRepresentable {
    public weak var panel: NSPanel?
    public let engine: any MatePetRendering
    public var onTap: () -> Void
    public var onDoubleTap: () -> Void
    public var onInteraction: (() -> Void)?
    public var buildMenu: () -> NSMenu

    public init(panel: NSPanel?,
                engine: any MatePetRendering,
                onTap: @escaping () -> Void,
                onDoubleTap: @escaping () -> Void,
                onInteraction: (() -> Void)? = nil,
                buildMenu: @escaping () -> NSMenu) {
        self.panel = panel
        self.engine = engine
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.onInteraction = onInteraction
        self.buildMenu = buildMenu
    }

    public func makeNSView(context: Context) -> MatePetInteractionNSView {
        let view = MatePetInteractionNSView()
        configure(view)
        return view
    }

    public func updateNSView(_ view: MatePetInteractionNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: MatePetInteractionNSView) {
        view.panel = panel
        view.engine = engine
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        view.onInteraction = onInteraction
        view.buildMenu = buildMenu
    }
}

public final class MatePetInteractionNSView: NSView {
    weak var panel: NSPanel?
    var engine: (any MatePetRendering)?
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onInteraction: (() -> Void)?
    var buildMenu: (() -> NSMenu)?

    private var mouseDownPoint: NSPoint = .zero
    private var dragOrigin: NSPoint?
    private var pendingSingleClick: DispatchWorkItem?

    private var lastDragSampleTime: TimeInterval = 0
    private var lastDragSamplePoint: NSPoint = .zero
    private var lastDragSentTime: TimeInterval = 0
    private var lastDragSentPoint: NSPoint = .zero
    private var velocity: (x: Double, y: Double) = (0, 0)

    private var lastPokeTime: TimeInterval = 0
    private var headPokeCount = 0

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // mouseMoved only reaches a view whose window opted in.
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    public override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    public override func mouseMoved(with event: NSEvent) {
        feedLook(event)
    }

    public override func mouseEntered(with event: NSEvent) {
        window?.acceptsMouseMovedEvents = true
        feedLook(event)
    }

    public override func mouseExited(with event: NSEvent) {
        // Drift back to camera centre instead of snapping the head.
        engine?.look(atNormalizedX: 0.5, y: 0.5)
    }

    private func feedLook(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let w = max(1, bounds.width)
        let h = max(1, bounds.height)
        engine?.look(atNormalizedX: Double(point.x / w), y: Double(point.y / h))
    }

    public override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation
        dragOrigin = panel?.frame.origin
        lastDragSamplePoint = mouseDownPoint
        lastDragSampleTime = event.timestamp
        lastDragSentPoint = mouseDownPoint
        lastDragSentTime = 0
        velocity = (0, 0)
        pendingSingleClick?.cancel()
        onInteraction?()
        engine?.audioUnlock()
        engine?.dragBegan()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let panel, let dragOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - mouseDownPoint.x
        let dy = now.y - mouseDownPoint.y
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy))

        // Velocity in points/second, using NSEvent's monotonic timestamp.
        let dt = event.timestamp - lastDragSampleTime
        if dt > 0.0001 {
            let vx = Double((now.x - lastDragSamplePoint.x) / CGFloat(dt))
            let vy = Double((now.y - lastDragSamplePoint.y) / CGFloat(dt))
            velocity = (velocity.x * 0.35 + vx * 0.65, velocity.y * 0.35 + vy * 0.65)
            lastDragSampleTime = event.timestamp
            lastDragSamplePoint = now
        }

        // 60 Hz is plenty for the sway spring; sending every trackpad event
        // would spam evaluateJavaScript across the WebKit bridge.
        if lastDragSentTime == 0 || event.timestamp - lastDragSentTime >= 1.0 / 60.0 {
            lastDragSentTime = event.timestamp
            let step = NSEvent.mouseLocation
            engine?.dragMoved(dx: Double(step.x - lastDragSentPoint.x),
                              dy: Double(step.y - lastDragSentPoint.y))
            lastDragSentPoint = step
        }
    }

    public override func mouseUp(with event: NSEvent) {
        pendingSingleClick?.cancel()
        let moved = hypot(NSEvent.mouseLocation.x - mouseDownPoint.x,
                          NSEvent.mouseLocation.y - mouseDownPoint.y)
        clampPanelOnScreen()

        if moved >= 6 {
            engine?.dragEnded(vx: velocity.x, vy: velocity.y)
            return
        }

        // Tap: drop the drag hold first so the poke pose is not competing
        // with the drag pose, then dispatch the host's click semantics.
        engine?.dragEnded(vx: 0, vy: 0)

        let point = convert(event.locationInWindow, from: nil)
        let region: MatePetHitRegion = point.y > bounds.height * 0.52 ? .head : .body
        let now = event.timestamp
        if region == .head && now - lastPokeTime < 1.6 {
            headPokeCount += 1
        } else {
            headPokeCount = 1
        }
        lastPokeTime = now
        engine?.poke(region: region, count: headPokeCount)
        if headPokeCount >= 3 {
            engine?.play(.pet)
        }

        if event.clickCount >= 2 {
            onDoubleTap?()
        } else {
            let task = DispatchWorkItem { [weak self] in self?.onTap?() }
            pendingSingleClick = task
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval,
                                          execute: task)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let menu = buildMenu?() else { return }
        menu.popUp(positioning: nil,
                   at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// Keep a dragged pet recoverable: at least a sliver stays inside the
    /// current screen's visible frame. Applied on mouse-up only so dragging
    /// itself never feels sticky.
    private func clampPanelOnScreen() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let sliver: CGFloat = 56
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x, visible.minX - frame.width + sliver),
                             visible.maxX - sliver)
        frame.origin.y = min(max(frame.origin.y, visible.minY - frame.height + sliver),
                             visible.maxY - sliver)
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }
}