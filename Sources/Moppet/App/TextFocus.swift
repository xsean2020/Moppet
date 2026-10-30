import AppKit

/// Text fields may only take focus once the app is ACTIVE and the window that
/// hosts them is KEY.
///
/// Focusing earlier makes AppKit open an input-method session from a
/// background context. macOS then logs, on behalf of this process:
///
///   error messaging the mach port for IMKCFRunLoopWakeUpReliable
///   TSM AdjustCapsLockLEDForKeyTransitionHandling - _ISSetPhysicalKeyboardCapsLockLED Inhibit
///
/// Both lines are diagnostics (nothing crashes), but they are also a reliable
/// signal that we focused too early — and in that state the first keystroke of
/// a Chinese composition can be swallowed, because the IME session was created
/// before the app owned the keyboard.
///
/// The old code used a fixed `DispatchQueue.main.async` hop, which is one run
/// loop too early whenever the window was opened while Moppet was in the
/// background (`openWindow` is asynchronous and activation lands after it).
/// This helper polls the real conditions instead of guessing a delay.
@MainActor
enum TextFocus {

    /// Calls `focus` as soon as `isReady()` is true, polling every 50ms for
    /// ~3s. Gives up silently after that: a user who switched away mid-open
    /// will click the field themselves, and stealing focus later would be
    /// worse than not focusing at all.
    static func whenReady(_ isReady: @escaping () -> Bool,
                          attempts: Int = 60,
                          _ focus: @escaping () -> Void) {
        func attempt(_ remaining: Int) {
            if isReady() {
                focus()
                return
            }
            guard remaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                attempt(remaining - 1)
            }
        }
        attempt(attempts)
    }
}
