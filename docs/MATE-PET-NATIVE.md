# MATE-PET-NATIVE — macOS 15+ RealityKit 原生桌宠规格

> 版本：1.0（2026-11-13）
> 状态：已实现并通过 `swift build`；在 macOS 27 实机加载 `Zome.vrm`（bounds `±0.685 × 1.55`）并播放 18 个离线烘焙 `.vrma`。
> 相关文档：WebView 回退与模块总览见 [`MATE-PET-MODULE.md`](MATE-PET-MODULE.md)。

---

## §1 目标与硬约束

| 项 | 规格 |
| --- | --- |
| 目标 | macOS 15+ 使用 **RealityKit + VRMRealityKit** 原生渲染 Zome.vrm |
| 回退 | macOS 14 自动使用现有 `MatePetEngine`（WKWebView + three-vrm） |
| 大脑 | 不变：`PetBus → QuickChat → BrainAgent` |
| 窗口 | 现有 `PetPanel`（透明、无边框、floating、全空间） |
| 渲染库 | `VRMKit` 0.11.0 / `VRMRealityKit` 0.11.0（MIT） |
| Swift | 6.0+（项目 target 使用 Swift 5 language mode） |

**为什么必须 macOS 15**：`VRMRealityKit` 的渲染层 API（`VRMEntity`、`VRMEntityLoader`、`GLTFDeformedMesh`、MToon `CustomMaterial` 等）全部标注 `@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)`。`VRMKit` 解析层本身支持 macOS 12，但 RealityKit 渲染层不支持。

**为什么仍保留 WebView**：macOS 14 没有可用的 VRMRealityKit；回退版本已经在 `MatePet` 内实现并通过 `--probe-pet-shot`，两者共享同一套宿主 API。

---

## §2 后端选择

`PetPanelController` 在首次构建面板时决定：

```swift
private lazy var engine: any MatePetRendering = {
    let engine: any MatePetRendering
    if ProcessInfo.processInfo.environment["MOPPET_PET_WEBVIEW"] == "1" {
        engine = MatePetEngine()          // 强制兼容渲染器
    } else if #available(macOS 15.0, *) {
        engine = MatePetNativeEngine()    // RealityKit 原生
    } else {
        engine = MatePetEngine()          // macOS 14 回退
    }
    engine.onEvent = { [weak self] event in self?.handle(event) }
    return engine
}()
```

两个实现都满足 `MatePetRendering`：

```swift
@MainActor public protocol MatePetRendering: AnyObject {
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
    func setWalking(_ direction: Int)
    func setMuted(_ muted: Bool)
    func setPaused(_ paused: Bool)
    func audioUnlock()
    func syncPreferences()
}
```

因此 `PetView`、`MatePetSceneView`、`MatePetInteractionView`、`MatePetWander` 完全不需要知道当前是哪个后端。

---

## §3 模块结构

```
Sources/MatePet/
  MatePetRendering.swift          ← 双后端协议
  MatePetEngine.swift             ← WebView 后端（macOS 14 回退）
  MatePetNativeEngine.swift       ← RealityKit 后端（macOS 15+）
  MatePetNativeSceneView.swift    ← RealityView 承载 + 加载 spinner
  MatePetSceneView.swift          ← 按 engine 类型选择宿主
  MatePetInteractionView.swift    ← AppKit 指针/拖拽/点击（后端无关）
  MatePetState.swift              ← 状态/动作/事件/偏好
  Resources/Zome.vrm              ← 同一份 Mate-Engine 模型
```

依赖：

```swift
.package(url: "https://github.com/tattn/VRMKit.git", from: "0.11.0")
```

`MatePet` target 依赖 `VRMKit` + `VRMRealityKit`；`VRMRealityKit` 自带 `VRMKit_VRMRealityKit.bundle`（MToon metallibs），打包时必须一起复制。

---

## §4 原生加载管线

```swift
let url = Bundle.module.resourceURL!
    .appendingPathComponent("Resources/Zome.vrm")
let loader = try VRMEntityLoader(withURL: url)
let entity = try await loader.loadEntity()
entity.setMToonLightDirection(simd_normalize(SIMD3(-0.35, -0.55, -0.75)))
renderRoot.addChild(entity)
```

步骤：

1. `startIfNeeded()`：创建 `PerspectiveCamera`、两盏 `DirectionalLight`、`renderRoot`；立即 `isPageReady = true` 并发送 `.ready`（面板显示，`MatePetNativeContainerView` 显示 spinner）。
2. `Task { await loadModel() }` 在后台异步加载 VRM。
3. `loadEntity()` 返回 `VRMEntity`，VRMRealityKit 已建立：
   - MToon 材质与描边；
   - humanoid 骨骼（`humanoid.node(for: .head)` 等）；
   - 24 组 BlendShape（`availableExpressions`）；
   - look-at；
   - springBone（头发/裙摆）。
4. 归一化尺寸：
   - `visualBounds` 高度 → `scale = 1.55 / height`；
   - 重新取 bounds，`groundOffset = -min.y`，让脚落在地面。
5. 捕获每根骨骼的 `transform.rotation` 作为 rest；之后每帧只写 `rest * delta`。
6. `entity.isAutomaticUpdateEnabled = false`；由 60Hz `Timer` 手动驱动：
   ```swift
   frame(delta)                  // 写骨骼/表情/lookAt
   model.update(deltaTime: delta) // 约束、springBone、蒙皮
   ```
7. `onModelReady?()` 隐藏 spinner；`onEvent?(.modelReady)`。
8. 播放离线烘焙的 `.vrma`（见 §4.1）。有 clip 时，`frame(delta)` 不再写 humanoid 骨骼，只叠加 look-at / 表情 / Chibi；没有 clip 时退回程序化姿态。

**为什么手动 tick**：VRMRealityKit 0.11.0 没有公开的 `setUpdateHandler`（main 分支有，tag 没有）。手动 tick 同时给了暂停/降频的唯一入口。

### §4.1 离线烘焙 Unity `.anim` → `.vrma`

脚本：`tools/matepet-vrma-bake.cs`（内置 `VrmAnimationExporter` 的 Unity Editor 脚本）。

| 项 | 值 |
| --- | --- |
| 输入 | Mate-Engine 的 `Zome.prefab` + Humanoid `.anim` |
| 采样 | Animator + `AnimationClipPlayable`，60fps，`PlayableGraph.Evaluate(0)` |
| 导出 | `UniVRM10.VrmAnimationExporter` → `VRMC_vrm_animation` GLB |
| 输出 | `Sources/MatePet/Resources/Animations/*.vrma` |
| 修过的坑 | 末帧 `clip.length` 与 `i/fps` 浮点四舍五入到同一时间，导致 VRMKit 拒绝 `input times must be strictly increasing`；脚本只添加严格递增的时间 |

烘焙命令（需要 Unity 2022.3，且先移出缺少第三方包的脚本目录）：

```sh
"/Applications/Unity/Hub/Editor/2022.3.62f2c1/Unity.app/Contents/MacOS/Unity"   -batchmode -nographics -quit   -projectPath Mate-Engine   -executeMethod UniVRM10.MatePetBake.Bake   -logFile /tmp/matepet-bake.log
```

本次产物（18 个）：

```
idle_01..04, talk(skip), happy, laugh, drag, shy,
dance_01..04, sleep, walk_left, walk_right, hide, pose_01, intro
```

`PET_TALKING.anim` 只有 BlendShape/口型曲线，`clip.isHumanMotion == false`，VRMA 导出器只导出人形骨骼，所以跳过；口型继续由程序化 viseme 驱动。

---

## §5 朝向与相机

| 项 | 值 |
| --- | --- |
| VRM 0.x 前向 | `-Z`（`VRM.forwardDirection`） |
| 相机位置 | `(0, centerY + 0.03h, -distance)`，看向 `center` |
| FOV | 30° |
| 舞台 | 固定 `baseHeight=1.55m`、`baseWidth=1.37m`；Chibi 不改变舞台，避免大头被裁 |
| distance | `max(1.55 * 1.9, 1.37 * 2.4) + 0.3 ≈ 3.59` |
| 模型旋转 | **不改**（不像 WebView 那样 `scene.rotation.y = π`） |

因为模型面朝 `-Z`，相机放在 `-Z` 才会正脸看模型。WebView 中 three-vrm 的 `rotateVRM0` 把模型转到 `+Z`，所以相机在 `+Z`；两套坐标系不要混用。

---

## §6 骨骼姿态

### §6.1 rest 捕获

```swift
for bone in HumanoidBone.allCases {
    guard let node = entity.humanoid.node(for: bone) else { continue }
    boneRest[bone] = BoneRest(node: node, base: node.transform.rotation)
}
```

### §6.2 每帧叠加

```swift
let q = simd_quatf(angle: offset.z, axis: [0,0,1])
      * simd_quatf(angle: offset.y, axis: [0,1,0])
      * simd_quatf(angle: offset.x, axis: [1,0,0])
node.transform.rotation = rest * q
```

`offset` 来自：

1. 基础站姿（手臂下垂）；
2. 状态/动作；
3. 拖拽 lean；
4. 视线（头/颈/胸）；
5. 戳一戳/摸头。

基础站姿与 WebView 版本一致：

| 骨骼 | X | Y | Z |
| --- | --- | --- | --- |
| leftUpperArm | -0.02 | -0.10 | -1.16 |
| rightUpperArm | -0.02 | +0.10 | +1.16 |
| leftLowerArm | +0.02 | -0.30 | -0.14 |
| rightLowerArm | +0.02 | +0.30 | +0.14 |
| leftUpperLeg | +0.01 | 0 | +0.015 |
| rightUpperLeg | +0.01 | 0 | -0.015 |

### §6.3 状态/动作

与 WebView 版 `PetRig` 相同的姿态表：

| state | 播放 clip | 叠加 |
| --- | --- | --- |
| idle | `idle_01..04` 轮换（12s） | 眨眼、look-at、随机小动作已由程序化表情层补充 |
| thinking | `pose_01` | relaxed / lookUp |
| talking | `idle_0x` | 程序化 viseme + 点头表情 |
| scanning | `pose_01` | lookLeft/Right |
| cleaning | `idle_0x` | 无专用 clip，保留待机身体 |
| celebrating | `happy` | happy/star/heart |
| sleeping | `sleep` | blink 1 / relaxed |
| sad | `shy` | sad |

> 有 clip 时不再写骨骼；`pose_01` 等没有完全对应语义的 clip 只是身体基底，情绪由表情层表达。

一次性动作：dance / hide / appear / wake / stretch / wave / poke / pet / walk。逻辑与 WebView 版一致，只是写入 `Entity.transform.rotation`。

### §6.4 Chibi

| 层 | 比例 |
| --- | --- |
| root（`model.transform.scale`） | `baseScale * (1 - 0.7 * mix)`（0.3） |
| head（raw node） | `1 + 1.7 * mix` |
| left/rightUpperLeg | `1 - 0.4 * mix`（0.6） |

每次 `mix` 变化 >0.015 时：

1. 临时把 `model.transform.translation.y = 0`；
2. 取 `visualBounds`，`groundOffset = -min.y`；
3. 恢复 translation；
4. `refitCamera()`。

与 WebView 版一致：世界身体 0.3×、头 0.81×（相对头 2.7×）、大腿 0.18×。

**相机拟合的坑**：RealityKit 的 `visualBounds()` 返回的是 bind pose 静态包围盒，**看不到关节缩放**（日志里 Chibi 全开时仍报 1.55m）。所以不能只靠 bbox 拟合，`refitCamera()` 用解析轮廓：

```swift
let armature = 1 - 0.7 * chibi      // 0.3
let headScale = 1 + 1.7 * chibi     // 2.7
let headTop = (headRestY + headRadius * headScale) * armature
let height = max(measuredHeight, headTop)   // 0.63m @ chibi=1
```

`headRestY` / `headRadius` 在加载时记录（头关节高度与头顶余量），这样 Chibi 时宠物仍占面板约 60% 高度且不裁切。

---

## §7 表情 / 视线 / 口型

### §7.1 表达式索引

`entity.availableExpressions` 返回 `[ExpressionInfo]`；建立：

```swift
expressionKeys["joy"] = info.key     // VRM0 Joy → preset(.happy)
expressionKeys["preset:happy"] = ...
expressionKeys["heart"] = .custom("Heart") // 若模型提供
```

VRM 0.x 名称映射：`joy → happy`、`fun → relaxed`、`sorrow → sad`、`a/i/u/e/o → aa/ih/ou/ee/oh`、`blink_l/r → blinkLeft/Right`。

### §7.2 每帧表情

- state/action/poke 用 `max()` 累积 `expressionTarget`；
- `expressionCurrent` 每帧向 target 阻尼 0.2；
- **即使权重为空也调用 `entity.setExpressions(weights)`**，否则上一个表情会冻结在最后值。

### §7.3 视线

```swift
model.lookAtTarget = .angles(yaw: lookYaw * 180 / .pi,
                             pitch: -lookPitch * 180 / .pi)
```

同时给头/颈/胸叠加 additive 旋转；VRM 有 look-at 时眼睛由 VRMRealityKit 驱动。

### §7.4 口型

`talking` 时每 70–150ms 切换 `aa/ih/ou/ee/oh`，权重 `0.42 + 0.22*|sin|`；与 WebView 版一致的伪 viseme。

---

## §8 交互

交互层完全复用 `MatePetInteractionNSView`：

| 事件 | 原生实现 |
| --- | --- |
| 鼠标移动 | `look(atNormalizedX:y:)` → `lookAtTarget` + 头/颈/胸 |
| 单击头/身体 | `poke(region:count:)`：歪头/小跳 + happy/surprised + 原生 chirp |
| 连续摸头 | `play(.pet)`：purr + happy/heart |
| 拖拽 | `dragBegan/Moved/Ended` → lean + 双手上抬 + 双腿摆动 |
| 右键 | 宿主 NSMenu（Dance/Wave/Stretch/Chibi/Wander/Sound/Sleep/Hide） |
| 双击 | 打开聊天窗 |
| 漫步 | 宿主移动 NSPanel；原生引擎只做腿/臂动画 |

---

## §9 原生音效

`NativePetAudio`：`AVAudioEngine` + `AVAudioPlayerNode`，无音频资源。

| 音效 | 实现 |
| --- | --- |
| poke | 960→1380Hz / 1380→1080Hz 两段正弦包络 |
| happy | 523/659/784/1046Hz 四音 |
| pet | 46Hz 正弦 + 22Hz tremolo，700ms |
| chibi | 880/1174/1568/2093Hz 上行 |
| dance | 0.45s 间隔的 130→52Hz kick + 220→180Hz hat |

首次用户手势调用 `audioUnlock()` → `AVAudioEngine.start()`；`setMuted` 只置 `muted`，`tone` 直接 return。

---

## §10 性能与生命周期

| 项 | 原生策略 |
| --- | --- |
| 动画 | 优先播放 `Resources/Animations/*.vrma`；无 clip 才使用程序化姿态 |
| 默认 tick | 60Hz `Timer` + `model.update(deltaTime:)` |
| 面板隐藏 | `setPaused(true)` → `stopTicker()`；`RealityView` 保持静态 |
| 显示 | `setPaused(false)` → `startTicker()` |
| 加载中 | `NSProgressIndicator` spinner；`onModelReady` 隐藏 |
| Spring bones | 每次 `model.update` 自动步进 |
| 加载 | 26MB VRM；实测 debug 构建约 20–35s，release 更快 |
| 内存 | RealityKit + VRM 纹理，预计高于 WebView；未做硬性 50MB 保证 |
| 降频 | 当前固定 60Hz；后续可把 `Timer` 间隔切到 1/30（idle） |
| 休眠 | `Timer` 在 `paused` 时不写骨骼/不更新模型 |

---

## §11 打包

`scripts/make-app.sh` 复制所有 SwiftPM 资源包：

```sh
for bundle in "$ROOT"/.build/release/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done
```

必须包含：

| bundle | 内容 |
| --- | --- |
| `Moppet_MatePet.bundle` | `Resources/Zome.vrm`、`mate-pet.html`、vendor |
| `Moppet_Moppet.bundle` | 贴纸、brand |
| `VRMKit_VRMRealityKit.bundle` | MToon metallibs 等 |

WebView 回退的 ATS 本地网络例外（`NSAllowsLocalNetworking`）仍保留；原生路径不启动本地服务器。

---

## §12 验证

### §12.1 编译

```sh
swift build
```

已通过，且无 warning。

### §12.2 原生加载

```sh
MOPPET_MATE_PET_DEV=1 .build/debug/Moppet --win-debug
```

期望日志：

```
mate-pet-native: start
mate-pet-native: model ready bounds=SIMD3<Float>(-0.6850361, 0.0, -0.17759599)-SIMD3<Float>(0.6850361, 1.55, 0.5949647)
```

实测已出现，说明：
- `VRMEntityLoader` 成功；
- 53 根人形骨骼建立；
- 模型缩放至 1.55m 高、脚在 y=0；
- 相机/灯光/RealityView 已挂载。

### §12.3 透明与可交互

- `PetPanel` 仍 `isOpaque=false`、`backgroundColor=.clear`；
- `RealityView` 外壳 `.background(Color.clear)`；
- `MatePetNativeContainerView.hitTest` 返回 nil，鼠标交给上方 `MatePetInteractionNSView`；
- 实机全屏截图显示宠物区域与桌面背景交替（非整块单色），说明窗口透明。

### §12.4 回退

```sh
MOPPET_PET_WEBVIEW=1 .build/debug/Moppet --probe-pet-shot /tmp/web.png 460 540
```

WebView 探针仍通过（`canvas.toDataURL` 自截图）。

### §12.5 验收清单

| 项 | 状态 |
| --- | --- |
| Unity `.anim` → `.vrma` 离线烘焙（18 个） | ✅ |
| VRMA 时间轴严格递增（末帧去重） | ✅ |
| `MatePetRendering` 双后端协议 | ✅ |
| macOS 15+ 自动 native | ✅ |
| macOS 14 自动 WebView | ✅ |
| `MOPPET_PET_WEBVIEW=1` 强制回退 | ✅ |
| VRMRealityKit 加载 Zome.vrm | ✅ |
| 骨骼/表情/lookAt/springBone | ✅（由 VRMRealityKit 驱动） |
| 程序化 idle/thinking/talking/scanning/cleaning/celebrating/sleeping/sad | ✅ |
| Drag/poke/pet | ✅ |
| Dance/Wave/Stretch/Chibi/Walk/Hide | ✅ |
| 原生合成音效 | ✅ |
| 加载 spinner | ✅ |
| 暂停/隐藏停止 tick | ✅ |
| 打包复制 VRMKit bundle | ✅ |
| 原生离屏截图探针 | ⏳（当前用 WebView 探针；RealityView 无稳定 offscreen snapshot） |
| macOS 12 支持 | ⚠️ 不满足：VRMRealityKit 渲染层要求 macOS 15 |

---

## §13 已知限制

| 项 | 说明 |
| --- | --- |
| macOS 15 硬门槛 | 原生渲染不能下探到 12/14；14 只能 WebView |
| 口型/表情 clip | `PET_TALKING` 非 Humanoid，VRMA 不含表情曲线；口型仍程序化 viseme |
| 原生截图探针 | RealityView 无 `takeSnapshot`；`GLTFEntity.snapshot()` 返回实体副本而非图片 |
| 口型 | 伪 viseme，不是音素对齐 |
| 50MB 内存目标 | 未做严格测量；VRM 纹理 + RealityKit 开销可能超过 |
| 固定 60Hz | 尚未做 idle 30Hz/自动降频 |
| 窗口坐姿 | 未实现跨 App 窗口吸附 |

---

## §14 复刻步骤

1. `Package.swift` 添加 `VRMKit` 0.11.0，`MatePet` 依赖 `VRMKit` + `VRMRealityKit`。
2. 新增 `MatePetRendering` 协议；让 `MatePetEngine` 满足。
3. 新增 `MatePetNativeEngine`（`@available(macOS 15.0, *)`）：
   - `renderRoot` + `PerspectiveCamera` + 2 盏 `DirectionalLight`；
   - `VRMEntityLoader(withURL:)` 加载 `Resources/Zome.vrm`；
   - 捕获 rest 骨骼、表达式索引、look-at；
   - `isAutomaticUpdateEnabled=false` + 60Hz Timer → `frame(delta)` + `model.update(deltaTime:)`；
   - 实现协议全部方法。
4. 新增 `MatePetNativeSceneView`（`RealityView` + spinner + clear background）。
5. `MatePetSceneView` 按 engine 类型选择 native/web；`MatePetInteractionView` 改用协议。
6. `PetPanelController` 按 `#available(macOS 15)` 选后端，`MOPPET_PET_WEBVIEW=1` 强制 WebView。
7. 打包复制所有 `.bundle`。
8. 按 §12 验证。