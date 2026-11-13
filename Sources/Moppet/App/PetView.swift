import SwiftUI
import AppKit
import MarkdownUI
import MatePet

// MARK: - Pet interaction (AppKit layer)

/// Invisible marker view: "this rectangle is real, clickable content".
/// Attached as a background to the bubble / question / approval cards; the
/// avatar's MatePetInteractionNSView doubles as its own marker.
final class HitRegionView: NSView {}

struct HitRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> HitRegionView { HitRegionView() }
    func updateNSView(_ view: HitRegionView, context: Context) {}
}

/// Hosting view for the pet panel. The panel can be MUCH wider than the avatar
/// while a wide answer is showing (adaptive bubble width) — the empty
/// transparent space must fall through to the apps underneath instead of
/// swallowing clicks. A click only belongs to Moppet when it lands on real
/// content (a hit-region marker or the avatar interaction layer).
final class PetPanelHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        // `point` arrives in the superview's coordinate space.
        let local = convert(point, from: superview)
        return containsHitRegion(local) ? super.hitTest(point) : nil
    }

    private func containsHitRegion(_ point: NSPoint) -> Bool {
        func walk(_ view: NSView) -> Bool {
            if view is HitRegionView || view is MatePetInteractionNSView,
               view.bounds.contains(view.convert(point, from: self)) {
                return true
            }
            return view.subviews.contains(where: walk)
        }
        return walk(self)
    }
}

/// NSMenuItem does not retain its target — a subclass keeps the closure alive
/// for as long as the menu (and its items) live.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unsupported") }

    @objc private func fire() { handler() }
}

/// Markdown body of the speech bubble. Extracted so it can be laid out
/// offscreen by `--probe-pet-bubble` (the bubble has regressed twice on
/// sizing; the probe measures real laid-out heights).
struct PetBubbleContent: View {
    let message: String
    let width: CGFloat

    var body: some View {
        // Markdown("") lays out as nothing, which is exactly the empty card
        // this bubble must never show — fall back to the hint text.
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PetBus.emptyAnswerHint : message
        Markdown(text)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(12)
                ForegroundColor(Airi.neutral900)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Scroll metrics reported by the bubble's scrolling viewport.
private struct BubbleContentMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var offset: CGFloat = 0
}

private struct BubbleContentMetricsKey: PreferenceKey {
    static var defaultValue = BubbleContentMetrics()
    static func reduce(value: inout BubbleContentMetrics, nextValue: () -> BubbleContentMetrics) {
        value = nextValue()
    }
}

private struct BubbleViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Coordinate space shared by SlimScrollView's offset reader (statics are not
/// allowed on generic types).
private enum BubbleScrollSpace {
    static let name = "petBubbleScroll"
}

/// Vertical ScrollView with a SLIM custom indicator. The system overlay thumb
/// (wide capsule + groove) read as a heavy bar inside the small speech card —
/// this one is a 3pt rounded sliver that only appears while the content
/// actually overflows, and tracks the scroll position smoothly.
struct SlimScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var metrics = BubbleContentMetrics()
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: BubbleContentMetricsKey.self,
                            value: BubbleContentMetrics(
                                contentHeight: geo.size.height,
                                offset: -geo.frame(in: .named(BubbleScrollSpace.name)).minY))
                    }
                )
        }
        .coordinateSpace(name: BubbleScrollSpace.name)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: BubbleViewportHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(BubbleContentMetricsKey.self) { metrics = $0 }
        .onPreferenceChange(BubbleViewportHeightKey.self) { viewportHeight = $0 }
        .overlay(alignment: .trailing) { indicator }
        // Scrolling content must not paint past the card's rounded corners.
        .clipShape(RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous))
    }

    private var overflow: CGFloat { metrics.contentHeight - viewportHeight }

    @ViewBuilder
    private var indicator: some View {
        if overflow > 1, viewportHeight > 0, metrics.contentHeight > 0 {
            let track = viewportHeight - 12
            let length = max(28, track * viewportHeight / metrics.contentHeight)
            let fraction = overflow > 0
                ? min(1, max(0, metrics.offset / overflow))
                : 0
            Capsule()
                .fill(Airi.neutral400.opacity(0.5))
                .frame(width: 3, height: length)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.vertical, 6)
                .padding(.trailing, 3)
                .offset(y: fraction * max(0, track - length))
                .animation(.easeOut(duration: 0.12), value: fraction)
                .allowsHitTesting(false)
        }
    }
}

/// The speech-bubble card exactly as the pet renders it: hug short answers,
/// scroll long ones, never taller than `maxHeight`.
struct PetBubbleCard: View {
    let message: String
    let width: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            // Concrete height: a greedy ScrollView would make the whole
            // ViewThatFits flexible and the parent VStack would stretch the
            // bubble to fill the panel for even two lines of text.
            SlimScrollView { content }
                .frame(height: maxHeight)
        }
        .frame(width: width)
        // Marks the card as clickable content for PetPanelHostingView's
        // pass-through hit-testing (the panel is wider than the mole).
        .petCardSurface(border: Airi.neutral200.opacity(0.6))
    }

    private var content: some View {
        PetBubbleContent(message: message, width: width)
    }
}

/// `--probe-pet-bubble`: lay the bubble out inside a pet-panel-sized VStack
/// (mole replaced by a flexible filler) and print the height it actually
/// gets. Short text must hug its content; long text must stop at the cap.
/// The second pass mirrors the REAL layout chain (card + reserved mole strip)
/// and asserts the mole keeps its height — the "pet disappeared behind a wide
/// answer" regression — and that card and mole strip share a center line:
/// the pet must sit mid-bubble, left-right symmetric.
@MainActor
enum PetBubbleProbe {
    /// Named coordinate space the card/mole centers are measured in (the
    /// probe's panel-sized VStack).
    static let chainSpace = "petBubbleProbeChain"

    private final class Store {
        var heights: [String: CGFloat] = [:]
        var moleHeights: [String: CGFloat] = [:]
        var natural: [String: CGFloat] = [:]
        var cardCenterX: [String: CGFloat] = [:]
        var moleCenterX: [String: CGFloat] = [:]
    }

    static func run() -> Never {
        let store = Store()
        let cases: [(CGFloat, CGFloat)] = [(200, 320), (250, 400)]
        let texts: [(String, String)] = [
            ("short", "嗨！我是 Zome ✨ 点我聊天 · 双击开完整窗口"),
            ("long", String(repeating: "很长的回答内容需要滚动才能看完。", count: 40)),
        ]
        for (panelW, panelH) in cases {
            for (label, text) in texts {
                let key = "\(label) \(Int(panelW))x\(Int(panelH))"
                let width = PetView.bubbleWidth(for: text, maxWidth: panelW - 24)
                let cap = max(96, min(208, panelH * 0.62))
                let host = NSHostingView(rootView:
                    VStack(spacing: 4) {
                        PetBubbleCard(message: text, width: width, maxHeight: cap)
                            .background(GeometryReader { g in
                                Color.clear.onAppear {
                                    store.heights[key] = g.size.height
                                }
                            })
                        Color.clear.frame(maxHeight: .infinity)
                    }
                    .frame(width: panelW, height: panelH)
                )
                host.frame = NSRect(x: 0, y: 0, width: panelW, height: panelH)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                print("probe \(key): bubbleH=\(Int(store.heights[key] ?? -1)) cap=\(Int(cap)) "
                      + "width=\(Int(width)) fits=\((store.heights[key] ?? 999) <= cap)")

                // --- Full chain: does the mole survive a long answer? ---
                let moleH = max(120, panelH - 130)
                let naturalHost = NSHostingView(rootView:
                    PetBubbleContent(message: text, width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { store.natural[key] = g.size.height }
                        })
                )
                naturalHost.frame = NSRect(x: 0, y: 0, width: width, height: 2000)
                naturalHost.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                let natural = store.natural[key] ?? 60
                let cardH = min(max(natural + 2, 48), max(80, panelH - moleH - 10))
                let targetH = max(panelH, cardH + 4 + moleH + 6)
                let fullHost = NSHostingView(rootView:
                    VStack(spacing: 4) {
                        PetBubbleCard(message: text, width: width, maxHeight: cardH)
                            .background(GeometryReader { g in
                                Color.clear.onAppear {
                                    store.heights[key] = g.size.height
                                    store.cardCenterX[key] =
                                        g.frame(in: .named(Self.chainSpace)).midX
                                }
                            })
                        Color.clear
                            .aspectRatio(230.0 / 270.0, contentMode: .fit)
                            .frame(maxWidth: max(120, panelW - 20),
                                   maxHeight: max(120, panelH - 130))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 10)
                            .layoutPriority(-1)
                            .background(GeometryReader { g in
                                Color.clear.onAppear {
                                    store.moleHeights[key] = g.size.height
                                    store.moleCenterX[key] =
                                        g.frame(in: .named(Self.chainSpace)).midX
                                }
                            })
                    }
                    .coordinateSpace(name: Self.chainSpace)
                    .frame(width: panelW, height: targetH)
                )
                fullHost.frame = NSRect(x: 0, y: 0, width: panelW, height: targetH)
                fullHost.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let mole = store.moleHeights[key] ?? -1
                let estimate = PetView.bubbleHeight(for: text, width: width)
                let drift = abs((store.cardCenterX[key] ?? -1) - (store.moleCenterX[key] ?? -2))
                print("probe \(key): cardH=\(Int(cardH)) panelH=\(Int(targetH)) "
                      + "moleH=\(Int(mole)) moleKept=\(mole >= moleH - 2) "
                      + "natural=\(Int(natural)) estimate=\(Int(estimate)) "
                      + "centerDrift=\(String(format: "%.1f", drift)) symmetric=\(drift < 0.5)")
            }
        }
        let allHeights = store.heights.count == cases.count * texts.count
        let moleKept = store.moleHeights.values.allSatisfy { $0 >= 118 }
        var allSymmetric = true
        for (key, cardX) in store.cardCenterX {
            let moleX = store.moleCenterX[key] ?? cardX - 10
            if abs(cardX - moleX) >= 0.5 { allSymmetric = false }
        }
        exit(allHeights && moleKept && allSymmetric ? 0 : 2)
    }
}

// MARK: - Pet view (MatePet avatar + bubble + quick chat)

struct PetView: View {
    weak var panel: NSPanel?
    let engine: any MatePetRendering
    /// Probe hook (`--probe-pet-panel`): replace the launch greeting with the
    /// long probe answer so it cannot be overwritten after the panel appears.
    static var debugLongAnswerOnAppear = false

    @State private var bus = PetBus.shared
    @State private var bubbleVisible = false
    @State private var bubbleHideTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            userInputCard
            approvalCard
            bubble
            ZStack {
                MatePetSceneView(engine: engine)
                // AppKit interaction layer on top of the WebGL scene; it owns
                // every pointer gesture so WKWebView never fights for events.
                MatePetInteractionView(
                    panel: panel,
                    engine: engine,
                    onTap: {
                        if bubbleVisible {
                            // Click during a visible bubble means "dismiss
                            // it" — same effect as the auto-hide (cancel the
                            // pending timer, drop the bubble, settle talking
                            // back to idle). The input bar is NOT toggled:
                            // closing a bubble and opening a bar in one tap
                            // reads as a glitch. During a streaming turn the
                            // dismissal also covers the rest of the turn —
                            // every token used to pop the bubble right back.
                            bubbleHideTask?.cancel()
                            withAnimation(Airi.controlAnimation) { bubbleVisible = false }
                            if bus.state == .talking { bus.setState(.idle) }
                            bus.dismissStreaming()
                            bus.noteBubbleHidden()   // 任务摘要被点掉：后续进度保持安静
                        } else if bus.state == .celebrating || bus.state == .sad {
                            // Click during a celebration or a sad moment
                            // means "got it" — settle back to idle.
                            bus.settle()
                        } else if bus.state == .sleeping {
                            // A click on a sleeping pet wakes it (the old
                            // path ignored Sleep — the pet napped forever).
                            bus.say(L("Awake! ✨"), state: .talking)
                        } else {
                            QuickChat.shared.toggleInput()
                        }
                    },
                    onDoubleTap: {
                        WindowRouter.shared.showChat()
                    },
                    onInteraction: {
                        MatePetWander.shared.noteInteraction()
                    },
                    buildMenu: petMenu
                )
            }
            // Keep the avatar's canonical 230×270 viewport: when a tall answer
            // squishes the vertical space the scene shrinks UNIFORMLY, so the
            // camera keeps the full body in frame instead of switching to a
            // landscape frustum that clips the feet.
            .aspectRatio(230.0 / 270.0, contentMode: .fit)
            .frame(maxWidth: max(120, PetSettings.currentSize.width - 20),
                   maxHeight: max(120, PetSettings.currentSize.height - 130))
            // The bubble card is centered in the panel, so the avatar rides the
            // panel's center too (symmetric 10pt side margins). The panel still
            // widens LEFTWARD (right edge pinned), so a wide answer glides
            // the pet left to stay centered instead of pushing it off-screen.
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 10)
            // The bubble/approval card win the vertical budget first; the
            // avatar flexes shorter while a long answer is up.
            .layoutPriority(-1)
        }
        .frame(width: targetPanelWidth,
               height: targetPanelHeight)
        .onChange(of: targetPanelSize) { _, size in
            syncPanelSize(size)
        }
        .onChange(of: bus.messageID) { _, _ in
            bubbleHideTask?.cancel()
            withAnimation(Airi.controlAnimation) { bubbleVisible = true }
            let interval = bus.messageHideInterval ?? bus.autoHideInterval
            engine.say(bus.message, seconds: interval > 0 ? interval : nil)
            engine.setTalking(bus.state == .talking)
            // 0 = keep the bubble until the next say() (streaming answers).
            guard interval > 0 else { return }
            bubbleHideTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(Airi.controlAnimation) { bubbleVisible = false }
                engine.setTalking(false)
                if bus.state == .talking { bus.setState(.idle) }
                bus.noteBubbleHidden()   // 摘要气泡到时隐藏：失去显示面
            }
        }
        .onChange(of: bus.state) { _, newState in
            engine.setState(newState.matePetState)
            engine.setTalking(newState == .talking)
        }
        .onAppear {
            if Self.debugLongAnswerOnAppear {
                let long = String(
                    repeating: "这是一段很长的回答内容，用来验证气泡变宽变高时宠物依然完整显示。",
                    count: 10)
                bus.say(long, state: .talking, hideAfter: 0)
                return
            }
            bus.say(String(format: L("Hi! I'm %@ ✨  Click to chat · double-click for the full window"),
                           PetIdentity.name),
                    state: .talking)
        }
    }

    /// Right-click menu (was SwiftUI .contextMenu — also activation-sensitive).
    private func petMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("Quick Scan")) { QuickScan.run() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Chat")) { WindowRouter.shared.showChat() })
        menu.addItem(ClosureMenuItem(title: L("Main Window")) { WindowRouter.shared.showMain() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Dance")) { engine.play(.dance) })
        menu.addItem(ClosureMenuItem(title: L("Wave")) { engine.play(.wave) })
        menu.addItem(ClosureMenuItem(title: L("Stretch")) { engine.play(.stretch) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: MatePetSettings.chibi ? L("Chibi Mode: On") : L("Chibi Mode: Off")) {
            engine.setChibi(!MatePetSettings.chibi)
        })
        menu.addItem(ClosureMenuItem(title: MatePetSettings.wander ? L("Wander: On") : L("Wander: Off")) {
            MatePetSettings.wander = !MatePetSettings.wander
            MatePetWander.shared.refresh()
        })
        menu.addItem(ClosureMenuItem(title: MatePetSettings.muted ? L("Sound: Off") : L("Sound: On")) {
            engine.setMuted(!MatePetSettings.muted)
        })
        menu.addItem(.separator())
        // Sleep is a toggle: the old menu only ever put the pet to sleep,
        // with no way back (settle() ignores .sleeping).
        if bus.state == .sleeping {
            menu.addItem(ClosureMenuItem(title: L("Wake")) {
                PetBus.shared.say(L("Awake! ✨"), state: .talking)
            })
        } else {
            menu.addItem(ClosureMenuItem(title: L("Sleep")) {
                PetBus.shared.say("Zzz…", state: .sleeping)
            })
        }
        menu.addItem(ClosureMenuItem(title: L("Hide Pet")) {
            PetPanelController.shared.hideWithAnimation()
        })
        return menu
    }

    // MARK: Speech bubble

    /// Measured bubble TEXT width for `message`, clamped to `maxWidth`:
    /// a short message sits compactly on one line, a long one wraps at the
    /// available width. MarkdownUI's own ideal width is unreliable for this,
    /// so the width is estimated per character (CJK/emoji/fullwidth ≈ 13pt
    /// at font 12, ASCII ≈ 7.2pt) over the longest line.
    ///
    /// The old version capped the card at the 250pt pet panel; a long answer
    /// wrapped into a skinny strip that was hard to read. `maxWidth` now
    /// derives from the room between the pet's right edge and the screen's
    /// left edge, so the bubble can stretch toward the screen edge.
    static func bubbleWidth(for message: String, maxWidth: CGFloat) -> CGFloat {
        func lineWidth(_ line: Substring) -> CGFloat {
            line.reduce(CGFloat(0)) { acc, ch in
                acc + (ch.unicodeScalars.first.map { $0.value > 0x2E80 ? 13 : 7.2 } ?? 7.2)
            }
        }
        let longest = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(lineWidth)
            .max() ?? 0
        let cap = max(96, maxWidth)
        return min(cap, max(80, longest + 22))
    }

    /// Widest the bubble TEXT may get: the room from the panel's right edge
    /// to 16pt from the screen's left edge — mirroring the pet's own 16pt
    /// right margin, so both sides stay consistent — with a readability
    /// ceiling of 560pt (≈ 40 CJK characters per line at font 12). Falls
    /// back to the base panel width when no screen can be resolved.
    private var maxBubbleTextWidth: CGFloat {
        let base = PetSettings.currentSize.width - 24
        guard let panel else { return base }
        let visible = panel.screen?.visibleFrame ?? panel.frame
        let room = panel.frame.maxX - visible.minX - 16 - 24
        return max(base, min(560, room))
    }

    /// Never lay out a blank card: `PetBus` already substitutes a hint for an
    /// empty message, this is the view-side guard (probe paths, future
    /// callers). Width, height and content all read THIS, so a blank message
    /// can't produce a wide empty bubble either.
    private var bubbleMessage: String {
        bus.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PetBus.emptyAnswerHint : bus.message
    }

    private var bubbleWidth: CGFloat {
        Self.bubbleWidth(for: bubbleMessage, maxWidth: maxBubbleTextWidth)
    }

    /// Panel width the layout wants: the base pet size while the bubble is
    /// hidden, wide enough for the whole bubble card while it shows.
    private var targetPanelWidth: CGFloat {
        guard bubbleVisible else { return PetSettings.currentSize.width }
        // The queue nav can be wider than a very short bubble; reserve its
        // width so the panel never clips the capsule.
        let nav: CGFloat = bus.showingTaskAnswer && bus.taskAnswerCount > 1 ? 150 : 0
        return max(PetSettings.currentSize.width, max(bubbleWidth, nav) + 24)
    }

    // MARK: Vertical budget
    //
    // The mole's strip is RESERVED, never negotiable: a wide card made long
    // answers fit without scrolling, ViewThatFits then handed the whole panel
    // height to the card and squeezed the mole into a 50pt sliver (the "pet
    // disappeared" report). Instead the panel GROWS UPWARD — bottom edge
    // pinned so the pet stays put — and only when the screen runs out does the
    // card start scrolling.

    /// Height kept for the mole (its canonical 270pt at the default scale).
    private var moleHeight: CGFloat {
        max(120, PetSettings.currentSize.height - 130)
    }

    /// Room left for the card: everything between the mole's strip and 8pt
    /// below the screen's top edge, with a design ceiling so a giant answer
    /// can't turn the pet into a full-screen reader (it scrolls instead).
    private var bubbleHardCap: CGFloat {
        let designCeiling = max(300, PetSettings.currentSize.height * 1.3)
        guard let panel else { return designCeiling }
        let visible = panel.screen?.visibleFrame ?? panel.frame
        let room = visible.maxY - 8 - panel.frame.minY - moleHeight - 10
        return max(120, min(designCeiling, room))
    }

    /// Card height: the ESTIMATED content height (hugs short answers, shows
    /// whole long ones) capped by the room above the mole's strip. The card
    /// itself never exceeds this (ViewThatFits switches to scrolling), so a
    /// sloppy estimate can only cost a little extra scrolling — it can never
    /// squeeze the mole out of the panel again.
    private var bubbleCardHeight: CGFloat {
        guard bubbleVisible else { return 1 }
        let estimate = Self.bubbleHeight(for: bubbleMessage, width: bubbleWidth)
        return min(max(estimate, 48), bubbleHardCap)
    }

    /// Estimated laid-out height of `message` in the bubble (font 12
    /// MarkdownUI basic theme): wraps every line at the card's text width,
    /// charges 17.5pt per wrapped line, 3pt between blocks and the card's
    /// 14pt vertical padding, then a 6% safety margin.
    ///
    /// A deterministic estimate is used on purpose: the panel resizes itself
    /// while SwiftUI lays it out, and preference-based measurement never
    /// updated past the first layout pass in that setup (verified with
    /// `--probe-pet-panel`), which left the card eating the mole's height.
    static func bubbleHeight(for message: String, width: CGFloat) -> CGFloat {
        let textWidth = max(60, width - 20)
        let lineHeight: CGFloat = 17.5
        var height: CGFloat = 14          // card vertical padding (7 × 2)
        var blocks = 0
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            // List items are indented by the marker gutter (~16pt) and get
            // their own block spacing.
            let isListItem = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("+ ") || trimmed.first?.isNumber == true && trimmed.contains(". ")
            let indent: CGFloat = isListItem ? 16 : 0
            let usable = max(40, textWidth - indent)
            let lineWidth = line.reduce(CGFloat(0)) { acc, ch in
                acc + (ch.unicodeScalars.first.map { $0.value > 0x2E80 ? 12.2 : 6.9 } ?? 6.9)
            }
            let wrapped = max(1, ceil(lineWidth / usable))
            height += wrapped * lineHeight
            if !trimmed.isEmpty {
                blocks += 1
                if blocks > 1 { height += 3 }
            }
        }
        return height * 1.06 + 4
    }

    private var targetPanelHeight: CGFloat {
        guard bubbleVisible else { return PetSettings.currentSize.height }
        let nav: CGFloat = bus.showingTaskAnswer && bus.taskAnswerCount > 1 ? 30 : 0
        return max(PetSettings.currentSize.height,
                   bubbleCardHeight + nav + 4 + moleHeight + 6)
    }

    private var targetPanelSize: CGSize {
        CGSize(width: targetPanelWidth, height: targetPanelHeight)
    }

    /// Resize the hosting panel so the layout's target size becomes real. The
    /// RIGHT edge and BOTTOM stay pinned — the panel grows leftward and
    /// upward, into the empty desktop area. Horizontally the pet rides the
    /// panel's center (it must sit mid-bubble), so a wide answer glides it
    /// left; the pinned right edge keeps the whole bubble on screen.
    ///
    /// The frame change is ANIMATED: an instant snap shrinks the window before
    /// the bubble's fade-out has played, clipping the card mid-animation —
    /// the vanish read as a choppy collapse. A short ease matches the
    /// bubble's spring closely enough that card and window move as one.
    private func syncPanelSize(_ size: CGSize) {
        guard let panel else { return }
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        let target = NSRect(x: frame.maxX - size.width, y: frame.minY,
                            width: size.width, height: size.height)
        // Streaming answers resize the panel repeatedly — an in-flight window
        // animation is superseded by the next target, never queued up.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.setFrame(target, display: true)
        }
    }

    /// Viewport height for a long answer when the screen itself is the limit
    /// (kept for the bubble probe / smoke test).
    static func bubbleHeightCap(panelHeight: CGFloat) -> CGFloat {
        max(96, min(208, panelHeight * 0.62))
    }

    private var taskAnswerStatusIcon: String {
        switch bus.currentTaskAnswer?.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        default: "stop.circle.fill"
        }
    }

    private var taskAnswerStatusColor: Color {
        switch bus.currentTaskAnswer?.status {
        case "completed": Airi.success
        case "failed": Airi.danger
        default: Airi.neutral400
        }
    }

    /// 任务结果队列导航：仅在有多条结果时出现，一次只看一条。
    private var taskAnswerNav: some View {
        HStack(spacing: 8) {
            Image(systemName: taskAnswerStatusIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(taskAnswerStatusColor)

            Button { bus.previousTaskAnswer() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!bus.canGoPreviousTaskAnswer)
            .help(L("Previous task result"))

            Text("\(bus.taskAnswerIndex + 1) / \(bus.taskAnswerCount)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())

            Button { bus.nextTaskAnswer() } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!bus.canGoNextTaskAnswer)
            .help(L("Next task result"))
        }
        .foregroundStyle(Airi.neutral700)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // The nav sits outside the card, so it needs its own hit region —
        // otherwise the pet panel's pass-through hitTest treats it as empty
        // desktop and the next/prev buttons never receive the click.
        .background(HitRegion())
        .background(Capsule().fill(Airi.cardBackground))
        .overlay(Capsule().strokeBorder(Airi.neutral200.opacity(0.7), lineWidth: 1))
    }

    private var bubble: some View {
        Group {
            if bubbleVisible {
                VStack(spacing: 4) {
                    if bus.showingTaskAnswer && bus.taskAnswerCount > 1 {
                        taskAnswerNav
                    }
                    // Markdown rendering — AI answers arrive as markdown
                    // (bold, lists, code) and leaked literal markers as plain
                    // Text ("**最快的办法：**"). Same engine as the chat
                    // window's transcript.
                    // Full answer, never clipped: a lineLimit(12) cut long
                    // answers mid-sentence (read as "the bubble is broken").
                    // ViewThatFits keeps short messages hugging their content
                    // and only switches to a scrolling viewport when the text
                    // would overflow the height budget.
                    PetBubbleCard(message: bubbleMessage,
                                  width: bubbleWidth,
                                  maxHeight: bubbleCardHeight)
                }
                // Double-click the bubble → full chat window (which has a
                // real close button in its header). contentShape keeps the
                // hit target alive now that the body is a ViewThatFits.
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    WindowRouter.shared.showChat()
                }
            } else {
                Color.clear.frame(height: 1)
            }
        }
        // Dissolve toward the pet: the card fades while shrinking slightly
        // into the center bottom, where the mole's head is (the pet is
        // centered under the bubble). A bare removal just blinks — with no
        // anchor the collapse reads as the bubble being sucked sideways by
        // the window resize.
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        .animation(Airi.controlAnimation, value: bubbleVisible)
    }

    // MARK: Inline model questions (pet-side mirror of the chat sheet)

    /// request_user_input on the pet panel: compact option chips per
    /// question; the full free-text "Other" flow lives in the chat sheet.
    /// Answers accumulate locally; the last question's answer submits all.
    @State private var petAnswers: [String: String] = [:]
    @State private var answeredRequestID: UUID?

    private var userInputCard: some View {
        Group {
            if let request = UserInputCenter.shared.pending {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("Quick question"), systemImage: "questionmark.bubble.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Airi.neutral900)
                    ForEach(request.questions) { question in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(question.question)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Airi.neutral800)
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                    Button {
                                        answerPet(question: question, answer: option.label, request: request)
                                    } label: {
                                        Text(option.label)
                                            .font(.system(size: 10, weight: .medium))
                                            .lineLimit(1)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(petAnswers[question.id] == option.label
                                                    ? Airi.primary.opacity(0.2) : Airi.neutral100)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Button {
                        WindowRouter.shared.showChat()
                    } label: {
                        Label(L("Answer in chat…"), systemImage: "bubble.left.and.bubble.right")
                            .font(Airi.caption2Font)
                            .foregroundStyle(Airi.primary)
                    }
                    .buttonStyle(.plain)
                    Text(L("Auto-dismisses after 5 minutes"))
                        .font(Airi.caption2Font)
                        .foregroundStyle(Airi.neutral400)
                }
                .padding(8)
                .frame(width: 236, alignment: .leading)
                .petCardSurface(border: Airi.primary.opacity(0.4))
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                .onAppear {
                    if answeredRequestID != request.id {
                        petAnswers = [:]
                        answeredRequestID = request.id
                    }
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8),
                   value: UserInputCenter.shared.pending == nil)
    }

    private func answerPet(question: UserInputQuestion, answer: String, request: UserInputRequest) {
        petAnswers[question.id] = answer
        // All questions answered → submit; otherwise wait for the rest.
        let answered = request.questions.allSatisfy { petAnswers[$0.id]?.isEmpty == false }
        if answered {
            request.respond(petAnswers)
        }
    }

    // MARK: Inline approval (pet-side mirror of the chat approval sheet)

    private var approvalCard: some View {
        Group {
            if let request = ApprovalCenter.shared.pending {
                VStack(alignment: .leading, spacing: 4) {
                    Label(request.title, systemImage: "shield.lefthalf.filled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Airi.neutral900)
                        .lineLimit(2)
                    Text(request.detail)
                        .font(Airi.monoCaption2Font)
                        .foregroundStyle(Airi.neutral700)
                        .lineLimit(4)
                    HStack(spacing: Airi.space2) {
                        // Approve is the affirmative action — primary color.
                        // The old destructive-red Approve read as "dangerous"
                        // and invited misclicks against macOS conventions
                        // (confirm = main color); risk lives in the title,
                        // detail and the red hairline.
                        AiriButton(title: L("Deny"), variant: .secondary) { request.respond(false) }
                        AiriButton(title: L("Approve"), variant: .primary) { request.respond(true) }
                    }
                }
                .padding(8)
                .frame(width: 236, alignment: .leading)
                .petCardSurface(border: Airi.danger.opacity(0.4))
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8),
                   value: ApprovalCenter.shared.pending == nil)
    }
}

// MARK: - Pet card surface

/// Shared chrome for the floating pet cards: click-through hit region,
/// rounded fill + shadow, and a one-pixel tinted border.
private struct PetCardSurface: ViewModifier {
    let border: Color

    func body(content: Content) -> some View {
        content
            .background(HitRegion())
            .background(
                RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                    .fill(Airi.cardBackground)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

private extension View {
    func petCardSurface(border: Color) -> some View {
        modifier(PetCardSurface(border: border))
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}


// MARK: - PetState → MatePet mapping

extension PetState {
    /// The MatePet module deliberately does not import Moppet's Core types;
    /// the app maps its richer bus state onto the renderer's small vocabulary.
    var matePetState: MatePetState {
        switch self {
        case .idle: return .idle
        case .thinking: return .thinking
        case .talking: return .talking
        case .scanning: return .scanning
        case .cleaning: return .cleaning
        case .celebrating: return .celebrating
        case .sleeping: return .sleeping
        case .sad: return .sad
        }
    }
}
