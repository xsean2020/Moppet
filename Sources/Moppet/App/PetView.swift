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
        camera.camera?.fieldOfView = 34
        camera.position = SCNVector3(0, 0.28, 1.55)
        camera.look(at: SCNVector3(0, 0.02, 0))
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
            ScrollView(.vertical, showsIndicators: true) {
                content
            }
            .frame(height: maxHeight)
        }
        .frame(width: width)
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
@MainActor
enum PetBubbleProbe {
    private final class Store {
        var heights: [String: CGFloat] = [:]
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
                let width = PetView.bubbleWidth(for: text, panelWidth: panelW)
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
            }
        }
        exit(store.heights.count == cases.count * texts.count ? 0 : 2)
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
            .frame(maxWidth: max(120, PetSettings.currentSize.width - 20),
                   maxHeight: max(120, PetSettings.currentSize.height - 130))
            // The bubble/approval card win the vertical budget first; the
            // mole flexes shorter while a long answer is up (fixed 270 +
            // a tall bubble overflowed the 400pt panel).
            .layoutPriority(-1)
        }
        .frame(width: PetSettings.currentSize.width,
               height: PetSettings.currentSize.height)
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

    /// Content-hugging bubble width: a short message sits compactly on one
    /// line, a long one wraps at the panel-wide cap. MarkdownUI's own ideal
    /// width is unreliable for this, so the width is estimated per character
    /// (CJK/emoji/fullwidth ≈ 13pt at font 12, ASCII ≈ 7.2pt) over the
    /// longest line.
    /// Bubble width for `message`, clamped to the PANEL that hosts it.
    ///
    /// The old version capped at a hardcoded 232pt. The pet panel is
    /// 250×sizeScale wide (200pt at the 0.8 scale), so a 232pt card overflowed
    /// the window: the card edge and the right end of every line were clipped
    /// away (the reported "bubble content is not complete").
    static func bubbleWidth(for message: String, panelWidth: CGFloat) -> CGFloat {
        func lineWidth(_ line: Substring) -> CGFloat {
            line.reduce(CGFloat(0)) { acc, ch in
                acc + (ch.unicodeScalars.first.map { $0.value > 0x2E80 ? 13 : 7.2 } ?? 7.2)
            }
        }
        let longest = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(lineWidth)
            .max() ?? 0
        // 12pt breathing room on each side of the panel, and the text padding
        // (10pt × 2) plus the card border stay inside it.
        let cap = max(96, panelWidth - 24)
        return min(cap, max(80, longest + 20))
    }

    private var bubbleWidth: CGFloat {
        Self.bubbleWidth(for: bus.message, panelWidth: PetSettings.currentSize.width)
    }

    /// Viewport height for a long answer: whatever the panel can spare after
    /// the mole keeps a usable strip, never the hardcoded 208.
    static func bubbleHeightCap(panelHeight: CGFloat) -> CGFloat {
        max(96, min(208, panelHeight * 0.62))
    }

    private var bubbleMaxHeight: CGFloat {
        Self.bubbleHeightCap(panelHeight: PetSettings.currentSize.height)
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
                    // would overflow the panel.
                    PetBubbleCard(message: bus.message,
                                  width: bubbleWidth,
                                  maxHeight: bubbleMaxHeight)
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
