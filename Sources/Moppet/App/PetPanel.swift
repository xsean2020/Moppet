import SwiftUI
import AppKit
import SceneKit
import Observation

/// Borderless panels refuse key status by default, which would starve the
/// quick-chat input of keyboard focus — override it (spotlight-style).
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reactive mirror of the pet panel's visibility for SwiftUI (the sidebar
/// footer's eye button). `PetPanelController.isVisible` is a plain computed
/// property on a non-observable class — reading it in a View body never
/// invalidates, so the icon went stale. Controllers call `set()` on show/hide.
@Observable
final class PetPanelVisibilityFlag {
    static let shared = PetPanelVisibilityFlag()
    var visible = false
}

/// Persistent pet-window preferences: scale, last frame, screen-following.
/// The pet used to reset to 250×400 in the bottom-right on every launch,
/// overwriting wherever the user had dragged it.
enum PetSettings {
    static let baseSize = NSSize(width: 250, height: 400)

    static var sizeScale: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: "pet.sizeScale")
            return v > 0 ? CGFloat(v) : 1.0
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "pet.sizeScale") }
    }

    static var followScreen: Bool {
        get { UserDefaults.standard.object(forKey: "pet.followScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pet.followScreen") }
    }

    static var savedFrame: NSRect? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "pet.frame"),
                  let frame = try? JSONDecoder().decode(NSRect.self, from: data) else { return nil }
            return frame
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "pet.frame")
            } else {
                UserDefaults.standard.removeObject(forKey: "pet.frame")
            }
        }
    }

    static var currentSize: NSSize {
        NSSize(width: baseSize.width * sizeScale, height: baseSize.height * sizeScale)
    }
}

/// airi-style desktop pet: a transparent, borderless, always-on-top panel
/// (stage-tamagotchi's window config: no frame, no shadow, floating level,
/// visible on all spaces) hosting the mole mascot. The panel is pure AppKit
/// and fully independent of the SwiftUI scene lifecycle — the pet keeps
/// running when every document window is closed, and can reopen them via
/// `WindowRouter`.
@MainActor
final class PetPanelController {

    static let shared = PetPanelController()

    private var panel: NSPanel?

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        PetPanelVisibilityFlag.shared.visible = true
        // The pet panel can present model questions (request_user_input).
        UserInputCenter.petSurfaceVisible = true
        // Safety net: if the first-frame reveal callback never fires
        // (SceneKit failure, unusual display setup), never leave the
        // panel stuck invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak panel] in
            if let panel, panel.alphaValue < 0.01 { panel.animator().alphaValue = 1 }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        UserInputCenter.petSurfaceVisible = false
        PetPanelVisibilityFlag.shared.visible = false
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Screen the pet panel currently sits on (for sibling floaters like the
    /// quick-chat bar that must appear next to the pet, not on NSScreen.main).
    var panelScreen: NSScreen? { panel?.screen }

    /// Multi-screen: the pet belongs on the same display as the app's main
    /// window — a pet stranded on another monitor reads as a bug. Moves the
    /// pet to the bottom-right of `target`; no-op when it's already there
    /// (keeps a user-dragged position on the matching screen untouched).
    /// Honors the user's "follow screen" setting (can be turned off so a
    /// hand-placed pet stays put).
    func relocateToScreen(_ target: NSScreen?) {
        guard PetSettings.followScreen else { return }
        guard let panel, panel.isVisible else { return }
        guard let screen = target ?? NSScreen.main, panel.screen !== screen else { return }
        Self.placeAtBottomRight(panel: panel, of: screen)
        PetSettings.savedFrame = panel.frame
    }

    /// The pet's anchor screen: whichever screen hosts the visible main/chat
    /// window (key window first), falling back to NSScreen.main at launch
    /// before any window exists.
    private func anchorScreen() -> NSScreen? {
        let tagged = NSApp.windows.filter {
            let id = $0.identifier?.rawValue
            return (id == WindowRouter.mainWindowID || id == WindowRouter.chatWindowID) && $0.isVisible
        }
        if let window = tagged.first(where: { $0.isKeyWindow }) ?? tagged.first {
            return window.screen ?? Self.bestScreen(for: window.frame)
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func placeAtBottomRight(panel: NSPanel, of screen: NSScreen) {
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - margin,
            y: visible.minY + margin   // visibleFrame already excludes Dock + menu bar
        )
        panel.setFrameOrigin(origin)
    }

    /// Screen with the largest overlap for a frame that misses every display
    /// (`window.screen` is nil for restored-onto-dead-space frames).
    private static func bestScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max {
            $0.frame.intersection(frame).width * $0.frame.intersection(frame).height
                < $1.frame.intersection(frame).width * $1.frame.intersection(frame).height
        }
    }

    private func buildPanel() {
        let size = PetSettings.currentSize
        let panel = PetPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        // fullScreenAuxiliary: visible over OTHER apps' fullscreen spaces
        // (canJoinAllSpaces alone doesn't cross fullscreen boundaries).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                     .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        // PetPanelHostingView (not plain NSHostingView): the panel can be
        // much wider than the mole while a wide answer is showing, and its
        // hitTest falls through everywhere except real content (mole,
        // bubble, cards) — see PetPanelHostingView.
        let view = PetPanelHostingView(rootView: PetView(panel: panel))
        panel.contentView = view

        // Restore the last dragged position when it still overlaps a real
        // display; otherwise park bottom-right of the anchor screen. The
        // saved frame can be WIDE/TALL (a big answer was showing at quit) —
        // bubble size is re-derived at runtime, so restore only the position
        // and the base size (right edge + bottom pinned, pet doesn't move).
        if let frame = PetSettings.savedFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            var restored = frame
            let size = PetSettings.currentSize
            restored.size = size
            restored.origin.x = frame.maxX - size.width
            restored.origin.y = frame.minY
            panel.setFrame(restored, display: false)
        } else if let screen = anchorScreen() {
            Self.placeAtBottomRight(panel: panel, of: screen)
        }
        self.panel = panel
        // Persist drags so relaunch keeps the pet where the user put it.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            PetSettings.savedFrame = panel.frame
        }
        // Reveal happens on the first rendered SceneKit frame (see
        // SceneReadyCoordinator) so the lazily-loaded pet never shows the
        // window's white backing store while the scene warms up.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    private var moveObserver: Any?

    /// Re-apply a new size scale (Settings): keep the bottom-right corner
    /// anchored so the pet "grows" in place.
    func applySizeScale(_ scale: CGFloat) {
        PetSettings.sizeScale = scale
        guard let panel else { return }
        let old = panel.frame
        let size = PetSettings.currentSize
        let newFrame = NSRect(
            x: old.maxX - size.width,
            y: old.minY,
            width: size.width,
            height: size.height
        )
        panel.setFrame(newFrame, display: true)
        PetSettings.savedFrame = newFrame
        // The hosting view's SwiftUI content reads currentSize in its frame
        // modifier — force a layout pass so it matches the new panel.
        if let content = panel.contentView {
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            content.needsDisplay = true
        }
    }
}

/// Reveals the pet panel after SceneKit rendered its first frame, wiping out
/// the "white rectangle → then transparent" flash during lazy load.
final class SceneReadyCoordinator: NSObject, SCNSceneRendererDelegate {
    private var revealed = false
    weak var scnView: NSView?

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard !revealed else { return }
        revealed = true
        // Rendering only happens for views already on screen, so the window
        // is guaranteed to be resolvable here.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.scnView?.window else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }
}

/// Central "open a SwiftUI window from anywhere" relay.
///
/// `openWindow` only exists inside SwiftUI scene contexts (RootView, ChatView,
/// MenuBarExtra content). Those register their closures here at `onAppear`;
/// AppKit surfaces (pet panel, notifications, Dock reopen) then route through
/// `showMain`/`showChat`. `openWindow(id:)` focuses an existing window or
/// **recreates** it when the user closed it — the fix for "main window never
/// comes back".
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    // nonisolated: window tags are immutable Sendable strings read from
    // AppKit contexts (pet panel placement, notification observers) too.
    nonisolated static let mainWindowID = "moppet-main"
    nonisolated static let chatWindowID = "moppet-chat"

    var openMainHandler: (() -> Void)?
    var openChatHandler: (() -> Void)?

    private var moveObservers: [NSObjectProtocol] = []

    init() {
        // Multi-screen follow: whenever a main/chat window moves or changes
        // display, bring the pet along so pet and window share a screen.
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            moveObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow,
                      let id = window.identifier?.rawValue,
                      id == Self.mainWindowID || id == Self.chatWindowID else { return }
                // queue: .main already delivers on the main thread; the Task
                // hop is for the isolation checker.
                Task { @MainActor in self?.syncPetScreen() }
            })
        }
    }

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMainHandler {
            openMainHandler()
        } else {
            focusExisting(Self.mainWindowID)
        }
        scheduleRepair()
    }

    func showChat() {
        NSApp.activate(ignoringOtherApps: true)
        if let openChatHandler {
            openChatHandler()
        } else {
            focusExisting(Self.chatWindowID)
        }
        scheduleRepair()
    }

    /// Move the pet to the display of the visible main/chat window (key
    /// window first). SwiftUI materializes `openWindow` targets a beat later,
    /// so callers run this after the repair delay too.
    func syncPetScreen() {
        let tagged = NSApp.windows.filter {
            let id = $0.identifier?.rawValue
            return (id == Self.mainWindowID || id == Self.chatWindowID) && $0.isVisible
        }
        guard let window = tagged.first(where: { $0.isKeyWindow }) ?? tagged.first else { return }
        let screen = window.screen
            ?? NSScreen.screens.max {
                $0.frame.intersection(window.frame).width * $0.frame.intersection(window.frame).height
                    < $1.frame.intersection(window.frame).width * $1.frame.intersection(window.frame).height
            }
        PetPanelController.shared.relocateToScreen(screen)
    }

    private func focusExisting(_ id: String) {
        for window in NSApp.windows
        where window.identifier?.rawValue == id && window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// macOS restores window frames by autosave name; if a display was
    /// disconnected since the last run, the restored frame points at dead
    /// space and the window "opens" invisibly. After any open/focus pass,
    /// drag such windows back onto a real screen.
    private func scheduleRepair() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.repairWindows()
            self?.syncPetScreen()
        }
    }

    func repairWindows() {
        for window in NSApp.windows
        where window.identifier?.rawValue == Self.mainWindowID
            || window.identifier?.rawValue == Self.chatWindowID {
            ensureOnScreen(window)
        }
    }

    /// True visibility check is geometry-only on purpose: a window on a
    /// background Space (normal for terminal-launched apps) is "not drawn"
    /// but perfectly fine — activating the app switches to its Space. Only a
    /// frame that misses every registered display (monitor unplugged since
    /// the frame was saved) needs rescuing; SwiftUI re-asserts its own
    /// geometry otherwise, so don't fight it.
    private func ensureOnScreen(_ window: NSWindow) {
        let overlapsScreen = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(window.frame)
            return overlap.width > 120 && overlap.height > 40
        }
        if debugWindows {
            FileHandle.standardError.write(Data((
                "win-debug repair? id=\(window.identifier?.rawValue ?? "?") overlaps=\(overlapsScreen)\n"
            ).utf8))
        }
        guard !overlapsScreen else { return }

        window.deminiaturize(nil)
        if let anchor = NSScreen.main ?? NSScreen.screens.first {
            var frame = window.frame
            frame.origin.x = anchor.visibleFrame.midX - frame.width / 2
            frame.origin.y = anchor.visibleFrame.midY - frame.height / 2
            window.setFrame(frame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// `--win-debug`: dump the AppKit view of window state to stderr.
    func debugDump() {
        let screens = NSScreen.screens.map { "\($0.frame)" }.joined(separator: " | ")
        FileHandle.standardError.write(Data((
            "win-debug screens: \(screens) | OcclusionState.visible raw=\(NSWindow.OcclusionState.visible.rawValue)\n"
        ).utf8))
        FileHandle.standardError.write(Data((
            "win-debug app: isActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow?.identifier?.rawValue ?? String(describing: NSApp.keyWindow)) "
            + "firstResponder=\(String(describing: NSApp.keyWindow?.firstResponder))\n"
        ).utf8))
        for window in NSApp.windows {
            let id = window.identifier?.rawValue ?? "(none)"
            guard id == Self.mainWindowID || id == Self.chatWindowID || window is PetPanel else { continue }
            FileHandle.standardError.write(Data((
                "win-debug id=\(id) frame=\(window.frame) visible=\(window.isVisible) "
                + "occlusion=\(window.occlusionState.rawValue) activeSpace=\(window.isOnActiveSpace) "
                + "mini=\(window.isMiniaturized) key=\(window.isKeyWindow)\n"
            ).utf8))
        }
    }

    /// `--win-debug` support: verbose repair decisions.
    private var debugWindows: Bool { CommandLine.arguments.contains("--win-debug") }
}

/// Quick scan shared by the menu-bar extra and the pet's quick menu.
enum QuickScan {
    @MainActor
    static func run() {
        PetBus.shared.say(L("Scanning…"), state: .scanning)
        Task {
            // Respect the user's Clean-page selection — this used to scan the
            // rule defaults, i.e. every item they had unchecked.
            var items = CleanSelectionStore.selectedItems()
            // Quick scan also covers the Trash. The rule is default-OFF in the
            // library (emptying it is destructive), but a quick scan is
            // READ-ONLY — it only sizes and reports, never deletes. A
            // deliberate untick of the Trash item is still respected.
            if CleanSelectionStore.all()["trash"] != false,
               let trash = RuleLibrary.sections.flatMap(\.items).first(where: { $0.id == "trash" }),
               !items.contains(where: { $0.id == "trash" }) {
                items.append(trash)
            }
            guard !items.isEmpty else {
                PetBus.shared.say(L("Nothing selected — open Clean and pick what to scan."), state: .idle)
                return
            }
            let findings = (await ScanEngine.scan(items: items)).flatMap(\.findings)
            let total = findings.reduce(0) { $0 + $1.bytes }
            let trashBytes = findings.filter { $0.itemID == "trash" }.reduce(0) { $0 + $1.bytes }
            // Report the scope so "only what I ticked" is visible, not assumed.
            // Trash is called out separately so its share is visible.
            var message = String(format: L("Scanned %1$lld categories · found %2$lld paths (%3$@)"),
                                 items.count, findings.count, total.bytesFormatted)
            if trashBytes > 0 {
                message += " · " + String(format: L("Trash %@"), trashBytes.bytesFormatted)
            }
            PetBus.shared.say(message, state: .celebrating)
        }
    }
}

/// App delegate: keeps the pet panel alive across scene lifecycle changes and
/// restores the MCP server at launch. The menu-bar item itself is a SwiftUI
/// `MenuBarExtra` (see MoppetApp) so it can reopen closed windows via
/// `openWindow`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var activateMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bare SPM binaries (no .app bundle) launched from a terminal never
        // get activated by the system: windows render and clicks pass
        // through, but the app never becomes "active" — so keyboard input is
        // never delivered (fields show a caret, typing does nothing) and the
        // first click after context-switching gets consumed by the failed
        // activation (the pet quick bar "sometimes opens"). Policy +
        // click-to-activate fixes both.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Modern minimal scrollbars app-wide (hairline indicator, hover/scroll
        // fade-in) — replaces the legacy gray track+knob look everywhere.
        ScrollbarTuner.install()
        activateMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            return event
        }
        PetPanelController.shared.show()
        MCPAppService.shared.restoreAtLaunch()
        // First launch: materialise the harness tree from the compiled-in seed
        // so the prompt is a file the user can read, diff and (later) edit.
        // Idempotent — an existing tree is never overwritten (design doc §9, P0).
        HarnessStore.ensureSeeded()
        // P3: the only timer that ever calls Evolver.tick. Both growth
        // switches default to off, so this is a no-op until the user opts in
        // (design doc §9.4 question 1).
        BrainGrowthScheduler.start()
        // Terminal-launched GUI apps start WITHOUT activation (isActive=false,
        // keyWindow=nil — verified via --win-debug): clicks still land
        // (click-through) but keyboard input goes nowhere. Activate properly
        // and key the main window.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == WindowRouter.mainWindowID }?
                .makeKeyAndOrderFront(nil)
        }
        // Repair windows restored onto disconnected displays (a restored
        // frame can point into dead space after a monitor unplug). Two
        // passes: the space assignment can settle after the first second.
        // Each pass also re-syncs the pet's screen: at show() time the main
        // window doesn't exist yet, so the pet parks on NSScreen.main while
        // macOS may put the main window on another display.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            WindowRouter.shared.repairWindows()
            WindowRouter.shared.syncPetScreen()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            WindowRouter.shared.repairWindows()
            WindowRouter.shared.syncPetScreen()
        }
        if CommandLine.arguments.contains("--win-debug") {
            // Periodic dump so post-click focus state (key window /
            // first responder) is captured for keyboard-focus debugging.
            func scheduleDump(_ delay: TimeInterval) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    WindowRouter.shared.debugDump()
                    scheduleDump(4.0)
                }
            }
            scheduleDump(5.0)
        }
    }

    /// The pet (and menu bar) outlive all document windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-click reopen brings the main window back even after it was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowRouter.shared.showMain() }
        return true
    }
}
