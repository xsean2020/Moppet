import AppKit
import MatePet

/// Mate-Engine-style desktop locomotion. The avatar animation lives in the
/// MatePet module; moving the NSPanel is a host concern, so this controller
/// stays in the app target.
///
/// The pet walks for a few seconds every 20–45 s while it is idle. Walking
/// stops on any pointer interaction, when the panel is hidden, or when the
/// user turns Wander off. Speed is deliberately slow (≈42 pt/s): a desktop pet
/// crossing the screen while the user works is a nuisance, not a feature.
@MainActor
final class MatePetWander {

    static let shared = MatePetWander()

    private var ticker: Timer?
    private var walking = false
    private var direction: CGFloat = 1
    private var walkEndsAt = Date.distantPast
    private var nextWalkAt = Date().addingTimeInterval(24)
    private var lastInteraction = Date.distantPast
    private var lastTick = Date()
    private let speed: CGFloat = 42

    private init() {}

    /// Starts or stops the timer according to the persisted preference. Safe
    /// to call repeatedly (panel show, settings toggle, page ready).
    func refresh() {
        guard MatePetSettings.wander else {
            stopWalking()
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        scheduleNext()
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func noteInteraction() {
        lastInteraction = Date()
        stopWalking()
        scheduleNext()
    }

    /// Panel hidden: stop moving and stop the 30 Hz timer entirely.
    func suspend() {
        stopWalking()
        ticker?.invalidate()
        ticker = nil
    }

    func stopWalking() {
        guard walking else { return }
        walking = false
        walkEndsAt = .distantPast
        PetPanelController.shared.setPetWalking(0)
    }

    private func scheduleNext() {
        nextWalkAt = Date().addingTimeInterval(TimeInterval.random(in: 20...44))
    }

    private func tick() {
        guard MatePetSettings.wander else { refresh(); return }
        guard let panel = PetPanelController.shared.petPanel, panel.isVisible else {
            stopWalking()
            return
        }
        // Do not move the window while the user is actively dragging it, or
        // within 8 seconds of any click; the pet must never fight the hand.
        guard NSEvent.pressedMouseButtons == 0,
              Date().timeIntervalSince(lastInteraction) > 8,
              PetBus.shared.state == .idle,
              !QuickChat.shared.panelVisible else { return }

        let now = Date()
        let dt = min(0.12, max(0.001, now.timeIntervalSince(lastTick)))
        lastTick = now

        if walking {
            if now >= walkEndsAt {
                stopWalking()
                scheduleNext()
                return
            }
            guard let screen = panel.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            var frame = panel.frame
            let nextX = frame.origin.x + direction * speed * CGFloat(dt)
            let minX = visible.minX + 6
            let maxX = visible.maxX - frame.width - 6
            if nextX < minX || nextX > maxX {
                stopWalking()
                scheduleNext()
                return
            }
            frame.origin.x = min(max(nextX, minX), maxX)
            panel.setFrameOrigin(frame.origin)
            return
        }

        guard now >= nextWalkAt else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        // Prefer a direction with room; reverse at the edge instead of
        // pressing into it.
        direction = Bool.random() ? 1 : -1
        if direction < 0 && frame.minX < visible.minX + 70 { direction = 1 }
        if direction > 0 && frame.maxX > visible.maxX - 70 { direction = -1 }

        frame.origin.y = min(max(frame.origin.y, visible.minY + 6),
                             visible.maxY - frame.height - 6)
        panel.setFrameOrigin(frame.origin)

        walking = true
        walkEndsAt = now.addingTimeInterval(TimeInterval.random(in: 2.6...5.2))
        PetPanelController.shared.setPetWalking(direction > 0 ? 1 : -1)
    }
}