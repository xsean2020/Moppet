import SwiftUI
import AppKit
import SceneKit
import MarkdownUI

// MARK: - Procedural 3D mole puppet (SceneKit, always visible, no network)

/// The pet's 3D body — a procedural mole built from SceneKit primitives with
/// per-state animations. Native rendering (no web view / CDN), so the pet is
/// guaranteed to show up. airi's idle_loop.vrma stays bundled for a future
/// VRM skin pipeline.
final class MolePuppet {

    let scene = SCNScene()
    let root = SCNNode()          // whole-mole group (state animations here)
    let body = SCNNode()          // breathing/sway animations here
    let nose: SCNNode
    let eyes: [SCNNode]
    /// Ears + tail join every state animation (they used to be build-only
    /// decorations — the "pet states feel unfinished" gap).
    private(set) var ears: [SCNNode] = []
    private(set) var tail: SCNNode?
    private var baseEarPoses: [SCNVector3] = []   // per-ear position/scale snapshot
    private var baseTailPose: SCNVector3 = SCNVector3(0, 0, 0)
    private var state: PetState = .idle

    init() {
        scene.background.contents = NSColor.clear

        func material(_ color: NSColor, roughness: CGFloat = 0.85) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .physicallyBased
            m.roughness.contents = roughness
            m.metalness.contents = 0.0
            return m
        }
        let fur = material(NSColor(hex: "8A6A52"))
        let bellyMat = material(NSColor(hex: "C9B29B"))
        let pink = material(NSColor(hex: "E8A0A8"), roughness: 0.5)
        let dark = material(NSColor(hex: "2A2118"), roughness: 0.35)
        let cream = material(NSColor(hex: "E8DCC8"))

        // body
        let bodyGeo = SCNSphere(radius: 0.34)
        bodyGeo.materials = [fur]
        body.geometry = bodyGeo
        body.scale = SCNVector3(1, 1.12, 1)

        let tummy = SCNNode(geometry: {
            let g = SCNSphere(radius: 0.22); g.materials = [bellyMat]; return g
        }())
        tummy.position = SCNVector3(0, -0.02, 0.17)
        tummy.scale = SCNVector3(1, 1.2, 0.72)
        body.addChildNode(tummy)

        // snout + nose
        let snout = SCNNode(geometry: {
            let g = SCNSphere(radius: 0.10); g.materials = [fur]; return g
        }())
        snout.position = SCNVector3(0, 0.06, 0.30)
        body.addChildNode(snout)

        nose = SCNNode(geometry: {
            let g = SCNSphere(radius: 0.045); g.materials = [pink]; return g
        }())
        nose.position = SCNVector3(0, 0.08, 0.38)
        body.addChildNode(nose)

        // eyes (blink by y-scale)
        var eyeNodes: [SCNNode] = []
        for side in [-1.0, 1.0] {
            let eye = SCNNode(geometry: {
                let g = SCNSphere(radius: 0.028); g.materials = [dark]; return g
            }())
            eye.position = SCNVector3(Float(0.10 * side), 0.14, 0.28)
            body.addChildNode(eye)
            eyeNodes.append(eye)
        }
        eyes = eyeNodes

        // ears
        for side in [-1.0, 1.0] {
            let ear = SCNNode(geometry: {
                let g = SCNSphere(radius: 0.06); g.materials = [pink]; return g
            }())
            ear.position = SCNVector3(Float(0.20 * side), 0.24, 0.02)
            ear.scale = SCNVector3(1, 1.25, 0.7)
            ear.name = side < 0 ? "ear-left" : "ear-right"
            body.addChildNode(ear)
            ears.append(ear)
            baseEarPoses.append(SCNVector3(ear.position.x, ear.position.y, ear.position.z))
        }

        // digging claws
        for side in [-1.0, 1.0] {
            for i in -1...1 {
                let claw = SCNNode(geometry: {
                    let g = SCNCapsule(capRadius: 0.02, height: 0.09); g.materials = [cream]; return g
                }())
                claw.position = SCNVector3(Float(0.24 * side), Float(-0.26 + 0.02 * Double(i)),
                                           Float(0.16 + Double(abs(i)) * 0.02))
                claw.eulerAngles = SCNVector3(0, 0, Float(side * (0.5 + Double(i) * 0.28)))
                body.addChildNode(claw)
            }
        }

        // tail
        let tail = SCNNode(geometry: {
            let g = SCNSphere(radius: 0.05); g.materials = [pink]; return g
        }())
        tail.position = SCNVector3(0, -0.02, -0.34)
        body.addChildNode(tail)
        self.tail = tail
        baseTailPose = tail.position

        // soft ground contact shadow (flattened dark disc, unlit)
        let shadow = SCNNode(geometry: {
            let g = SCNCylinder(radius: 0.30, height: 0.004)
            let m = SCNMaterial()
            m.diffuse.contents = NSColor.black.withAlphaComponent(0.22)
            m.lightingModel = .constant
            m.writesToDepthBuffer = false
            g.materials = [m]
            return g
        }())
        shadow.position = SCNVector3(0, -0.42, 0)
        root.addChildNode(shadow)
        let shadowShrink = SCNAction.sequence([
            SCNAction.scale(to: 0.86, duration: 1.3),
            SCNAction.scale(to: 1.0, duration: 1.3),
        ])
        shadow.runAction(SCNAction.repeatForever(shadowShrink))

        root.addChildNode(body)
        root.position = SCNVector3(0, -0.08, 0)
        scene.rootNode.addChildNode(root)

        // camera & lights
        let camera = SCNNode()
        camera.camera = SCNCamera()
        // Framing so the WHOLE puppet fits: the claws reach forward (z≈0.2)
        // toward the viewer, and the old 34° camera at z=1.55 clipped their
        // tips (and the ground shadow) at the viewport's bottom edge — the
        // reported "pet's feet are cut off". A wider field of view with a
        // slightly lower, farther camera leaves margin below the feet and
        // above the ear tips (incl. the celebrating hop).
        camera.camera?.fieldOfView = 39
        camera.position = SCNVector3(0, 0.32, 1.6)
        camera.look(at: SCNVector3(0, -0.04, 0))
        scene.rootNode.addChildNode(camera)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-Float.pi / 3.4, Float.pi / 7, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 280
        fill.position = SCNVector3(-1.1, 0.7, -0.9)
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 340
        scene.rootNode.addChildNode(ambient)

        applyState(.idle)
        startBlinking()
    }

    // MARK: - State animations

    /// Base pose of the animatable nodes (captured at build time).
    private let baseRootPosition = SCNVector3(0, -0.08, 0)
    private let baseBodyScale = SCNVector3(1, 1.12, 1)

    func applyState(_ newState: PetState) {
        state = newState
        root.removeAllActions()
        body.removeAllActions()
        nose.removeAllActions()
        eyes.forEach { $0.removeAllActions() }

        // CRITICAL: removing a running SCNAction does NOT roll back the
        // transform it already applied. Without this reset, interrupting the
        // celebration spin mid-flight (auto-settle, state switch, click)
        // froze the mole facing a random direction — permanently.
        root.position = baseRootPosition
        root.eulerAngles = SCNVector3(0, 0, 0)
        body.position = SCNVector3(0, 0, 0)
        body.eulerAngles = SCNVector3(0, 0, 0)
        body.scale = baseBodyScale
        nose.scale = SCNVector3(1, 1, 1)
        // Ears/tail too — removeAllActions does not roll back their transforms.
        for (i, ear) in ears.enumerated() {
            ear.removeAllActions()
            ear.position = baseEarPoses[i]
            ear.scale = SCNVector3(1, 1.25, 0.7)
            ear.eulerAngles = SCNVector3(0, 0, 0)
        }
        tail?.removeAllActions()
        tail?.position = baseTailPose
        tail?.scale = SCNVector3(1, 1, 1)

        // breathing + idle sway always run. SCNAction.scale(to:) is UNIFORM
        // and flattened the egg-shaped base ratio (y = 1.12) → drive the
        // per-axis scale from a customAction so the shape is preserved.
        let base = baseBodyScale
        let breath = SCNAction.customAction(duration: 2.6) { node, elapsed in
            // 0…2.6s → one smooth in/out cycle (sine easing, ±3.5%).
            let t = Double(elapsed) / 2.6
            let eased: Double = (sin(t * 2.0 * Double.pi - Double.pi / 2.0) + 1.0) / 2.0
            let s: CGFloat = 1.0 + 0.035 * CGFloat(eased)
            let x: CGFloat = base.x * s
            let y: CGFloat = base.y * s
            let z: CGFloat = base.z * s
            node.scale = SCNVector3(x, y, z)
        }
        body.runAction(.repeatForever(breath))

        let sway = SCNAction.rotateBy(x: 0, y: 0, z: 0.035, duration: 1.4)
        sway.timingMode = .easeInEaseOut
        let swayBack = SCNAction.rotateBy(x: 0, y: 0, z: -0.07, duration: 2.8)
        swayBack.timingMode = .easeInEaseOut
        body.runAction(.repeatForever(.sequence([sway, swayBack, sway])))

        switch newState {
        case .idle, .thinking:
            // Idle: an occasional ear twitch keeps the mole alive between
            // announcements; the tail sways slowly.
            for (i, ear) in ears.enumerated() {
                // Spheres show no rotation — twitch is a position jiggle.
                let twitch = SCNAction.sequence([
                    .wait(duration: Double.random(in: 2.5...6.0) + Double(i) * 1.7),
                    .moveBy(x: 0, y: 0.02, z: 0.015, duration: 0.09),
                    .moveBy(x: 0, y: -0.035, z: -0.02, duration: 0.16),
                    .moveBy(x: 0, y: 0.015, z: 0.005, duration: 0.09),
                ])
                ear.runAction(.repeatForever(twitch))
            }
            if let tail { tail.runAction(.repeatForever(Self.tailSway(duration: 2.4, angle: 0.5))) }
            if newState == .thinking {
                let bobUp = SCNAction.moveBy(x: 0, y: 0.03, z: 0, duration: 0.7)
                bobUp.timingMode = .easeInEaseOut
                let bobDown = SCNAction.moveBy(x: 0, y: -0.03, z: 0, duration: 0.7)
                bobDown.timingMode = .easeInEaseOut
                root.runAction(.repeatForever(.sequence([bobUp, bobDown])))
            }
        case .talking:
            // Ears bounce with the chirp rhythm; the tail wags along.
            for (i, ear) in ears.enumerated() {
                let bounce = SCNAction.sequence([
                    .wait(duration: 0.12 * Double(i)),
                    .moveBy(x: 0, y: 0.012, z: 0, duration: 0.12),
                    .moveBy(x: 0, y: -0.012, z: 0, duration: 0.12),
                ])
                ear.runAction(.repeatForever(bounce))
            }
            tail?.runAction(.repeatForever(Self.tailWag(duration: 0.9, angle: 0.6)))
            let chirp = SCNAction.sequence([
                .moveBy(x: 0, y: 0.025, z: 0, duration: 0.12),
                .moveBy(x: 0, y: -0.025, z: 0, duration: 0.12),
            ])
            root.runAction(.repeatForever(chirp))
            let pulse = SCNAction.sequence([
                .scale(to: 1.35, duration: 0.10),
                .scale(to: 1.0, duration: 0.10),
            ])
            nose.runAction(.repeatForever(pulse))
        case .scanning:
            // Ears perk forward while the head sweeps.
            for ear in ears {
                ear.runAction(.sequence([
                    .moveBy(x: 0, y: 0.015, z: 0.05, duration: 0.3),
                    Self.earScale(1.08, duration: 0.3),
                ]))
            }
            let look = SCNAction.sequence([
                .rotateBy(x: 0, y: 0.45, z: 0.05, duration: 0.5),
                .rotateBy(x: 0, y: -0.9, z: -0.1, duration: 1.0),
                .rotateBy(x: 0, y: 0.45, z: 0.05, duration: 0.5),
            ])
            look.timingMode = .easeInEaseOut
            root.runAction(.repeatForever(look))
        case .cleaning:
            // Ears pin back and the tail flicks fast — busy work.
            for ear in ears {
                ear.runAction(.sequence([
                    .moveBy(x: 0, y: -0.015, z: -0.045, duration: 0.25),
                    Self.earScale(0.92, duration: 0.25),
                ]))
            }
            tail?.runAction(.repeatForever(Self.tailWag(duration: 0.28, angle: 0.85)))
            let shiver = SCNAction.sequence([
                .moveBy(x: 0.012, y: 0, z: 0, duration: 0.06),
                .moveBy(x: -0.024, y: 0, z: 0, duration: 0.12),
                .moveBy(x: 0.012, y: 0, z: 0, duration: 0.06),
            ])
            root.runAction(.repeatForever(shiver))
        case .celebrating:
            let hop = SCNAction.sequence([
                .moveBy(x: 0, y: 0.12, z: 0, duration: 0.18),
                .moveBy(x: 0, y: -0.12, z: 0, duration: 0.18),
            ])
            hop.timingMode = .easeInEaseOut
            root.runAction(.repeatForever(hop))
            body.runAction(.repeatForever(
                .rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 1.6)
            ))
            let happy = SCNAction.sequence([
                .scale(to: 1.4, duration: 0.14),
                .scale(to: 1.0, duration: 0.14),
            ])
            nose.runAction(.repeatForever(happy))
            // Ears pop up and the tail wags like there is no tomorrow.
            for (i, ear) in ears.enumerated() {
                let pop = SCNAction.sequence([
                    .wait(duration: 0.05 * Double(i)),
                    Self.earScale(1.18, duration: 0.14),
                    Self.earScale(1.0, duration: 0.2),
                ])
                ear.runAction(.repeatForever(pop))
            }
            tail?.runAction(.repeatForever(Self.tailWag(duration: 0.35, angle: 1.0)))
        case .sleeping:
            root.runAction(.sequence([
                .rotateTo(x: 0.45, y: 0, z: 0.1, duration: 0.7, usesShortestUnitArc: true),
                .moveBy(x: 0, y: -0.06, z: 0, duration: 0.4),
            ]))
            eyes.forEach { $0.scale = SCNVector3(1, 0.12, 1) }
            let base = baseBodyScale
            let snore = SCNAction.customAction(duration: 3.2) { node, elapsed in
                let t = Double(elapsed) / 3.2
                let eased: Double = (sin(t * 2.0 * Double.pi - Double.pi / 2.0) + 1.0) / 2.0
                let s: CGFloat = 1.0 + 0.07 * CGFloat(eased)
                let x: CGFloat = base.x * s
                let y: CGFloat = base.y * s
                let z: CGFloat = base.z * s
                node.scale = SCNVector3(x, y, z)
            }
            body.runAction(.repeatForever(snore))
            // Everything droops: ears sag outward, the tail settles low.
            for (i, ear) in ears.enumerated() {
                let side = CGFloat(i == 0 ? -1.0 : 1.0)
                _ = side
                ear.runAction(.sequence([
                    .moveBy(x: 0, y: -0.05, z: 0.02, duration: 0.7),
                    Self.earScale(0.85, duration: 0.7),
                ]))
            }
            tail?.runAction(.sequence([
                .moveBy(x: 0, y: -0.03, z: 0, duration: 0.7),
            ]))
        case .sad:
            // Ears droop, tail hangs, head pitches slightly down — the
            // "oops" pose for error announcements (was dead sticker code).
            for (i, ear) in ears.enumerated() {
                let side = CGFloat(i == 0 ? -1.0 : 1.0)
                _ = side
                ear.runAction(.sequence([
                    .moveBy(x: 0, y: -0.04, z: 0.015, duration: 0.35),
                    Self.earScale(0.9, duration: 0.35),
                ]))
            }
            tail?.runAction(.sequence([
                .moveBy(x: 0, y: -0.035, z: 0, duration: 0.4),
                .wait(duration: 0.6),
                .moveBy(x: 0, y: 0.015, z: 0, duration: 0.5),
                .moveBy(x: 0, y: -0.015, z: 0, duration: 0.5),
            ]))
            root.runAction(.sequence([
                .rotateBy(x: 0.1, y: 0, z: 0, duration: 0.4),
            ]))
        }
        if newState != .sleeping {
            eyes.forEach { $0.scale = SCNVector3(1, 1, 1) }
            // applyState removed the blink actions — rebuild them, otherwise
            // the mole never blinked again after the very first state change.
            startBlinking()
        }
    }

    /// Slow left-right tail sway (idle / thinking).
    private static func tailSway(duration: TimeInterval, angle: CGFloat) -> SCNAction {
        // POSITION sweep — the tail is a sphere, rotations are invisible.
        let amp = angle * 0.04
        let left = SCNAction.moveBy(x: -amp, y: 0, z: 0, duration: duration / 2)
        left.timingMode = .easeInEaseOut
        let right = SCNAction.moveBy(x: amp * 2, y: 0, z: 0, duration: duration)
        right.timingMode = .easeInEaseOut
        return .sequence([left, right, SCNAction.moveBy(x: -amp, y: 0, z: 0, duration: duration / 2)])
    }

    /// Ear scale that PRESERVES the non-uniform base ratios (1, 1.25, 0.7) —
    /// SCNAction.scale(to:) is uniform-only and would squash the ear shape.
    private static func earScale(_ factor: CGFloat, duration: TimeInterval) -> SCNAction {
        SCNAction.customAction(duration: duration) { node, elapsed in
            let t = CGFloat(min(1, elapsed / duration))
            let eased = t * t * (3 - 2 * t)   // smoothstep
            let x: CGFloat = 1.0 * (1.0 + (factor - 1.0) * eased)
            let y: CGFloat = 1.25 * (1.0 + (factor - 1.0) * eased)
            let z: CGFloat = 0.7 * (1.0 + (factor - 1.0) * eased)
            node.scale = SCNVector3(x, y, z)
        }
    }

    /// Fast wag for expressive states (talking / cleaning / celebrating).
    private static func tailWag(duration: TimeInterval, angle: CGFloat) -> SCNAction {
        let amp = angle * 0.05
        let left = SCNAction.moveBy(x: -amp, y: 0.008, z: 0, duration: duration / 2)
        let right = SCNAction.moveBy(x: amp * 2, y: -0.016, z: 0, duration: duration)
        return .sequence([left, right, SCNAction.moveBy(x: -amp, y: 0.008, z: 0, duration: duration / 2)])
    }

    /// One-shot tactile feedback for clicks: hop + body wiggle + nose boop.
    func poke() {
        let hop = SCNAction.sequence([
            .moveBy(x: 0, y: 0.10, z: 0, duration: 0.10),
            .moveBy(x: 0, y: -0.10, z: 0, duration: 0.10),
        ])
        hop.timingMode = .easeInEaseOut
        root.runAction(.sequence([
            hop,
            .rotateBy(x: 0, y: 0, z: 0.12, duration: 0.08),
            .rotateBy(x: 0, y: 0, z: -0.24, duration: 0.16),
            .rotateBy(x: 0, y: 0, z: 0.12, duration: 0.08),
        ]))
        let boop = SCNAction.sequence([
            .scale(to: 1.5, duration: 0.08),
            .scale(to: 1.0, duration: 0.10),
        ])
        nose.runAction(boop)
    }

    private func startBlinking() {
        for eye in eyes {
            let blink = SCNAction.sequence([
                SCNAction.wait(duration: Double.random(in: 2.5...6.0)),
                SCNAction.scale(to: 0.1, duration: 0.07),
                SCNAction.scale(to: 1.0, duration: 0.07),
            ])
            eye.runAction(.repeatForever(blink)) { [weak self, weak eye] in
                guard let self, let eye else { return }
                if self.state != .sleeping { eye.scale = SCNVector3(1, 1, 1) }
            }
        }
    }
}

// MARK: - SceneKit host view

@MainActor
final class PetSceneBridge {
    static let shared = PetSceneBridge()
    var puppet: MolePuppet?

    func applyState(_ state: PetState) {
        puppet?.applyState(state)
    }

    func poke() {
        puppet?.poke()
    }
}

struct MoleSceneView: NSViewRepresentable {
    func makeCoordinator() -> SceneReadyCoordinator { SceneReadyCoordinator() }

    func makeNSView(context: Context) -> NSView {
        let puppet = MolePuppet()
        let view = SCNView(frame: NSRect(x: 0, y: 0, width: 230, height: 270))
        view.scene = puppet.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        view.delegate = context.coordinator
        context.coordinator.scnView = view
        PetSceneBridge.shared.puppet = puppet
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Pet interaction (AppKit layer)

/// Invisible marker view: "this rectangle is real, clickable content".
/// Attached as a background to the bubble / question / approval cards; the
/// mole's PetInteractionNSView doubles as its own marker.
final class HitRegionView: NSView {}

struct HitRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> HitRegionView { HitRegionView() }
    func updateNSView(_ view: HitRegionView, context: Context) {}
}

/// Hosting view for the pet panel. The panel can be MUCH wider than the mole
/// while a wide answer is showing (adaptive bubble width) — the empty
/// transparent space must fall through to the apps underneath instead of
/// swallowing clicks. A click only belongs to Moppet when it lands on real
/// content (a hit-region marker or the mole interaction layer).
final class PetPanelHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        // `point` arrives in the superview's coordinate space.
        let local = convert(point, from: superview)
        return containsHitRegion(local) ? super.hitTest(point) : nil
    }

    private func containsHitRegion(_ point: NSPoint) -> Bool {
        func walk(_ view: NSView) -> Bool {
            if view is HitRegionView || view is PetInteractionNSView,
               view.bounds.contains(view.convert(point, from: self)) {
                return true
            }
            return view.subviews.contains(where: walk)
        }
        return walk(self)
    }
}

/// Click/double-click/drag/cursor/right-click layer that sits ON TOP of the
/// 3D scene.
///
/// The previous SwiftUI gesture stack (.onTapGesture ×2 + .onHover +
/// DragGesture wrapped around MoleSceneView) misbehaved whenever Moppet was
/// NOT the active app — and the pet panel is a non-activating floater, so
/// that is the common case: SwiftUI's hover tracking stopped firing (the
/// pointing-hand cursor came and went), the first click after a context
/// switch was consumed by app activation ("single click sometimes does
/// nothing"), and jittery clicks got eaten by the root DragGesture. A plain
/// NSView with `acceptsFirstMouse` + an `.activeAlways` tracking area handles
/// all of it deterministically regardless of activation state.
struct PetInteractionView: NSViewRepresentable {
    weak var panel: NSPanel?
    var onTap: () -> Void
    var onDoubleTap: () -> Void
    var buildMenu: () -> NSMenu

    func makeNSView(context: Context) -> PetInteractionNSView {
        let view = PetInteractionNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PetInteractionNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: PetInteractionNSView) {
        view.panel = panel
        view.onTap = onTap
        view.onDoubleTap = onDoubleTap
        view.buildMenu = buildMenu
    }
}

final class PetInteractionNSView: NSView {
    weak var panel: NSPanel?
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var buildMenu: (() -> NSMenu)?

    /// Global-coordinate point of mouseDown — the drag and click-threshold
    /// math both compare against it.
    private var mouseDownPoint: NSPoint = .zero
    private var dragOrigin: NSPoint?
    private var pendingSingleClick: DispatchWorkItem?

    /// The pet must act on the FIRST click even while the app is in the
    /// background — without this the click only activates the app and is
    /// eaten (the panel is non-activating, so it is never key).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Panel dragging is driven by mouseDragged below; letting the system
    /// move the window too would double-move.
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    /// Pointing hand in EVERY app state. (SwiftUI .onHover + NSCursor push/pop
    /// only worked while Moppet was active, and unbalanced pushes leaked the
    /// hand cursor to other UI.)
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = NSEvent.mouseLocation
        dragOrigin = panel?.frame.origin
        pendingSingleClick?.cancel()
        PetSceneBridge.shared.poke()   // instant tactile feedback
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel, let dragOrigin else { return }
        let now = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(
            x: dragOrigin.x + (now.x - mouseDownPoint.x),
            y: dragOrigin.y + (now.y - mouseDownPoint.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        pendingSingleClick?.cancel()
        // Held-and-moved = drag, not a click (the old root DragGesture ate
        // jittery clicks; a small tolerance keeps them clickable).
        let moved = hypot(NSEvent.mouseLocation.x - mouseDownPoint.x,
                          NSEvent.mouseLocation.y - mouseDownPoint.y)
        guard moved < 6 else { return }
        if event.clickCount >= 2 {
            onDoubleTap?()
        } else {
            // Defer until the double-click window closes, else a real
            // double-click would first toggle the input bar open.
            let task = DispatchWorkItem { [weak self] in self?.onTap?() }
            pendingSingleClick = task
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval, execute: task)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = buildMenu?() else { return }
        menu.popUp(positioning: nil,
                   at: convert(event.locationInWindow, from: nil), in: self)
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
        Markdown(message)
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
        .background(HitRegion())
        .background(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .fill(Airi.cardBackground)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                .strokeBorder(Airi.neutral200.opacity(0.6), lineWidth: 1)
        )
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
/// answer" regression.
@MainActor
enum PetBubbleProbe {
    private final class Store {
        var heights: [String: CGFloat] = [:]
        var moleHeights: [String: CGFloat] = [:]
        var natural: [String: CGFloat] = [:]
    }

    static func run() -> Never {
        let store = Store()
        let cases: [(CGFloat, CGFloat)] = [(200, 320), (250, 400)]
        let texts: [(String, String)] = [
            ("short", "嗨！我是 Moley 🦫 点我聊天 · 双击开完整窗口"),
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
                        Color.clear
                            .aspectRatio(230.0 / 270.0, contentMode: .fit)
                            .frame(maxWidth: max(120, panelW - 20),
                                   maxHeight: max(120, panelH - 130))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 10)
                            .layoutPriority(-1)
                            .background(GeometryReader { g in
                                Color.clear.onAppear { store.moleHeights[key] = g.size.height }
                            })
                    }
                    .frame(width: panelW, height: targetH)
                )
                fullHost.frame = NSRect(x: 0, y: 0, width: panelW, height: targetH)
                fullHost.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let mole = store.moleHeights[key] ?? -1
                let estimate = PetView.bubbleHeight(for: text, width: width)
                print("probe \(key): cardH=\(Int(cardH)) panelH=\(Int(targetH)) "
                      + "moleH=\(Int(mole)) moleKept=\(mole >= moleH - 2) "
                      + "natural=\(Int(natural)) estimate=\(Int(estimate))")
            }
        }
        let ok = store.heights.count == cases.count * texts.count
            && store.moleHeights.values.allSatisfy { $0 >= 118 }
        exit(ok ? 0 : 2)
    }
}

// MARK: - Pet view (3D mole + bubble + quick chat)

struct PetView: View {
    weak var panel: NSPanel?

    @State private var bus = PetBus.shared
    @State private var bubbleVisible = false
    @State private var bubbleHideTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            userInputCard
            approvalCard
            bubble
            ZStack {
                MoleSceneView()
                // AppKit interaction layer on top of the scene so the SCNView
                // never competes for mouse events (see PetInteractionNSView).
                PetInteractionView(
                    panel: panel,
                    onTap: {
                        if bus.state == .celebrating || bus.state == .sad {
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
                    buildMenu: petMenu
                )
            }
            // Keep the scene's canonical 230×270 aspect: when a tall answer
            // squishes the vertical space the scene shrinks UNIFORMLY. A
            // plain resize goes landscape, and the camera's field of view
            // follows the larger viewport axis — that squeezed the frustum
            // vertically and cut the feet off.
            .aspectRatio(230.0 / 270.0, contentMode: .fit)
            .frame(maxWidth: max(120, PetSettings.currentSize.width - 20),
                   maxHeight: max(120, PetSettings.currentSize.height - 130))
            // The panel widens LEFTWARD while a wide answer is showing; the
            // mole must stay pinned at the panel's trailing edge (10pt margin,
            // matching the old centered 230-in-250 layout) so the pet itself
            // never moves on screen.
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            // The bubble/approval card win the vertical budget first; the
            // mole flexes shorter while a long answer is up (fixed 270 +
            // a tall bubble overflowed the 400pt panel).
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
            // 0 = keep the bubble until the next say() (streaming answers).
            guard interval > 0 else { return }
            bubbleHideTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(Airi.controlAnimation) { bubbleVisible = false }
                if bus.state == .talking { bus.setState(.idle) }
            }
        }
        .onChange(of: bus.state) { _, newState in
            PetSceneBridge.shared.applyState(newState)
        }
        .onAppear {
            bus.say(String(format: L("Hi! I'm %@ 🦫  Click to chat · double-click for the full window"),
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

    private var bubbleWidth: CGFloat {
        Self.bubbleWidth(for: bus.message, maxWidth: maxBubbleTextWidth)
    }

    /// Panel width the layout wants: the base pet size while the bubble is
    /// hidden, wide enough for the whole bubble card while it shows.
    private var targetPanelWidth: CGFloat {
        guard bubbleVisible else { return PetSettings.currentSize.width }
        return max(PetSettings.currentSize.width, bubbleWidth + 24)
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
        let estimate = Self.bubbleHeight(for: bus.message, width: bubbleWidth)
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
        return max(PetSettings.currentSize.height, bubbleCardHeight + 4 + moleHeight + 6)
    }

    private var targetPanelSize: CGSize {
        CGSize(width: targetPanelWidth, height: targetPanelHeight)
    }

    /// Resize the hosting panel so the layout's target size becomes real. The
    /// RIGHT edge and BOTTOM stay pinned — the pet never moves; the bubble
    /// grows leftward and upward, into the empty desktop area.
    private func syncPanelSize(_ size: CGSize) {
        guard let panel else { return }
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        panel.setFrame(NSRect(x: frame.maxX - size.width, y: frame.minY,
                              width: size.width, height: size.height),
                       display: true)
    }

    /// Viewport height for a long answer when the screen itself is the limit
    /// (kept for the bubble probe / smoke test).
    static func bubbleHeightCap(panelHeight: CGFloat) -> CGFloat {
        max(96, min(208, panelHeight * 0.62))
    }

    private var bubble: some View {
        Group {
            if bubbleVisible {
                VStack {
                    // Markdown rendering — AI answers arrive as markdown
                    // (bold, lists, code) and leaked literal markers as plain
                    // Text ("**最快的办法：**"). Same engine as the chat
                    // window's transcript.
                    // Full answer, never clipped: a lineLimit(12) cut long
                    // answers mid-sentence (read as "the bubble is broken").
                    // ViewThatFits keeps short messages hugging their content
                    // and only switches to a scrolling viewport when the text
                    // would overflow the height budget.
                    PetBubbleCard(message: bus.message,
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
                .background(HitRegion())
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .fill(Airi.cardBackground)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .strokeBorder(Airi.primary.opacity(0.4), lineWidth: 1)
                )
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
                .background(HitRegion())
                .background(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .fill(Airi.cardBackground)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Airi.radiusCard, style: .continuous)
                        .strokeBorder(Airi.danger.opacity(0.4), lineWidth: 1)
                )
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8),
                   value: ApprovalCenter.shared.pending == nil)
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
