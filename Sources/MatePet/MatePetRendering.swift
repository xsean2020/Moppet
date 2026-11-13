import Foundation

/// The small surface the host uses to drive a desktop pet. There are two
/// implementations:
///
/// - `MatePetEngine` — WKWebView + three.js/three-vrm (macOS 14 compatible)
/// - `MatePetNativeEngine` — RealityKit + VRMRealityKit (macOS 15+)
///
/// Keeping this protocol separate from either renderer is what lets the panel,
/// interaction layer and Brain integration stay identical while the rendering
/// backend is chosen at runtime.
@MainActor
public protocol MatePetRendering: AnyObject {
    var onEvent: ((MatePetEvent) -> Void)? { get set }
    var isPageReady: Bool { get }

    func startIfNeeded()
    func setState(_ state: MatePetState)
    func setTalking(_ talking: Bool)
    func say(_ text: String, seconds: Double?)
    func look(atNormalizedX x: Double, y: Double)

    func dragBegan()
    func dragMoved(dx: Double, dy: Double)
    func dragEnded(vx: Double, vy: Double)

    func poke(region: MatePetHitRegion, count: Int)
    func play(_ action: MatePetAction)

    func setChibi(_ on: Bool)
    /// -1 = left, 0 = stop, +1 = right. The host moves the actual NSPanel.
    func setWalking(_ direction: Int)
    func setMuted(_ muted: Bool)
    func setPaused(_ paused: Bool)
    func audioUnlock()
    func syncPreferences()
}

public extension MatePetRendering {
    func say(_ text: String) { say(text, seconds: nil) }
}