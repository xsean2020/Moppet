import AppKit

/// App-wide minimal scrollbar treatment.
///
/// The stock look (legacy track + dark knob, or the auto-hiding overlay
/// sliver macOS shows while scrolling) reads as an industrial gray bar —
/// especially with an external mouse attached, which makes macOS fall back
/// to the ALWAYS-visible legacy style for every scroll view in the app.
///
/// This tuner replaces all of it, app-wide, with one modern style:
/// - native scrollers are removed at the AppKit level
/// - a custom hairline indicator (3pt, ~⅓ opacity) fades in while a view
///   is scrolling or the cursor is over the scroll area, thickens to 6pt
///   and brightens on hover, and fades back out ~0.7s after scrolling stops
/// - capsule shape, label-adaptive color (light/dark), soft fade/glide
///
/// It works by walking every window's view tree on `NSWindow.didUpdate`
/// (SwiftUI builds its NSScrollViews lazily — new pages keep appearing) and
/// instrumenting each `NSScrollView` exactly once: kill the native scroller,
/// drop a full-height hairline subview into the clip view, observe scroll &
/// layout notifications, self-heal if SwiftUI ever rebuilds the clip's
/// subviews (presence is re-checked on every pass).
enum ScrollbarTuner {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        // Even for views we never touch (native lists, future code), stop the
        // legacy always-visible track: registered defaults stay in the app
        // domain only — the user's system setting is untouched.
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "Overlay"])
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                instrument(window.contentView)
            }
        }
    }

    @MainActor
    private static func instrument(_ view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView {
            tune(scroll)
        }
        view.subviews.forEach(instrument)
    }

    @MainActor
    private static func tune(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        // RE-ASSERT on every pass: SwiftUI flips `hasVerticalScroller` back
        // to true whenever its content becomes scrollable (lazy data loads,
        // layout changes), which resurrected the native bar next to our
        // custom indicator — two scrollbars. Hiding is idempotent and cheap;
        // only the indicator insertion is once-per-scroll-view.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        // Self-healing presence check — SwiftUI may rebuild the clip's
        // subviews on state changes; the next didUpdate pass re-adds us.
        if clip.subviews.contains(where: { $0 is ScrollbarIndicatorView }) { return }
        clip.addSubview(ScrollbarIndicatorView(scrollView: scroll))
    }
}

/// The hairline indicator itself: a 9pt-wide, full-height strip pinned to the
/// clip view's trailing edge (non-interactive — `hitTest` returns nil). The
/// visible knob is a CALayer capsule; geometry (position/height) tracks the
/// scroll position INSTANTLY so it never lags the content, while opacity and
/// width fade with a short transaction.
@MainActor
final class ScrollbarIndicatorView: NSView {

    private weak var scrollView: NSScrollView?
    private let trackLayer = CALayer()
    private let knobLayer = CALayer()
    private var observers: [NSObjectProtocol] = []
    private var hideWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    // Metrics, recomputed on every scroll/layout pass.
    private var scrollable = false
    private var knobHeight: CGFloat = 32
    /// Knob's distance from the top of the strip (flipped coords).
    private var knobTop: CGFloat = 0
    private var visible = false
    private var prominent = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 1))
        wantsLayer = true
        trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        knobLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.32).cgColor
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(knobLayer)
        knobLayer.opacity = 0
        trackLayer.opacity = 0

        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollActivity() }
        })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.documentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollActivity() }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        hideWork?.cancel()
    }

    override var isFlipped: Bool { true }

    /// Never intercept clicks — the content underneath stays interactive.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        relayout()
    }

    /// Pin to the clip view's trailing edge, full height, and refresh the
    /// hover tracking area to cover the WHOLE scroll area (the owner receives
    /// mouseEntered/Exited for the rect even though it exceeds our frame).
    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        guard let clip = superview else { return }
        let clipBounds = clip.bounds
        frame = NSRect(x: clipBounds.width - frame.width, y: 0,
                       width: frame.width, height: clipBounds.height)
        let areaRect = NSRect(x: -frame.minX, y: 0,
                              width: clipBounds.width, height: clipBounds.height)
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: areaRect,
            options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        updateMetrics()
        render(animated: false)
    }

    private func scrollActivity() {
        updateMetrics()
        guard scrollable else {
            setVisible(false)
            return
        }
        setVisible(true)
        // Auto-hide shortly after scrolling stops — unless the cursor is
        // parked on the scroll area.
        guard !prominent else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setVisible(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func updateMetrics() {
        guard let scroll = scrollView, let document = scroll.documentView else {
            scrollable = false
            return
        }
        let clipHeight = scroll.contentView.bounds.height
        let contentHeight = document.frame.height
        scrollable = contentHeight > clipHeight + 1
        guard scrollable else { return }
        let ratio = clipHeight / contentHeight
        knobHeight = max(28, clipHeight * ratio)
        let maxOffset = max(1, contentHeight - clipHeight)
        let offset = scroll.documentVisibleRect.minY
        let position = min(1, max(0, offset / maxOffset))
        knobTop = position * max(0, clipHeight - knobHeight)
    }

    override func mouseEntered(with event: NSEvent) {
        prominent = scrollable
        if scrollable {
            hideWork?.cancel()
            setVisible(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        prominent = false
        setVisible(false)
    }

    private func setVisible(_ value: Bool) {
        guard visible != value || prominent else { return }
        visible = value
        render(animated: true)
    }

    /// Geometry (knob position/height) is applied WITHOUT animation so the
    /// knob hugs the content while scrolling; appearance (opacity, width)
    /// fades over a short transaction.
    private func render(animated: Bool) {
        guard layer != nil else { return }
        let width: CGFloat = prominent ? 6 : 3
        let inset: CGFloat = 2
        let show = visible && scrollable

        // Geometry — instant, so the knob hugs the content while scrolling.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let trackWidth = width + inset * 2
        trackLayer.frame = NSRect(x: bounds.width - trackWidth - inset, y: 0,
                                  width: trackWidth, height: bounds.height)
        trackLayer.cornerRadius = trackWidth / 2
        knobLayer.frame = NSRect(x: bounds.width - inset - width,
                                 y: knobTop,
                                 width: width,
                                 height: knobHeight)
        knobLayer.cornerRadius = width / 2
        CATransaction.commit()

        // Appearance — fade in/out, thicken-brighten on hover.
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        trackLayer.opacity = show && prominent ? 1 : 0
        knobLayer.opacity = show ? (prominent ? 0.55 : 0.32) : 0
        CATransaction.commit()
    }

    /// Light/dark switch — resolve the adaptive colors for the new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        trackLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        knobLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.32).cgColor
    }
}
