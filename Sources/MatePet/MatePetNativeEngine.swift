import AVFoundation
import Foundation
import RealityKit
import VRMKit
import VRMRealityKit

/// Native RealityKit renderer for macOS 15+.
///
/// This is the second `MatePetRendering` implementation. It keeps the same
/// host-facing API as the WKWebView engine, so `PetPanelController`, the
/// interaction layer and `PetView` do not branch on the renderer.
///
/// Design notes:
/// - VRMRealityKit owns skinning, MToon materials, expressions, look-at and
///   spring bones; we only write humanoid bone rotations once per frame from
///   `setUpdateHandler(_:at: .afterAnimation)`.
/// - Bones are posed through their entity transforms, which VRMKit adopts at
///   the next update. Rest rotations are captured after load and every pose is
///   `rest * delta`, never an absolute overwrite.
/// - The camera sits on -Z because VRM 0.x faces -Z (`VRM.forwardDirection`);
///   this frames Zome's face without a 180° model rotation.
@available(macOS 15.0, *)
@MainActor
public final class MatePetNativeEngine: NSObject, MatePetRendering {

    public var onEvent: ((MatePetEvent) -> Void)?
    /// Host-only hook used by the native container to hide its loading spinner.
    public var onModelReady: (() -> Void)?
    public private(set) var isPageReady = false

    /// Added to the `RealityView` by `MatePetNativeSceneView`.
    public let renderRoot = Entity()

    private var model: VRMEntity?
    private var cameraNode: PerspectiveCamera?
    private var keyLight: DirectionalLight?
    private var fillLight: DirectionalLight?
    private var started = false
    private var paused = false

    private struct BoneRest {
        let node: Entity
        let base: simd_quatf
    }
    private var boneRest: [HumanoidBone: BoneRest] = [:]
    private var offsets: [HumanoidBone: SIMD3<Float>] = [:]

    private var headNode: Entity?
    private var leftLegNode: Entity?
    private var rightLegNode: Entity?
    private var baseScale = SIMD3<Float>(repeating: 1)
    private var baseHeight: Float = 1.55
    private var baseWidth: Float = 1.37
    private var headRestY: Float = 1.30
    private var headRadius: Float = 0.22
    private var groundOffset: Float = 0

    private var expressionKeys: [String: ExpressionKey] = [:]
    private var expressionCurrent: [ExpressionKey: CGFloat] = [:]
    private var expressionTarget: [ExpressionKey: CGFloat] = [:]
    private var availableExpressions: Set<ExpressionKey> = []

    private var state: MatePetState = .idle
    private var talking = false
    private var talkingUntil: TimeInterval = 0
    private var time: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0

    private var look = SIMD2<Float>(0.5, 0.5)
    private var lookYaw: Float = 0
    private var lookPitch: Float = 0

    private var dragActive = false
    private var dragEnergy = SIMD2<Float>(0, 0)
    private var lean: Float = 0

    private var mode: MatePetAction?
    private var modeStart: TimeInterval = 0
    private var modeUntil: TimeInterval = 0

    private var pokeStart: TimeInterval = -1000
    private var pokeRegion: MatePetHitRegion = .body
    private var petStart: TimeInterval = -1000

    private var chibi: Float = 0
    private var chibiTarget: Float = 0
    private var lastChibiFit: Float = -1

    private var walkDir: Int = 0
    private var jump: Float = 0
    private var modeY: Float = 0
    private var cameraGoalPosition = SIMD3<Float>(0, 0.8, -3.2)
    private var cameraGoalLook = SIMD3<Float>(0, 0.8, 0)
    private var cameraInitialized = false

    // Offline-baked Unity clips (VRMA). Playback is driven by the same
    // 60Hz tick as the procedural fallback; when a clip is active we do not
    // write humanoid rotations, so the clip owns the skeleton.
    private var animationCache: [String: VRMAnimation] = [:]
    private var animationController: GLTFAnimationPlaybackController?
    private var currentClip: String?
    private var clipGeneration = 0
    private var idleClipIndex = 0
    private var nextIdleSwitch: TimeInterval = 0

    private let audio = NativePetAudio()
    private var ticker: Timer?
    private var lastTick: TimeInterval = 0
    private var visemeIndex = 0
    private var visemeClock: TimeInterval = 0
    private var blinkStart: TimeInterval = -1000
    private var nextBlink: TimeInterval = 2
    private var blinking: CGFloat = 0
    private var nextGesture: TimeInterval = 7

    // MARK: - Lifecycle

    private var verbose: Bool {
        ProcessInfo.processInfo.environment["MOPPET_MATE_PET_DEV"] != nil
    }

    public func startIfNeeded() {
        guard !started else { return }
        started = true
        if verbose { FileHandle.standardError.write(Data("mate-pet-native: start\n".utf8)) }

        setUpCameraAndLights()
        isPageReady = true
        onEvent?(.ready)

        Task { @MainActor in
            await loadModel()
        }
    }

    private func setUpCameraAndLights() {
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 30
        camera.camera.near = 0.03
        camera.camera.far = 30
        renderRoot.addChild(camera)
        cameraNode = camera

        let key = DirectionalLight()
        key.light.intensity = 2200
        key.look(at: .zero, from: SIMD3<Float>(-1.2, 2.4, 2.2), relativeTo: nil)
        renderRoot.addChild(key)
        keyLight = key

        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: SIMD3<Float>(1.8, 1.2, -1.2), relativeTo: nil)
        renderRoot.addChild(fill)
        fillLight = fill

        refitCamera()
    }

    private func loadModel() async {
        do {
            guard let root = Bundle.module.resourceURL else {
                throw NSError(domain: "MatePet", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "resource bundle missing"])
            }
            let url = root.appendingPathComponent("Resources/Zome.vrm")
            let loader = try VRMEntityLoader(withURL: url)
            let entity = try await loader.loadEntity()

            // Zome is VRM 0.x: it faces -Z, so we keep the model as-is and put
            // the camera on -Z. This avoids the WebView's 180° scene rotation.
            entity.setMToonLightDirection(simd_normalize(SIMD3<Float>(-0.35, -0.55, -0.75)))
            renderRoot.addChild(entity)
            model = entity

            // Normalize height and put the feet on y = 0.
            let bounds = entity.visualBounds(relativeTo: nil)
            let height = max(0.1, bounds.max.y - bounds.min.y)
            let targetHeight: Float = 1.55
            baseScale = SIMD3<Float>(repeating: targetHeight / height)
            entity.transform.scale = baseScale
            let scaled = entity.visualBounds(relativeTo: nil)
            groundOffset = -scaled.min.y
            entity.transform.translation.y = groundOffset
            baseHeight = scaled.max.y - scaled.min.y
            baseWidth = scaled.max.x - scaled.min.x

            for bone in HumanoidBone.allCases {
                guard let node = entity.humanoid.node(for: bone) else { continue }
                boneRest[bone] = BoneRest(node: node, base: node.transform.rotation)
                offsets[bone] = .zero
            }
            headNode = entity.humanoid.node(for: .head)
            leftLegNode = entity.humanoid.node(for: .leftUpperLeg)
            rightLegNode = entity.humanoid.node(for: .rightUpperLeg)

            // Chibi grows the head joint alone; RealityKit's visualBounds()
            // reports the static bind pose, so it never sees that growth. Keep
            // the rest head position/radius and derive the chibi silhouette.
            if let head = headNode {
                let headY = head.position(relativeTo: renderRoot).y
                headRestY = max(0.4, headY)
                headRadius = max(0.08, scaled.max.y + groundOffset - headRestY)
            }

            for info in entity.availableExpressions {
                availableExpressions.insert(info.key)
                expressionCurrent[info.key] = 0
            }
            indexExpressions(entity.availableExpressions)

            // 0.11.0 has no public update-handler hook, so drive the model
            // ourselves: pose, then `update(deltaTime:)` for constraints,
            // spring bones and skinning. This also gives us the pause/降频 knob.
            entity.isAutomaticUpdateEnabled = false
            refitCamera()
            chibiTarget = MatePetSettings.chibi ? 1 : 0
            audio.muted = MatePetSettings.muted

            startTicker()
            if verbose {
                let b = entity.visualBounds(relativeTo: renderRoot)
                FileHandle.standardError.write(Data("mate-pet-native: model ready bounds=\(b.min)-\(b.max)\n".utf8))
            }
            onModelReady?()
            onEvent?(.modelReady)
        } catch {
            FileHandle.standardError.write(Data("mate-pet-native: load failed \(error.localizedDescription)\n".utf8))
            onEvent?(.loadError(error.localizedDescription))
        }
    }

    private func indexExpressions(_ infos: [ExpressionInfo]) {
        for info in infos {
            expressionKeys[info.name.lowercased()] = info.key
        }
        for preset in ExpressionPreset.allCases {
            if let info = infos.first(where: { $0.preset == preset }) {
                expressionKeys["preset:\(preset.rawValue)"] = info.key
            }
        }
        // VRM 0.x names that map onto presets.
        let aliases: [String: ExpressionPreset] = [
            "joy": .happy, "fun": .relaxed, "sorrow": .sad,
            "a": .aa, "i": .ih, "u": .ou, "e": .ee, "o": .oh,
            "blink_l": .blinkLeft, "blink_r": .blinkRight,
        ]
        for (name, preset) in aliases {
            if let info = infos.first(where: { $0.preset == preset }) {
                expressionKeys[name] = info.key
            }
        }
    }

    private func expression(_ name: String) -> ExpressionKey? {
        expressionKeys[name.lowercased()]
    }

    private func preset(_ preset: ExpressionPreset) -> ExpressionKey? {
        expressionKeys["preset:\(preset.rawValue)"]
    }

    // MARK: - Public API

    public func setState(_ state: MatePetState) {
        self.state = state
        if state == .sleeping { nextGesture = time + 60 }
        if !dragActive, walkDir == 0, mode == nil {
            playStateClip()
        }
    }

    public func setTalking(_ talking: Bool) {
        self.talking = talking
        talkingUntil = talking ? .infinity : 0
        visemeClock = 0
    }

    public func say(_ text: String, seconds: Double?) {
        let length = max(1.2, min(6.5, 1.2 + Double(text.count) * 0.035))
        talking = true
        talkingUntil = time + (seconds ?? length)
        visemeClock = 0
    }

    public func look(atNormalizedX x: Double, y: Double) {
        look = SIMD2<Float>(Float(max(0, min(1, x))), Float(max(0, min(1, y))))
    }

    public func dragBegan() {
        dragActive = true
        dragEnergy = .zero
        _ = playClip("drag", loops: true)
    }

    public func dragMoved(dx: Double, dy: Double) {
        dragEnergy.x = dragEnergy.x * 0.45 + Float(dx) * 0.55
        dragEnergy.y = dragEnergy.y * 0.45 + Float(dy) * 0.55
    }

    public func dragEnded(vx: Double, vy: Double) {
        dragActive = false
        dragEnergy = SIMD2<Float>(Float(vx) * 0.004, Float(vy) * 0.004)
        dragEnergy = simd_clamp(dragEnergy, SIMD2<Float>(repeating: -2.2), SIMD2<Float>(repeating: 2.2))
        lean = max(-0.42, min(0.42, -dragEnergy.x * 0.10))
        playStateClip()
    }

    public func poke(region: MatePetHitRegion, count: Int) {
        pokeStart = time
        pokeRegion = region
        audio.unlock()
        audio.poke()
        if region == .head {
            playOneShot("laugh")
            target(.happy, 0.9)
        } else {
            playOneShot("happy")
            target(.surprised, 0.8)
        }
    }

    public func play(_ action: MatePetAction) {
        modeStart = time
        switch action {
        case .dance:
            mode = .dance
            modeUntil = time + 9
            audio.unlock()
            audio.danceStart()
            _ = playClip("dance_0\(Int.random(in: 1...4))", loops: true)
        case .hide:
            stopClip()
            mode = .hide
            modeUntil = time + 0.65
        case .appear:
            stopClip()
            mode = .appear
            modeUntil = time + 0.65
        case .wake:
            stopClip()
            mode = .wake
            modeUntil = time + 0.9
            audio.unlock()
            audio.happy()
        case .stretch:
            stopClip()
            mode = .stretch
            modeUntil = time + 1.5
        case .wave:
            stopClip()
            mode = .wave
            modeUntil = time + 1.8
        case .poke: poke(region: .body, count: 1)
        case .pet:
            petStart = time
            audio.unlock()
            audio.pet()
            playOneShot("laugh")
            target(.happy, 1)
            targetCustom("heart", 0.8)
        case .chibiOn: setChibi(true)
        case .chibiOff: chibiTarget = 0; MatePetSettings.chibi = false
        case .walkLeft: setWalking(-1)
        case .walkRight: setWalking(1)
        case .stopWalk: setWalking(0)
        }
    }

    public func setChibi(_ on: Bool) {
        chibiTarget = on ? 1 : 0
        MatePetSettings.chibi = on
        if on { audio.unlock(); audio.chibiOn() }
    }

    public func setWalking(_ direction: Int) {
        let next = max(-1, min(1, direction))
        guard next != walkDir else { return }
        walkDir = next
        if next == 0 {
            playStateClip()
        } else {
            _ = playClip(next < 0 ? "walk_left" : "walk_right", loops: true)
        }
    }

    public func setMuted(_ muted: Bool) {
        MatePetSettings.muted = muted
        audio.muted = muted
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            stopTicker()
        } else {
            startTicker()
        }
    }

    public func audioUnlock() {
        audio.unlock()
    }

    public func syncPreferences() {
        // Silent: a saved Chibi preference must not chirp on every launch.
        chibiTarget = MatePetSettings.chibi ? 1 : 0
        audio.muted = MatePetSettings.muted
    }

    private func startTicker() {
        guard ticker == nil, model != nil, !paused else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard !paused, let model else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.05, max(0.001, now - lastTick))
        lastTick = now
        frame(delta)
        if let cameraNode {
            cameraNode.position += (cameraGoalPosition - cameraNode.position) * 0.15
            cameraNode.look(at: cameraGoalLook, from: cameraNode.position, relativeTo: renderRoot)
        }
        model.update(deltaTime: delta)
    }

    // MARK: - Frame

    private func frame(_ delta: TimeInterval) {
        guard !paused, let model else { return }
        lastFrameTime = time
        time += min(0.05, max(0.001, delta))
        let t = time
        jump = 0
        modeY = 0
        offsets.removeAll(keepingCapacity: true)
        expressionTarget.removeAll(keepingCapacity: true)

        let procedural = animationController == nil
        if procedural {
            applyBasePose()
            applyState(t)
            applyMode(t)
            applyDrag(t)
            applyPoke(t)
            applyPet(t)
            applyWalk(t)
            applyPose()
        } else {
            // A baked VRMA owns the skeleton. Only expression/look-at/chibi
            // layering runs; reset the procedural offset table so a later
            // fallback starts clean.
            applyLook(t)
            applyTalking(t)
            applyBlink(t)
            applyStateExpressions()
        }
        if procedural {
            applyLook(t)
            applyTalking(t)
            applyBlink(t)
        }

        if state == .idle, mode == nil, animationController != nil,
           currentClip?.hasPrefix("idle_") == true, time >= nextIdleSwitch {
            idleClipIndex = (idleClipIndex + 1) % 4
            _ = playClip(currentIdleClip, loops: true)
            nextIdleSwitch = time + 12
        }

        applyExpressions()
        applyChibi(delta)
        model.transform.translation.y = groundOffset + jump + modeY

        if let mode, time >= modeUntil {
            if mode == .hide { onEvent?(.hideFinished) }
            if mode == .dance { audio.danceStop(); stopClip() }
            self.mode = nil
            playStateClip()
        }
    }

    private func applyBasePose() {
        addBase(.leftShoulder, 0, 0, -0.035)
        addBase(.rightShoulder, 0, 0, 0.035)
        addBase(.leftUpperArm, -0.02, -0.10, -1.16)
        addBase(.rightUpperArm, -0.02, 0.10, 1.16)
        addBase(.leftLowerArm, 0.02, -0.30, -0.14)
        addBase(.rightLowerArm, 0.02, 0.30, 0.14)
        addBase(.leftHand, 0, 0, -0.05)
        addBase(.rightHand, 0, 0, 0.05)
        addBase(.leftUpperLeg, 0.01, 0, 0.015)
        addBase(.rightUpperLeg, 0.01, 0, -0.015)
    }

    private func addBase(_ bone: HumanoidBone, _ x: Float, _ y: Float, _ z: Float) {
        add(bone, x, y, z)
    }

    private func add(_ bone: HumanoidBone, _ x: Float, _ y: Float, _ z: Float) {
        guard boneRest[bone] != nil else { return }
        var value = offsets[bone] ?? .zero
        value += SIMD3<Float>(x, y, z)
        offsets[bone] = value
    }

    private func applyPose() {
        for (bone, rest) in boneRest {
            let offset = offsets[bone] ?? .zero
            let q = simd_quatf(angle: offset.z, axis: SIMD3<Float>(0, 0, 1))
                * simd_quatf(angle: offset.y, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: offset.x, axis: SIMD3<Float>(1, 0, 0))
            rest.node.transform.rotation = rest.base * q
        }
    }

    // MARK: - Offline-baked VRMA clips

    private var currentIdleClip: String {
        "idle_0\(min(4, max(1, idleClipIndex + 1)))"
    }

    @discardableResult
    private func playClip(_ name: String, loops: Bool) -> TimeInterval? {
        guard let model else { return nil }
        if currentClip == name, animationController != nil { return nil }
        animationController?.stop()
        animationController = nil
        currentClip = nil
        clipGeneration += 1
        do {
            let animation = try loadAnimation(name)
            let controller = try model.playAnimation(animation, loops: loops)
            animationController = controller
            currentClip = name
            return controller.animation.duration
        } catch {
            if verbose {
                FileHandle.standardError.write(
                    Data("mate-pet-native: clip \(name) unavailable: \(error.localizedDescription)\n".utf8))
            }
            return nil
        }
    }

    private func loadAnimation(_ name: String) throws -> VRMAnimation {
        if let cached = animationCache[name] { return cached }
        guard let root = Bundle.module.resourceURL else {
            throw NSError(domain: "MatePet", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "resource bundle missing"])
        }
        let url = root.appendingPathComponent("Resources/Animations/\(name).vrma")
        let animation = try VRMAnimation(withURL: url)
        animationCache[name] = animation
        return animation
    }

    private func stopClip() {
        animationController?.stop()
        animationController = nil
        currentClip = nil
        clipGeneration += 1
    }

    private func clipForState(_ state: MatePetState) -> String {
        switch state {
        case .idle: return currentIdleClip
        case .thinking: return "pose_01"
        case .talking: return currentIdleClip
        case .scanning: return "pose_01"
        case .cleaning: return currentIdleClip
        case .celebrating: return "happy"
        case .sleeping: return "sleep"
        case .sad: return "shy"
        }
    }

    private func playStateClip() {
        guard mode == nil, !dragActive, walkDir == 0 else { return }
        _ = playClip(clipForState(state), loops: true)
        if state == .idle { nextIdleSwitch = time + 12 }
    }

    private func playOneShot(_ name: String) {
        guard let duration = playClip(name, loops: false) else { return }
        let generation = clipGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.clipGeneration == generation,
                  self.mode == nil, !self.dragActive, self.walkDir == 0 else { return }
            self.playStateClip()
        }
    }

    private func applyState(_ t: TimeInterval) {
        let breath = Float(sin(t * 1.65))
        let sway = Float(sin(t * 0.48))
        let shift = Float(sin(t * 0.23))
        add(.spine, -0.012 + breath * 0.012, sway * 0.025, shift * 0.018)
        add(.chest, breath * 0.018, sway * 0.018, 0)
        add(.neck, -0.008, sway * 0.02, 0)
        add(.head, -0.006 + breath * 0.008, sway * 0.045, -shift * 0.018)
        add(.hips, 0, 0, shift * 0.012)

        switch state {
        case .thinking:
            add(.head, -0.08, 0.2, 0.16)
            add(.neck, 0.02, 0.1, 0.08)
            add(.rightUpperArm, -0.15, 0.65, 0.48)
            add(.rightLowerArm, 0.5, -0.35, -0.95)
            target(.relaxed, 0.55)
            target(.lookUp, 0.45)
        case .talking:
            add(.head, -0.04 + Float(sin(t * 3.1)) * 0.035,
                0.03 + Float(sin(t * 1.7)) * 0.05, 0)
            add(.leftUpperArm, 0, -0.14, 0.08)
            add(.rightUpperArm, 0, 0.14, -0.08)
            target(.happy, 0.35)
        case .scanning:
            let sweep = Float(sin(t * 1.15))
            add(.head, -0.03, sweep * 0.48, 0.06)
            add(.neck, 0, sweep * 0.22, 0)
            add(.rightUpperArm, -0.1, 0.9, 0.95)
            add(.rightLowerArm, 0.4, -0.4, -1.1)
            target(.lookLeft, sweep < 0 ? 0.5 : 0)
            target(.lookRight, sweep > 0 ? 0.5 : 0)
        case .cleaning:
            let scrub = Float(sin(t * 8.5))
            add(.spine, 0.09, 0, 0)
            add(.chest, 0.05, 0, 0)
            add(.head, 0.06, 0, 0)
            add(.leftUpperArm, -0.72, -0.55, 0.35)
            add(.rightUpperArm, -0.72, 0.55, -0.35)
            add(.leftLowerArm, 0.35, -0.65 + scrub * 0.12, -0.18)
            add(.rightLowerArm, 0.35, 0.65 - scrub * 0.12, 0.18)
            target(.angry, 0.16)
        case .celebrating:
            add(.head, -0.08, 0, 0.04)
            add(.leftUpperArm, -0.3, 0.2, 2.15)
            add(.rightUpperArm, -0.3, -0.2, -2.15)
            add(.leftLowerArm, 0, -0.2, 0.2)
            add(.rightLowerArm, 0, 0.2, -0.2)
            jump = abs(Float(sin(t * 6.2))) * 0.095
            target(.happy, 1)
            targetCustom("star", 0.8)
            targetCustom("heart", 0.35)
        case .sleeping:
            add(.head, 0.20, 0.16, 0.22)
            add(.neck, 0.08, 0.08, 0.08)
            add(.spine, 0.05, 0, 0.03)
            add(.chest, 0.03 + Float(sin(t * 1.1)) * 0.015, 0, 0)
            add(.leftUpperArm, 0.05, 0.1, 0.06)
            add(.rightUpperArm, 0.05, -0.1, -0.06)
            target(.blink, 1)
            target(.relaxed, 0.6)
        case .sad:
            add(.head, 0.26, -0.05, -0.04)
            add(.neck, 0.12, 0, 0)
            add(.spine, 0.10, 0, 0)
            add(.chest, 0.08, 0, 0)
            add(.leftUpperArm, 0.14, -0.06, -0.12)
            add(.rightUpperArm, 0.14, 0.06, 0.12)
            add(.leftLowerArm, 0.16, 0, 0)
            add(.rightLowerArm, 0.16, 0, 0)
            target(.sad, 1)
        case .idle:
            target(.happy, 0.10 + 0.04 * CGFloat(sin(t * 0.6)))
        }
    }

    private func applyStateExpressions() {
        switch state {
        case .celebrating:
            target(.happy, 1)
            targetCustom("star", 0.8)
            targetCustom("heart", 0.35)
        case .sleeping:
            target(.blink, 1)
            target(.relaxed, 0.6)
        case .sad:
            target(.sad, 1)
        case .thinking:
            target(.relaxed, 0.55)
            target(.lookUp, 0.45)
        case .scanning:
            target(.lookLeft, 0.4)
        case .talking:
            target(.happy, 0.35)
        case .idle, .cleaning:
            break
        }
    }

    private func applyMode(_ t: TimeInterval) {
        guard let mode else { return }
        let elapsed = time - modeStart
        let total = max(0.001, modeUntil - modeStart)
        let p = Float(max(0, min(1, elapsed / total)))

        switch mode {
        case .dance:
            let beat = Float(t * 5.4)
            let side = Float(sin(beat))
            add(.hips, 0, 0, side * 0.18)
            add(.spine, 0.03 * Float(cos(beat)), 0, -side * 0.12)
            add(.chest, 0, 0, -side * 0.08)
            add(.head, -0.06 + abs(Float(sin(beat))) * 0.06, side * 0.20, -side * 0.08)
            add(.leftUpperArm, -0.35, 0.1, 1.35 + side * 0.65)
            add(.rightUpperArm, -0.35, -0.1, -1.35 - side * 0.65)
            add(.leftLowerArm, 0.2, -0.4, 0.2 + side * 0.2)
            add(.rightLowerArm, 0.2, 0.4, -0.2 - side * 0.2)
            let step = Float(sin(beat * 2))
            add(.leftUpperLeg, -step * 0.25, 0, 0)
            add(.rightUpperLeg, step * 0.25, 0, 0)
            jump = abs(Float(sin(beat))) * 0.035
            target(.happy, 1)
            targetCustom("star", 0.65)
        case .hide:
            modeY = -p * 0.9
            add(.head, 0.25 * p, 0, 0.18 * p)
            target(.sad, 0.4)
        case .appear:
            modeY = -(1 - p) * 0.8
        case .wake:
            let s = Float(sin(p * .pi))
            add(.leftUpperArm, 0, 0, 1.1 * s)
            add(.rightUpperArm, 0, 0, -1.1 * s)
            add(.head, -0.08 * s, 0, 0)
            target(.happy, CGFloat(0.7 * s))
        case .stretch:
            let s = Float(sin(p * .pi))
            add(.leftUpperArm, 0, 0, 1.65 * s)
            add(.rightUpperArm, 0, 0, -1.65 * s)
            add(.head, -0.14 * s, 0, 0)
            target(.relaxed, CGFloat(0.55 * s))
        case .wave:
            let wave = Float(sin(p * .pi * 6)) * 0.22
            add(.rightUpperArm, -0.35, 0.3, 1.75)
            add(.rightLowerArm, 0, 0.1, -0.95 + wave)
            add(.head, -0.03, 0.08, 0.08)
            target(.happy, 0.7)
        default:
            break
        }
    }

    private func applyDrag(_ t: TimeInterval) {
        let energy = dragEnergy
        let desired = max(-0.4, min(0.4, -energy.x * 0.11))
        lean += (desired - lean) * 0.18
        add(.hips, 0, 0, lean * 0.35)
        add(.spine, max(-0.12, min(0.12, energy.y * 0.02)), 0, lean * 0.5)
        add(.chest, 0, 0, lean * 0.25)
        add(.head, max(-0.1, min(0.1, -energy.y * 0.015)), lean * 0.2, -lean * 0.35)
        if dragActive {
            add(.leftUpperArm, -0.25, -0.2, 1.75)
            add(.rightUpperArm, -0.25, 0.2, -1.75)
            add(.leftLowerArm, 0.25, -0.4, -0.35)
            add(.rightLowerArm, 0.25, 0.4, 0.35)
            let kick = Float(sin(t * 9)) * 0.22
            add(.leftUpperLeg, -kick * 0.6, 0, 0)
            add(.rightUpperLeg, kick * 0.6, 0, 0)
            add(.leftLowerLeg, 0.35 + kick * 0.2, 0, 0)
            add(.rightLowerLeg, 0.35 - kick * 0.2, 0, 0)
            target(.surprised, 0.6)
        } else {
            dragEnergy *= 0.92
            lean *= 0.92
        }
    }

    private func applyLook(_ t: TimeInterval) {
        let asleep = state == .sleeping
        let weight: Float = asleep ? 0.15 : 1
        let yaw = (look.x * 2 - 1) * 38 * .pi / 180
        let pitch = -(look.y * 2 - 1) * 24 * .pi / 180
        lookYaw += (yaw - lookYaw) * 0.16
        lookPitch += (pitch - lookPitch) * 0.16
        if animationController == nil {
            add(.head, lookPitch * 0.85 * weight, lookYaw * 0.85 * weight, 0)
            add(.neck, lookPitch * 0.25 * weight, lookYaw * 0.28 * weight, 0)
            add(.chest, 0, lookYaw * 0.12 * weight, 0)
        }
        model?.lookAtTarget = .angles(yaw: lookYaw * 180 / .pi, pitch: -lookPitch * 180 / .pi)
    }

    private func applyTalking(_ t: TimeInterval) {
        guard talking, time < talkingUntil else {
            if !talking { talkingUntil = 0 }
            return
        }
        visemeClock -= 0.016
        if visemeClock <= 0 {
            visemeClock = 0.08 + Double.random(in: 0...0.08)
            visemeIndex = (visemeIndex + 1 + Int.random(in: 0..<4)) % 5
        }
        let presets: [ExpressionPreset] = [.aa, .ih, .ou, .ee, .oh]
        target(presets[visemeIndex], 0.42 + 0.22 * CGFloat(abs(sin(time * 0.025))))
    }

    private func applyBlink(_ t: TimeInterval) {
        if time > nextBlink {
            blinkStart = time
            nextBlink = time + 2.1 + Double.random(in: 0...3.9)
        }
        let progress = (time - blinkStart) / 0.15
        var value: CGFloat = 0
        if progress >= 0 && progress <= 1 {
            value = progress < 0.5
                ? CGFloat(smoothstep(Float(progress * 2)))
                : CGFloat(1 - smoothstep(Float((progress - 0.5) * 2)))
        }
        if state == .sleeping { value = 1 }
        blinking = value
        target(.blink, value)
    }

    private func applyPoke(_ t: TimeInterval) {
        let elapsed = time - pokeStart
        guard elapsed < 0.62 else { return }
        let k = CGFloat(1 - elapsed / 0.62)
        let direction: Float = sin(Float(elapsed) * 0.02) > 0 ? 1 : -1
        if pokeRegion == .head {
            add(.head, -0.22 * Float(k), direction * 0.18 * Float(k), 0.24 * Float(k))
            add(.neck, -0.06 * Float(k), direction * 0.08 * Float(k), 0.08 * Float(k))
        } else {
            jump += Float(sin((elapsed / 0.62) * .pi)) * 0.016
            add(.spine, -0.06 * Float(k), 0, 0)
        }
    }

    private func applyPet(_ t: TimeInterval) {
        let elapsed = time - petStart
        guard elapsed < 1.2 else { return }
        let k = Float(sin((elapsed / 1.2) * .pi))
        add(.head, -0.08 * k, 0.12 * k, 0.12 * k)
        target(.relaxed, 0.7 * CGFloat(k))
        target(.happy, 0.8 * CGFloat(k))
    }

    private func applyWalk(_ t: TimeInterval) {
        guard walkDir != 0, mode == nil else { return }
        let phase = Float(t * 9)
        let swing = Float(sin(phase))
        add(.leftUpperLeg, -swing * 0.34, 0, 0)
        add(.rightUpperLeg, swing * 0.34, 0, 0)
        add(.leftLowerLeg, 0.12 + max(0, swing) * 0.35, 0, 0)
        add(.rightLowerLeg, 0.12 + max(0, -swing) * 0.35, 0, 0)
        add(.leftUpperArm, 0, 0, -swing * 0.28)
        add(.rightUpperArm, 0, 0, swing * 0.28)
        jump = abs(Float(sin(phase))) * 0.012
        target(.happy, 0.18)
    }

    // MARK: - Expressions

    private func target(_ preset: ExpressionPreset, _ value: CGFloat) {
        guard let key = self.preset(preset) else { return }
        expressionTarget[key] = max(expressionTarget[key] ?? 0, max(0, min(1, value)))
    }

    private func targetCustom(_ name: String, _ value: CGFloat) {
        guard let key = expression(name) else { return }
        expressionTarget[key] = max(expressionTarget[key] ?? 0, max(0, min(1, value)))
    }

    private func applyExpressions() {
        guard let model else { return }
        for (key, value) in expressionTarget {
            let current = expressionCurrent[key] ?? 0
            expressionCurrent[key] = current + (value - current) * 0.2
        }
        let keys = Array(expressionCurrent.keys)
        for key in keys where expressionTarget[key] == nil {
            expressionCurrent[key] = (expressionCurrent[key] ?? 0) * 0.9
        }
        let weights = expressionCurrent.filter { $0.value > 0.001 }
        // Send even an empty dictionary so a finished expression really
        // returns to zero instead of freezing at its last weight.
        model.setExpressions(weights)
    }

    // MARK: - Chibi / camera

    private func applyChibi(_ delta: TimeInterval) {
        guard let model else { return }
        chibi += (chibiTarget - chibi) * 0.18
        // Mate-Engine's ChibiToggle.cs scales the armature root by 0.3, the
        // head by 2.7 and both upper legs by 0.6 (all relative). Scaling the
        // model root keeps Body / LongSleeve / Clothes under one transform, so
        // the hands stay inside the sleeve cuffs; the old 0.45 / 1.3 / 1.15
        // mix shrank the body but barely moved the head, which read as a
        // detached head with floating sleeves.
        model.transform.scale = baseScale * (1 - 0.7 * chibi)
        headNode?.transform.scale = SIMD3<Float>(repeating: 1 + 1.7 * chibi)
        leftLegNode?.transform.scale = SIMD3<Float>(repeating: 1 - 0.4 * chibi)
        rightLegNode?.transform.scale = SIMD3<Float>(repeating: 1 - 0.4 * chibi)

        // Refit while the mix moves, and once more when it settles: the damped
        // mix never lands exactly on the target, so a pure 0.015 threshold
        // left the camera framing the 0.86 snapshot instead of 1.0.
        let settled = abs(chibiTarget - chibi) < 0.01
        if abs(chibi - lastChibiFit) > 0.015 || (settled && abs(chibi - lastChibiFit) > 0.001) {
            lastChibiFit = chibi
            let savedY = model.transform.translation.y
            model.transform.translation.y = 0
            let bounds = model.visualBounds(relativeTo: renderRoot)
            groundOffset = -bounds.min.y
            model.transform.translation.y = savedY
            refitCamera()
        }
    }

    private func refitCamera() {
        guard let model, let cameraNode else { return }
        // Fit the *current* silhouette. The old fixed 1.55m stage kept the
        // camera at full-body distance while Chibi shrank the armature to 0.3,
        // so the pet shrank to a stamp in the middle of the panel.
        let bounds = model.visualBounds(relativeTo: renderRoot)
        let measuredH = bounds.max.y - bounds.min.y
        let measuredW = bounds.max.x - bounds.min.x
        // visualBounds() ignores joint scale, so blend in the analytic chibi
        // silhouette: armature ×0.3, head ×2.7, upper legs ×0.6.
        let armature = 1 - 0.7 * chibi
        let headScale = 1 + 1.7 * chibi
        let headTop = (headRestY + headRadius * headScale) * armature
        let height = max(0.30, max(measuredH.isFinite ? measuredH : baseHeight, headTop))
        let width = max(0.24, max(measuredW.isFinite ? measuredW : baseWidth, baseWidth * armature))
        let bottom = bounds.min.y
        let center = SIMD3<Float>(0, bottom + height * 0.5, 0)
        // Fit BOTH axes: the VRM's T-pose/hair bounds are wide, and dance
        // clips go wider still; height-only framing clipped the hands.
        let distance = max(height * 1.9, width * 2.4) + 0.3
        cameraGoalLook = center
        cameraGoalPosition = center + SIMD3<Float>(0, height * 0.03, -distance)
        if verbose {
            FileHandle.standardError.write(Data(
                "mate-pet-native: refit h=\(height) w=\(width) d=\(distance) chibi=\(chibi) bounds=\(bounds.min)-\(bounds.max)\n".utf8))
        }
        if !cameraInitialized {
            cameraInitialized = true
            cameraNode.position = cameraGoalPosition
            cameraNode.look(at: cameraGoalLook, from: cameraGoalPosition, relativeTo: renderRoot)
        }
    }

    private func smoothstep(_ x: Float) -> Float {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }
}
/// Very small native synth for the handful of interaction sounds. The WebView
/// backend has a fuller Web Audio kit; this keeps the native path from being
/// silent without shipping audio assets.
@available(macOS 15.0, *)
@MainActor
private final class NativePetAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false
    private var danceTimer: Timer?
    var muted = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func unlock() {
        guard !started else { return }
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            // No output device / permission: stay silent rather than crash.
        }
    }

    func poke() {
        guard !muted else { return }
        tone(from: 960, to: 1380, seconds: 0.075, gain: 0.16)
        tone(from: 1380, to: 1080, seconds: 0.09, gain: 0.10)
    }

    func happy() {
        guard !muted else { return }
        for note in [523.25, 659.25, 783.99, 1046.5] {
            tone(from: note, to: note, seconds: 0.09, gain: 0.13)
        }
    }

    func pet() {
        guard !muted else { return }
        tone(from: 46, to: 46, seconds: 0.7, gain: 0.11, purr: true)
    }

    func chibiOn() {
        guard !muted else { return }
        for note in [880.0, 1174.0, 1568.0, 2093.0] {
            tone(from: note, to: note * 1.02, seconds: 0.1, gain: 0.10)
        }
    }

    func danceStart() {
        danceStop()
        guard !muted else { return }
        var beat = 0
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.muted else { return }
                if beat % 2 == 0 { self.tone(from: 130, to: 52, seconds: 0.14, gain: 0.2) }
                else { self.tone(from: 220, to: 180, seconds: 0.06, gain: 0.05) }
                beat += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        danceTimer = timer
    }

    func danceStop() {
        danceTimer?.invalidate()
        danceTimer = nil
    }

    private func tone(from f0: Double, to f1: Double, seconds: Double, gain: Float, purr: Bool = false) {
        unlock()
        guard started, let buffer = makeBuffer(from: f0, to: f1, seconds: seconds, gain: gain, purr: purr) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    private func makeBuffer(from f0: Double, to f1: Double, seconds: Double, gain: Float, purr: Bool) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(max(1, seconds * format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let progress = t / max(0.0001, seconds)
            let frequency = f0 + (f1 - f0) * progress
            phase += 2 * .pi * frequency / format.sampleRate
            let envelope = min(1, t * 60) * pow(1 - progress, 1.4)
            let tremolo = purr ? (0.65 + 0.35 * sin(2 * .pi * 22 * t)) : 1
            channel[i] = Float(sin(phase) * envelope * tremolo) * gain
        }
        return buffer
    }
}
