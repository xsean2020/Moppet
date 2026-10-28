# Swift 本地小模型选型分析（Moppet Brain）

> **状态**：选型分析，未改代码。写于 2026-10-28。
> **问题**：有没有 Swift 原生的 LLM 方案，能直接嵌进 app、性能可接受（不能很慢）？
> **前提（已核实）**：开发机 = **Mac mini / Apple M1 / 8 GB**；工具链 = **Swift 6.2.3 / Xcode 26.2**；`Package.swift` = `swift-tools-version:6.0`、`.macOS(.v14)`、`swiftLanguageMode(.v5)`；SPM 可执行目标；另有 MAS 上架计划（`docs/APPSTORE_PLAN.md`）。

---

## 0. 结论摘要（30 秒版）

1. **有，而且不止一个。** 2026 年 Apple 平台的本地推理已经收敛成 4 条路：**Foundation Models**（系统自带 3B）、**Core AI**（macOS 27 起，自带模型）、**MLX**（Apple Silicon GPU）、**llama.cpp/GGUF**（通用）。外面还有一层统一封装 **AnyLanguageModel**。

2. **但对你的机器，最该选的不是"自己 ship 模型"，而是"用系统的"。** 8 GB 内存是硬约束：Moppet 自己（SceneKit 3D 宠物 + 清理引擎）已经吃掉一部分，再常驻一个 1.1 GB 的 1.7B 模型，系统会开始换页。**Foundation Models 的模型跑在系统服务里，App 内存占用≈0、零下载、Apple 针对 ANE 调过**——在 8 GB M1 上这是唯一"不折腾且不慢"的本地路径。

3. **`AnyLanguageModel` 是架构上最漂亮的选择，但现在装不上。** 它要求 **Swift 6.3+ / Xcode 26.4+**，你是 **6.2.3 / 26.2**。它把 Foundation Models / MLX / llama.cpp / Core ML / Ollama / 云端统一到一个 `LanguageModel` 协议，**工具调用全后端支持**，`macOS 14.0+` 起。**升级 Xcode 后它就是首选**，现在只能等。

4. **`llama.swift` 是现在唯一"今天就能跑"的纯本地方案**：Swift 6.0+ / macOS 13+ / XCFramework（预编译，不用 CMake）。但它只是 **llama.cpp 的 C API 直出**，chat template、采样循环、工具调用解析都要自己写（约 400–600 行），**脆弱点全在工具调用解析**。

5. **性能上，M1/8GB 的真实答案是：0.6B 级够用，1.7B 勉强，3B 别想。** 决策层只要 ≤8 个 token 输出，0.6B 约 **70–110 tok/s** → 一次决策 **~0.1–0.2 s**，可接受；但**拿它替代主脑做工具调用会明显变笨**（见 §5）。

6. **最重要的一条：决策层根本不需要 LLM。** 上一轮已经算过——60 次/天的决策全走主模型只占总量 32%，而规则是 0。**引入本地小模型的正当理由不是省钱，是：离线可用、隐私（文件路径不出机器）、以及规则覆盖不到的长尾。** 但我今天**实测了系统自带的 embedding，想用它零成本解决"检索"这一层，结果是不可用**（见 §3.6：`NLEmbedding` 中文句向量把"写一首春天的诗"排在"不要清理 docker"前面）。所以检索这一层不要指望系统能力，**改成给 cue 显式挂别名**——我们写的 cue，我们自己知道它是什么意思，没必要让模型去猜。

---

## 1. 先看约束：你的项目卡在哪

选型不是选"最好的"，是选"能装进来的"。四条硬约束：

| # | 约束 | 现状 | 影响 |
|---|---|---|---|
| C1 | **部署目标 macOS 14** | `platforms: [.macOS(.v14)]` | Foundation Models（26+）、Core AI（27+）**只能 `if #available` 增强**，不能当主路径 |
| C2 | **Swift 6.2.3 / Xcode 26.2** | 实测 `swift --version` | `AnyLanguageModel` 要 **6.3 / 26.4** → **当前装不上** |
| C3 | **8 GB 统一内存** | M1 Mac mini | 常驻模型 ≤ 600 MB 才安全；1.7B(1.1GB) 会让系统换页 |
| C4 | **语言模式钉在 Swift 5** | `swiftLanguageMode(.v5)` | 依赖自带的 Swift 6 并发没问题，但**新代码不能依赖 6.0 严格并发**去写 actor 隔离 |

外加两条产品约束：

| # | 约束 | 影响 |
|---|---|---|
| C5 | **Intel 兼容**（`HANDOFF` 记录做过 `x86_64` 交叉编译验证） | MLX **完全不支持 Intel**；llama.cpp XCFramework 是否含 x86_64 slice **需实测**（见 §8） |
| C6 | **MAS 上架计划**（沙盒） | 运行时下载模型权重可行但体积/审核有摩擦；**系统自带模型（Foundation Models）在沙盒里最省事** |

> **C1 + C2 是决定性的**：它们把"最省事的两个方案"（Foundation Models、AnyLanguageModel）分别推到了"只能做增强"和"等升级"。

---

## 2. 候选全景（2026-10 实况）

| 方案 | 形态 | 最低 OS | 工具链 | 模型来源 | Intel | 结论 |
|---|---|---|---|---|---|---|
| **Foundation Models** | 系统框架，Swift 原生 | **macOS 26** | Xcode 26 | **系统自带 3B** | ❌（需 Apple Silicon + Apple Intelligence 开启） | **首选（有条件）** |
| **Core AI** | 系统框架，替代 Core ML | **macOS 27** | Xcode 27 | 自带 BYO 模型，AOT 编译 | ❌ Apple Silicon | 未来 |
| **MLX / mlx-swift-lm** | Swift 包，GPU | macOS 14 | Swift 6 | 自己下 safetensors/量化 | ❌ | 仅 M 系，8GB 偏重 |
| **llama.cpp / llama.swift** | Swift 包 + XCFramework | **macOS 13** | **Swift 6.0** | 自己下 GGUF | 待验 | **今天就能跑** |
| **AnyLanguageModel** | 统一协议层（HF 维护） | macOS 14 | **Swift 6.3 / Xcode 26.4** | 取决于后端 | 取决于后端 | **升级后首选** |
| Ollama | 外部 App + HTTP | — | — | 用户自己拉 | ✅ | **已经支持**（`AIVendor.ollama`） |

补充两个常被忽略、但对你这个场景更重要的系统能力：

| 能力 | 框架 | 最低 OS | 用途 |
|---|---|---|---|
| `NLContextualEmbedding` | NaturalLanguage | **macOS 14** | 语义检索（经验/记忆匹配），**中文有独立模型**，资产按需下载 |
| `NLEmbedding` | NaturalLanguage | macOS 10.15 | 静态词/句向量；Apple 官方推荐用于**语义相似度** |

---

## 3. 逐个分析

### 3.1 Foundation Models（系统自带 3B）—— 最省事，但有门槛

**是什么**：WWDC25 开放的系统级框架，直接调用驱动 Apple Intelligence 的**端侧 ~3B 模型**。Swift 原生 API（`LanguageModelSession`、`@Generable`、`Tool` 协议）。WWDC26 又加了：**`LanguageModel` 协议**（第三方 provider 可接入）、**Dynamic Profiles**（会话中换模型/工具/指令）、**Evaluations 框架**。

**对 Moppet 的意义**：

- ✅ **零下载、零包体增长**：模型在系统里，不占你的 .app 体积，也不占你的沙盒容器。
- ✅ **零 App 内存**：推理跑在系统服务里，8 GB 机器上这是决定性优势。
- ✅ **性能最好**：Apple 针对自家 ANE/GPU 调过，比你自己跑 3B 快得多。
- ✅ **工具调用是原生的**：`Tool` 协议 + `@Generable` 参数，比解析 GGUF 模型的输出稳得多。
- ✅ **沙盒/审核最友好**（C6）。
- ❌ **要 macOS 26**：你的部署目标是 14。只能 `if #available(macOS 26, *)` 做增强，不能当唯一路径。
- ❌ **需要 Apple Intelligence 已开启且设备支持**：Intel Mac 永远没有；部分用户会关掉。
- ❌ 3B 是通用助手模型，**不是为"磁盘清理 + 工具编排"训练的**，工具选择质量需要实测（§8）。

**结论**：**做"本地主脑"的最佳候选，但只能作为可选增强**，必须有云端兜底。这在架构上完全可行——`BrainModel` 已经是协议，加一个 `FoundationModelsBrainModel` 就行。

### 3.2 Core AI —— 未来，现在不用考虑

WWDC26 新框架，**内置系统、专为 Apple Silicon**、Swift API、**AOT 编译**（加载快）、细粒度内存控制、零拷贝、有状态执行。定位是"把你自己的模型带上端侧"的最佳方式，官方口径是替代 Core ML。

**最低 macOS 27**。你现在连 26 都还在适配阶段，**这条是 2027 年的事**，记一笔即可。

### 3.3 MLX / mlx-swift-lm —— Apple Silicon 上最快的自托管方案

**是什么**：Apple 的数组框架 + 官方 LLM 包。WWDC26 加了 Metal 4 与 **GPU Neural Accelerators**，训练可跨多台 Mac（RDMA over Thunderbolt）。

- ✅ M 系上**比 llama.cpp 通常更快**（尤其 prefill），生态最活跃，量化模型现成。
- ❌ **Intel 完全没有**（C5 直接冲突）。
- ❌ **8 GB 上偏重**：MLX 的 KV cache 与权重常驻行为比 GGUF 激进，容易触发内存压力。
- ❌ 与 `swift-ai-sdk` 是两套世界观，需要自己写 `BrainModel` 适配。

**结论**：如果你的用户群确定是 M 系 + ≥16 GB，MLX 是性能最优解。**但 8 GB M1 不是它的舒适区。**

### 3.4 llama.cpp / llama.swift —— 今天唯一能落地的纯本地方案

**是什么**：`mattt/llama.swift` 把 llama.cpp 的**预编译 XCFramework** 包成 SwiftPM 包，**直接 re-export C++ API**。

**要求（已核实）**：**Swift 6.0+ / macOS 13.0+**，MIT，版本形如 `.upToNextMajor(from: "2.10549.0")`（版本号跟 llama.cpp release 走）。

- ✅ **你的工具链今天就满足**（C2 不再是问题）。
- ✅ **不用 CMake / 不用编 C++**：XCFramework 是二进制，`swift build` 快。
- ✅ GGUF 生态：任何量化模型（Qwen3 / Llama-3.2 / Gemma-3 / Phi）直接跑。
- ✅ 内存可控：`n_ctx` / `n_batch` 自己定，8 GB 上能压到很省。
- ❌ **它是引擎，不是 SDK**：README 示例就是手写 `llama_tokenize → llama_decode → 采样 → detokenize` 的循环。
- ❌ **chat template 要自己套**：好消息是 llama.cpp 提供 `llama_chat_apply_template`，能从 GGUF 元数据里读模板；坏消息是**工具调用格式因模型而异**（Qwen 用 `<tool_call>{...}</tool_call>`，Llama-3 又是另一套），解析器要自己写，这是**整个集成里最脆的地方**。
- ❌ **Intel slice 待验**（§8）：llama.cpp 官方 XCFramework 可能只有 arm64 macOS。

**集成量估算**：`BrainModel` 适配器 **约 400–600 行**（模板应用 + 采样 + 流式 + 工具调用解析 + 生命周期）。不是"加个依赖就完事"，但完全可控。

### 3.5 AnyLanguageModel —— 架构最优，但现在装不上

**是什么**（已核实，HF 组织下维护，Apache-2）：**Foundation Models 的 drop-in 替代**，`import FoundationModels` 改成 `import AnyLanguageModel` 即可。一个 `LanguageModel` 协议统一：

- 端侧：Foundation Models（26+）、Private Cloud Compute（27+）、Core AI（27+）、Core ML、MLX、**llama.cpp/GGUF**
- 远程：Ollama、OpenAI（Chat/Responses）、OpenRouter、Anthropic、Gemini

**关键能力**：

- ✅ **工具调用全后端支持**（llama.cpp 取决于模型的 chat format）
- ✅ **`ToolExecutionDelegate`**：`didGenerateToolCalls` / `toolCallDecision`（返回 `.execute` / `.stop` / `.provideOutput`）——**这正好是 Moppet 需要的**，因为 Brain 自己派发工具，不需要框架代跑
- ✅ `@Generable` 结构化输出——决策层的意图分类可以直接写成一个 enum
- ✅ Swift 6.1 **Package Traits**：`CoreML` / `MLX` / `Llama` 按需引入，不用的后端不进二进制
- ✅ **macOS 14.0+**（包本身）

**唯一的墙**：**Swift 6.3+ / Xcode 26.4+**。你是 6.2.3 / 26.2。

**结论**：**升级 Xcode 之后，这是唯一正确的选择**——它把你今天纠结的所有后端选择变成一个配置项，而且工具调用那层它替你处理了。

### 3.6 系统 embedding —— 实测：**不可用**（这条推翻了我上一轮的建议）

上一轮 §5.11.4 我建议"用本地 embedding 做检索"。今天在**本机实测**了系统自带的两种，结论是**都不能用**：

**实测 1：`NLEmbedding.sentenceEmbedding(for:)`**

```
en:      可用，dim=512
zh-Hans: 可用，dim=640     ← 中文确实有，不是 nil
zh-Hant: nil
```

可用，但**区分度是坏的**。查询 = `"只清一下浏览器缓存，别动 docker"`：

| 候选 cue | 余弦 | 判定 |
|---|---|---|
| 帮我写一首关于春天的诗 | **0.9626** | 域外·无关 ❌ |
| 用户限定清理范围时如何传参 | 0.9607 | 域内·中相关 |
| 清理前应该先扫描并展示结果 | 0.9561 | 域内·弱相关 |
| **用户要求不要清理 docker** | **0.9510** | **域内·高相关** ❌ |
| 解释一下 Swift 的 actor 隔离 | 0.9429 | 域外·无关 |
| 今天天气怎么样 | 0.9174 | 域外·无关 |

**"写一首春天的诗"排在"不要清理 docker"前面。** 全部分数挤在 0.90–0.97，排序基本是噪声。另外它**对长度敏感**：同一含义，句子越长分数越高（`"请不要清理 docker 相关的任何数据，包括镜像和卷"` 得 0.9640，而 `"别动 docker"` 只有 0.9137）——典型的静态向量向语料质心漂移。

> 结论：**静态句向量 + 平均池化，在短中文短语上不可用。** 我原先建议的 `cos < 0.62 丢弃` 阈值在这个分布下毫无意义。

**实测 2：`NLContextualEmbedding(language: .simplifiedChinese)`**

```
model=12784592-…  dim=512  maxLen=256  assets=false   ← 资产不在本机
requestAssets → 100 秒内回调未返回，放弃
```

中文走的是独立的 CJK 模型（支持 ja/ko/zh-Hans/zh-Hant），但**资产需要下载，本机没有，且在我这次测试里没有拿到**。即使拿到，BERT 类模型**平均池化做句子相似度**本身也是弱方案（缺训练过的 pooling head）。

> 结论：**不能依赖**。至少要当作"可能拿不到"来处理。

#### 那检索该怎么办？—— 别做模糊匹配，把 cue 写死

既然 cue 是**我们自己写的**（不是用户产生的），就没必要用一个模型去猜它的语义。**给每条 cue 显式挂别名**：

```markdown
- **cue**: 用户提到清理范围限定时
- **aliases**: 只清, 别动, 不要碰, 范围, 只清理, 别删, 排除, 除了, 仅
```

匹配用**别名命中 + 字符 n-gram 重合**，确定性、可单测、0 依赖、0 延迟。经验库 ≤60 条、每条 ≤8 个别名，这个规模下**比任何 embedding 都可靠**——因为它是"构造即检索"（Harness² 的原话），而不是"猜语义"。

只有一种情况才需要真 embedding：**经验库 > 200 条，且别名维护不过来**。那时再上 GGUF embedding 模型（`bge-small-zh-v1.5` Q8 ≈ 95 MB，llama.cpp 可直接跑），而不是用系统那个。

---

## 4. 性能：M1 / 8 GB 上到底多快

> ⚠️ **这些是推算，不是实测**——本机没装 Ollama，我无法在沙箱里跑基准。推算依据：一个已知锚点（**Qwen3-8B Q4 在 M4/16GB 上 19.3 tok/s**）+ 内存带宽比例（M1 ≈ 68 GB/s，M4 ≈ 120 GB/s）+ 生成阶段是**内存带宽受限**（tok/s ∝ 1/权重大小）。

| 模型 | 量化 | 权重体积 | M1 预估 tok/s | 8 token 输出耗时 | 8 GB 可用性 |
|---|---|---|---|---|---|
| Qwen3-0.6B | Q4_K_M | ~0.4 GB | **70–110** | ~0.07–0.11 s | ✅ 舒适 |
| Llama-3.2-1B | Q4_K_M | ~0.8 GB | 45–65 | ~0.12–0.18 s | ✅ 可以 |
| Qwen3-1.7B | Q4_K_M | ~1.1 GB | **30–45** | ~0.18–0.27 s | ⚠️ 紧张 |
| Llama-3.2-3B | Q4_K_M | ~2.0 GB | 15–22 | ~0.4–0.5 s | ❌ 不建议 |
| Foundation Models | 系统 3B | 系统托管 | 系统优化（≈3B 的 1.5–2×） | ~0.1–0.2 s | ✅ **不占 App 内存** |

**读法**：

- **决策层**（输出 ≤8 token）：0.6B 完全够，**~100 ms**，异步跑不阻塞 UI。1.7B 也能忍。
- **主脑**（多轮工具调用，输出几百 token）：1.7B 生成 300 token ≈ **7–10 s**，且质量不够。**不可行。**
- **冷启动**：从 SSD 加载 0.4 GB GGUF ≈ **0.3–0.8 s**。这是 8 GB 机器上的真实痛点——**不能常驻就得每次付这个钱**，常驻又挤内存。**这一条几乎单独判了"自托管小模型"的死刑**，也是 Foundation Models 的最大优势（系统常驻）。

**内存账（8 GB）**：

```
macOS 系统          ~3.0 GB
Moppet（SceneKit 3D + 引擎）  ~0.8–1.5 GB
浏览器等用户 App      ~1.5 GB
────────────────────────────
留给模型             ~1.5–2.5 GB（且不能长期占满，否则换页）
```

→ **常驻上限 ≈ 0.6 GB**，即 **0.6B Q4**。1.7B 只能"用完就卸"，但卸载后每次冷启动 0.5 s+。

---

## 5. 关键判断：本地小模型该干什么，不该干什么

这是本文档最重要的一节。

| 用途 | 0.6B | 1.7B | 3B | 结论 |
|---|---|---|---|---|
| 意图分类（9 选 1） | ✅ | ✅ | ✅ | **规则优先，模型兜底** |
| 语义重复提问检测 | ✅ | ✅ | ✅ | 可用 |
| 承诺未兑现检测 | ✅ | ✅ | ✅ | 可用 |
| 经验检索 | — | — | — | **用 cue 别名匹配**（实测系统 embedding 不可用，§3.6） |
| **主脑 + 工具编排** | ❌ | ❌ | ⚠️ | **绝对不要** |

**为什么"主脑"不能本地化**（这一点必须有共识，否则会做出一个明显变笨的宠物）：

1. **工具调用是硬指标**。Moppet 有 23 个工具 + JSON Schema + 沙箱/审批矩阵。1.7B 级模型在多工具、长 schema、中英混排下的**调用准确率会崩**——不是"稍差"，是"经常调错工具或漏参数"。
2. **Brain 的循环是 10 轮**（`maxTurnsPerSubmit`）。单轮质量下降会在 10 轮里**复合放大**。
3. **中文 + 文件路径 + 技术术语**是小模型最弱的地方，而这恰好是桌宠的日常。
4. 一次失败的工具调用可能**真的删错东西**——这个代价不能用"省几美分"来换。

> 所以正确的分工是：**主脑留在云端（或 Foundation Models 可用时的系统 3B），本地小模型只做"高频、低风险、输出极短"的决策。** 这和上一轮 §5.11 的风险不对称原则完全一致——**越是会写进持久状态的决策，越不能交给小模型**。

---

## 6. 推荐方案（按投入排序）

### 路线 A（推荐，0 新依赖）：先把系统能力用满

1. **决策层**：维持规则（0 token），把 §5.11 的 D1/D5/D6 长尾留给"规则 + 阈值"。
2. **检索层**：**给 cue 显式挂 `aliases:`**（§3.6），别名命中 + n-gram 重合。**不要用系统 embedding**（实测不可用）。若经验库涨到 200+ 条再考虑 GGUF embedding 模型。
3. **主脑**：`if #available(macOS 26, *)` 时，加一个 `FoundationModelsBrainModel` 作为**本地优先、云端兜底**；否则维持现状。
4. **Ollama**：保留现有 `AIVendor.ollama`（已支持，零成本），给愿意装的高端用户。

**代价**：几乎为零。**收益**：离线检索（别名方案）、隐私、macOS 26 用户获得真正的本地主脑。**不改 `Package.swift`。**

### 路线 B（升级 Xcode 后，架构最优）：接 `AnyLanguageModel`

1. 升级到 **Xcode 26.4+ / Swift 6.3+**。
2. `Package.swift` 的 `swift-tools-version` 提到 **6.1+**（traits 需要），加：
   ```swift
   .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "1.1.1",
            traits: ["Llama"])   // 先只要 llama.cpp；MLX 视用户群再加
   ```
3. 写一个 `AnyLanguageModelBrainModel: BrainModel`，用 `ToolExecutionDelegate.toolCallDecision` 返回 `.provideOutput(...)`，**把工具派发继续交给 `BrainTools.dispatch`**（保持现有安全层不变）。
4. 后端按可用性自动选：Foundation Models（26+）→ llama.cpp（GGUF）→ 云端。

**代价**：一次工具链升级 + 一个适配器（~200 行，比路线 C 少一半，因为模板和工具解析它替你做了）。**收益**：一个协议吃下所有后端，未来换模型不改代码。

### 路线 C（现在就要纯本地）：`llama.swift` 手写适配

1. 加依赖：`.package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.10549.0"))`
2. 写 `LlamaBrainModel: BrainModel`：
   - `llama_chat_apply_template` 套模板（从 GGUF 元数据读）
   - 采样循环 → `AsyncThrowingStream<BrainStreamEvent>`
   - 工具调用解析（**按模型家族分支**，只支持你实测过的那 1–2 个模型，不要做通用解析器）
3. 模型：**Qwen3-0.6B Q4**（决策层）/ **Qwen3-1.7B Q4**（仅在 ≥16 GB 机器上）
4. 生命周期：`load` 懒加载 + 空闲 5 分钟 `llama_model_free`。

**代价**：400–600 行 + 工具调用解析的长期维护。**收益**：完全离线、完全可控、Intel 也能跑（待验 slice）。

---

## 7. 不要做的事

| 不做 | 原因 |
|---|---|
| **用本地 1.7B 替代主脑** | 工具调用会崩，10 轮循环会复合放大，可能真的删错文件（§5） |
| **为了"省 token"引入本地模型** | 上一轮已算清：优化后成长功能只要 $0.05–2/月，决策层走规则是 0。**省的不是钱** |
| **把模型权重打进 .app** | 0.4 GB 起步，MAS 审核 + 更新包体积都难受；改为首次使用时下载 |
| **自己写通用工具调用解析器** | 每个模型家族一套格式。**只支持实测过的模型**，其余降级到云端 |
| **在 8 GB 机器上常驻 1.7B** | 会触发换页，宠物动画会卡——这是桌宠最致命的体验问题 |
| **用系统 embedding 做检索** | **已实测：`NLEmbedding` 中文句向量区分度不可用**（§3.6），`NLContextualEmbedding` 中文资产拿不到。用 cue 别名 |

---

## 8. 验证状态

### 已实测（本机，2026-10-28）

| # | 结论 | 方法 |
|---|---|---|
| V1 | `NLEmbedding.sentenceEmbedding` 中文**可用**（dim=640），`zh-Hant` 为 nil | 直接调用 |
| V2 | 但**区分度不可用**：域外句排在域内句之前，全部分数挤在 0.90–0.97；且对长度敏感 | 6 组对照 + 长度变体 |
| V3 | `NLContextualEmbedding(.simplifiedChinese)` 模型存在（dim=512，CJK 独立模型），但**资产不在本机**，`requestAssets` 100 s 未回调 | 直接调用 |
| V4 | 工具链 **Swift 6.2.3 / Xcode 26.2**，机器 **M1 / 8 GB** | `swift --version` / `system_profiler` |

### 仍待验证

1. **llama.cpp XCFramework 是否含 macOS x86_64 slice** — 决定 Intel 用户能否用路线 C。验证：`lipo -info` 解包 XCFramework。
2. **Foundation Models 在 M1/8 GB 上是否可用**（Apple Intelligence 最低 8 GB，理论上可以），以及**它对 23 个工具的实际选择准确率** — 这决定路线 A 能否真的把主脑本地化。这是**最该先验的一条**。
3. **Qwen3-0.6B 在 M1 上的真实 tok/s** — 我的 70–110 是推算。装个 Ollama 或编译 llama.cpp 跑一次就有真数。
4. **`AnyLanguageModel` 0.4 → 1.1.1 的 API 稳定性** — 快速迭代（0.10 加 LiteRT、0.11 又删掉），锁版本要谨慎。

**建议下一步**：先验 #2（Foundation Models 能不能用、工具调用准不准）。如果它能用，路线 A 直接成立，路线 C 就不用做了。

---

## 9. 一句话回答

**有 Swift 方案，但"性能还可以"的真正瓶颈不是 tok/s，是 8 GB 内存和 0.5 s 冷启动。** 所以：**决策层别上 LLM（规则 + cue 别名就够，系统 embedding 实测不可用），主脑用 Foundation Models（macOS 26+，系统托管、零内存）或云端，自己 ship GGUF 只在"必须离线"时才值得。** 等 Xcode 升到 26.4，`AnyLanguageModel` 会让这一切变成一个配置项。
