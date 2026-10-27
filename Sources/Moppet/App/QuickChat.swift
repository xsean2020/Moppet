import Foundation
import AppKit
import SwiftUI
import MarkdownUI
import Observation

/// Spotlight-style quick chat: single-click the pet pops an input-only bar
/// centered on screen. The bar STAYS after submitting — follow-up questions
/// type straight in while the answer streams into the pet's speech bubble;
/// it closes on click-away / Esc / clicking the pet again. Runs on its own
/// BrainAgent — the rollout lands in the same session directory, so quick
/// chats show up in the chat window's session list and keep full context.
@MainActor
@Observable
final class QuickChat {
    static let shared = QuickChat()

    private(set) var brain = BrainAgent()
    /// A quick-chat turn is streaming/running.
    private(set) var active = false
    /// Whether the centered input bar is shown.
    private(set) var panelVisible = false
    /// Accumulated answer for the pet-bubble tail.
    private(set) var answerText = ""

    private let panelController = QuickChatPanelController()

    private init() {
        brain.onEvent = { [weak self] event in
            // Brain events can arrive from background executors.
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    /// Toggle the input bar: click the pet again to dismiss.
    func toggleInput() {
        panelVisible ? hideInput() : showInput()
    }

    func showInput() {
        // Order matters for IME: activate + makeKey FIRST, then flip
        // panelVisible so the TextField's focus request flows through
        // onChange while the panel is already key and the app active.
        // The old order (focus flag first, onAppear focus during
        // buildPanel) asked IMK for a keyboard channel from a background
        // app — "error messaging the mach port for IMKCFRunLoopWakeUpReliable"
        // in the log, and dropped Chinese composition on first open.
        panelController.show()
        panelVisible = true
    }

    func hideInput() {
        panelVisible = false
        panelController.hide()
    }

    func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !active else { return }
        // Pre-flight: the old path submitted unconfigured requests and let the
        // SDK surface a raw error 8s later, with no path to fix it.
        if !AISettings.load().isConfigured {
            PetBus.shared.say(L("No AI provider configured yet — open Settings to add an API key or sign in."),
                              state: .talking, hideAfter: 12)
            WindowRouter.shared.showMain()
            NotificationCenter.default.post(name: .moppetNavigateSettings, object: nil)
            return
        }
        // Slash commands run locally (codex TUI parity) — output goes to the
        // pet bubble; UI-only ones point at the chat window. The bar stays:
        // only click-away / Esc / pet-reclick close it.
        if trimmed.hasPrefix("/") {
            let command = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            Task { @MainActor in
                let result = await BrainSlash.run(trimmed, brain: brain)
                    ?? String(format: L("%@ is chat-window only — double-click the pet to open it"), command)
                PetBus.shared.say(Self.bubbleTail(result), state: .talking, hideAfter: 10)
            }
            return
        }
        // Pick up provider/model changes made anywhere (chat window, Settings)
        // since this agent was created.
        brain.refreshModel()
        // Bar stays open — the follow-up can be typed while this turn streams
        // (send() gates on `active`, so Return during a stream keeps the draft).
        answerText = ""
        active = true
        // Pet poses busy, but the bubble stays silent until the answer: the
        // bubble shows RESULTS only, never tool calls or progress text.
        PetBus.shared.setState(.thinking)
        Task {
            await brain.submit(trimmed)
            active = false
        }
    }

    func stop() {
        guard active else { return }
        brain.cancel()
    }

    private func handle(_ event: BrainEvent) {
        switch event {
        case .assistantMessageDelta(let delta):
            answerText += delta
            PetBus.shared.say(Self.bubbleTail(answerText), state: .talking, hideAfter: 0)
        case .toolStarted:
            // Result-only bubble: no "🔧 tool…" text. The pet still shows a
            // working pose so the turn doesn't look dead during long tool runs.
            PetBus.shared.setState(.cleaning)
        case .toolFinished:
            break
        case .turnCompleted(let output, let usage):
            let final = output ?? answerText
            answerText = final
            let tk = usage.map { " · \($0.totalTokens) tk" } ?? ""
            PetBus.shared.say(Self.bubbleTail(final, suffix: tk),
                              state: .celebrating, hideAfter: 12)
        case .error(let message):
            answerText = "✗ \(message)"
            // 12s (was 8) + the bubble's double-click → chat window gives the
            // user somewhere to take the failed turn.
            PetBus.shared.say("✗ \(message)", state: .sad, hideAfter: 12)
        default:
            break
        }
    }

    /// The bubble is a small overlay — show only the tail of long answers
    /// (the full text stays in the chat window's rollout). Markdown markers
    /// are kept: the pet bubble renders them (MarkdownUI).
    private static func bubbleTail(_ text: String, suffix: String = "") -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 320 else { return trimmed + suffix }
        return "…" + String(trimmed.suffix(320)) + suffix
    }
}

// MARK: - Centered input bar (AppKit host)

/// Borderless panel that can take keyboard focus without activating the app
/// (`canBecomeKey` is false by default for borderless panels — without the
/// override the TextField never receives keystrokes).
final class QuickChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    func centerOnScreen() {
        // Appear on the pet's display (the thing the user just clicked) —
        // NSScreen.main multi-screen resolves to the key window's screen,
        // which can be a different monitor from the pet.
        guard let screen = PetPanelController.shared.panelScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY + visible.height * 0.18
        ))
    }
}

@MainActor
final class QuickChatPanelController {
    private var panel: QuickChatPanel?
    /// Click-outside dismissal: local monitor catches clicks in our own
    /// windows, global monitor catches clicks in other apps / the desktop.
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        panel.centerOnScreen()
        installDismissMonitors()
        // Key events — and crucially the input-method server (IME): a key
        // window's text field that reaches IMK from a background app logs
        // "mach port for IMKCFRunLoopWakeUpReliable" errors and can drop
        // composition (Chinese input) — only reliably reach our windows when
        // Moppet is the ACTIVE app. No-op when we're already front.
        NSApp.activate(ignoringOtherApps: true)
        // Nonactivating + key: takes keystrokes without stealing app focus.
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeDismissMonitors()
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let panel = QuickChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above every normal/floating window of any app (the bar pops over
        // whatever the user is working in), below menus and popovers.
        panel.level = .statusBar
        // fullScreenAuxiliary: also show over OTHER apps' fullscreen spaces
        // (canJoinAllSpaces alone doesn't cross fullscreen boundaries).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                     .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: QuickChatInputView())
        self.panel = panel
    }

    private func installDismissMonitors() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Clicks inside the pet panel belong to its tap gestures (toggle);
            // everything else in our windows dismisses.
            if !(event.window is PetPanel), event.window !== self?.panel {
                self?.hide()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeDismissMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

// MARK: - Input bar UI

struct QuickChatInputView: View {
    @State private var quick = QuickChat.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            PetStickerAvatar(size: 26)
            // Single line on purpose: the host panel is a fixed 560×64 bar, so
            // a growing (axis: .vertical) field would wrap into clipped space
            // — long input scrolls horizontally, Spotlight-style.
            TextField(L("Ask me anything…"), text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Airi.neutral900)
                .focused($focused)
                .onSubmit { send() }
            CircleIconButton(icon: quick.active ? "stop.fill" : "arrow.up.circle.fill") {
                if quick.active { quick.stop() } else { send() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 560)
        // Same card recipe as SettingsCard — dynamic cardBackground adapts to
        // the system appearance (light frosted / dark translucent) and the
        // adaptive TextField text stays readable in both.
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(Airi.cardBackground)
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
        )
        .onExitCommand { quick.hideInput() }
        .onChange(of: quick.panelVisible) { _, visible in
            if visible { focused = true }
        }
        // No onAppear focus: the panel is built BEFORE show() activates the
        // app — focusing here hits IMK from a background app (see showInput).
    }

    private func send() {
        // Gate BEFORE clearing: `quick.submit` is a silent no-op while a
        // previous turn streams (button shows stop), so an ungated Return
        // would swallow the typed text. Keep the draft; it can be sent once
        // the current turn finishes.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !quick.active else { return }
        draft = ""
        quick.submit(trimmed)
    }
}
