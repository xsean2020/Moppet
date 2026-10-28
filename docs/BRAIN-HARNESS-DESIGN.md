# Moppet Brain × Harness² · 让宠物持续变聪明的设计文档

> **状态**：设计提案，未开工。写于 2026-10-28，对应代码状态 v15.38（build 0/0、smoke 105、brain-smoke 51 全绿）。
> **对象**：`Sources/Moppet/Brain/`（4176 行）+ `harness2/`（Python 7731 行，只读参考，不引入依赖）。
> **本文档只回答一件事**：把 Harness² 的**方法论**（不是它的代码）移植进 Brain，让宠物在用户真实使用中**越用越懂这个用户**，同时不把用户机器变成试验场。

---

## 0. 结论摘要（30 秒版）

1. **Harness² 最值钱的不是"多智能体"，而是三个反自欺的工程决定**：① 把 harness 从代码里拿出来变成**可校验的数据树**；② **没有真值时靠"对比"而不是靠打分**；③ **KEEP_BASE 是一个合法答案**（证据不足就不改）。这三条正好命中 Brain 当前的病。

2. **Brain 当前的天花板不是能力不够，是"不会学习"**。工具面已经对齐 codex（23 个工具、沙箱、MCP、审批、exec 会话），但**每一轮对话都从零开始**：系统提示词是硬编码的 Swift 字符串字面量（`BrainInstructions.systemPrompt`），没有技能、没有持久记忆、没有经验库。rollout JSONL 只写不读——它是**只进不出的档案**，不是学习材料。

3. **一个可验证的证据**：该提示词的 Operating rules 里已经出现**两个编号 7**（`BrainRollout.swift:261` 与 `:263`），第 4 条规则同时把"删除永远先问"写死在字符串里——这段文本已经开始腐化，而没人发现，因为它埋在 Swift 多行字符串里，没有校验、没有 diff、没有版本。**这就是"必须外置"的最小证明。**

4. **核心架构决定：把"演化"从请求路径上挪走。** Harness² 每个任务跑 `4k` 次 rollout + `3k` 次改进会话，桌宠不可能这么做。本设计把它拆成**三条不同时间尺度的闭环**：会话内只做**检索**（零额外模型调用）、会话后做**反思**（1 次调用）、空闲时做**演化**（离线、可抢占、默认关闭）。

5. **核心技术创新：Shadow Replay Probe（影子回放探针）。** 没有 grader 怎么判断新 harness 更好？答案是**只在"已知是坏"的时刻上对比**：把历史 rollout 的某个决策点截断，用候选 harness 重放一次，只看它**是否重犯记录在案的错误**。不执行任何工具、不产生副作用、不需要真值、不需要打扰用户。这是本设计里唯一真正原创的部分，也是整套闭环能成立的前提。

6. **安全边界（最重要的一条）**：宠物**可以改自己怎么说话、怎么记事、怎么排步骤，永远不能改自己被允许做什么**。`SafetyGuard` / `BrainSandbox` / `ToolRegistry` 的破坏性门控**不进可编辑面**。Harness² 允许模型写 Python 脚本并执行——**这一条我们明确不抄**（见 §3.3）。

7. **投入产出**：P0（外置提示词）+ P1（技能 + 记忆）约 **3–4 天**，风险接近零，能拿到 80% 的"变聪明"体感（记住偏好、少走弯路）。P2/P3（反思 + 自演化）是**有趣但容易失望**的部分，建议先跑通 P0/P1 再决定。

8. **Token 经济学（v2 修订，见 §6.4）**：初版设计"每个会话结束都反思、喂全文轨迹"实测约 **38 万 tokens/天**，是预算的 2.5 倍，**上线第二天就超**。三处纯工程优化（跳过好会话 / 压缩输入 / 合并调用）可降到 **2.3 万/天（-94%）**，**不需要引入任何新模型**。而"决策"如果交给主模型，反而要吃掉优化后总量的 **32%**——所以决策必须走规则，不是走模型。**结论：为了省 token 而引入决策模型，是错的解法**；小模型的真正价值在 §5.11。

**待决策问题在 §9.4**（演化默认开关、预算、是否允许宠物自主新增技能、小模型是否启用）。

---

## 1. 先读懂 Harness²：它到底先进在哪

### 1.1 一句话拆解

> 一个 harness 是"模型外面的那套系统"（提示词、工具、记忆、技能、编排）。**Harnessing 就是优化这套系统**——在**不动模型权重**的前提下，让同一个模型表现更好。

它的两层递归（`harness2/README.md`）：

| 层 | 做什么 | 周期 | 产物 |
|---|---|---|---|
| **任务级递归**（task-level） | Propose–Probe–Compose：提议改动 → 在同一任务上试探效果 → 用**行为对比**合成新 harness | 每个任务一次 | 一个针对该任务的 harness |
| **harnessing 级递归**（harnessing-level） | 反思器把"被采纳的 harness + 有证据支撑的经验"写进持久**改进 harness** | 跨任务 | 经验库，指导下一次改进 |

关键点：**权重固定**。所有进步都来自上下文构造方式的改变。这对桌宠极其重要——用户不会为了宠物变聪明去训练模型。

### 1.2 八个组件：按"成本 / 射程"分类

`prompts.py:_SURFACE_CODEX` 里那张表是整份设计里最实用的一页，我原样翻译过来：

| 组件 | 是什么 | 何时进上下文 | 成本 |
|---|---|---|---|
| `systemprompt.md` | 角色与流程 | **常驻** | 每一轮都付费 |
| `guardrails.md` | 长期规则 | **常驻** | 同上 |
| `LongTermMEMORY.md` | 持久领域事实 | **常驻** | 同上 |
| `tool_descriptions/tool_guidance.md` | 工具怎么用 | **常驻** | 同上 |
| `skills/<name>/SKILL.md` | 可复用工作流 | **按需**，被调用时才读 | 近零 |
| `sub_agents/<name>/AGENT.md` | 委派子 agent | 独立上下文 | 中 |
| `scripts/<name>.py` | 确定性助手 | 按需 bash 执行 | 近零 |
| `plugin/<name>.ts` | 插件/钩子 | **常驻注册，在工具循环内生效** | 零提示词成本 |

作者反复强调的一条（`prompts.py:129`）：

> **ALWAYS-ON PROSE IS THE EXPENSIVE OPTION.** 每个字每一轮都在抢 agent 自己的输出预算——而这类工作最贵的失败，就是"推理到预算耗尽、什么都没产出"。**加常驻文本只会让这件事更容易发生。**

并且给了**优先级**：技能 > 脚本 > 子 agent > 插件 > 常驻文本（最后，且"要加就得先砍掉别的来付账"）。

> **这条对我们直接可用**：Brain 的系统提示词是纯常驻文本，且正在变长。它是最贵的那种形式。

### 1.3 三层"反自欺"纪律（我认为这才是精髓）

Harness² 大量篇幅不是在讲算法，而是在**防止改进过程自己骗自己**。摘三条最硬的：

**(a) 没有真值就不许假装有。**
`prompts.py:41` 的 `ANSWER_FREE` 块，直接写进每一次 proposer 的 prompt：

> 你的上下文里**没有**评分标准、答案、参考解、分数，任何东西都不该被当成评分标准。不要去找，不要去猜"评分器想要什么"，永远不要在任何产物里写下"评分器期望……"这类句子。

**(b) 采纳 ≠ 有效。** `prompts.py:1146`：

> **Adoption alone never establishes that an edit helped or will transfer.**（被选中这件事本身，永远不能证明某个改动起了作用或能迁移。）
> 如果一个候选同时改了好几个组件、而没有执行能隔离出其中某一个，就标 `confounded`——**宁可标"混杂"，也不要编造归因**。一行诚实的 `confounded` 是有用的记录；一个编造的归因会毒化整个库。

**(c) 单次失败是噪声，重复失败才是信号。** `prompts.py:919`：

> k 个 base rollout 是**同一个分布**的抽样，要当成一个集合读，不是 k 个独立故事。在 base 集合里**重复**出现的失败，是 base harness 的真实属性，也是你能动手的最强证据；**1/k 里出现一次的缺陷是噪声**，针对它改就是过拟合单次采样。

**(d) 加上一条**：任何关联到某改动的 rollout **没产出任何东西**，该改动默认视为 **UNSAFE**，除非其余证据压倒性——"帮忙一个、冒险全空"是坏改动。

这四条，比任何"self-improving agent"的漂亮话都值钱。**它们同时也是给桌宠用的——因为桌宠没有 grader，比 benchmark 更依赖"不骗自己"。**

### 1.4 没有真值怎么选：盲选 + 文件化证据

`selection.py` 的做法值得完整理解，因为桌宠要照抄它的**结构**：

1. 候选产物**匿名化**：`assign_ids` 用 `sha1(task|k|mode)` 做种子洗牌，A/B/C 顺序稳定但**与来源无关**。
2. 每个候选写成一个**完整不截断**的 md 文件（`_write_candidates`，文件头明确写 "COMPLETE -- nothing trimmed"）。
3. 证据是**磁盘上的文件**，prompt 只是一句指针（`context.mission`）："它在磁盘上，去读它，不要只看这条消息就回答"。
4. 选择器**只看产物，看不到 harness、看不到轨迹**，明确告诉它"从原始 harness 出来的产物被选中是完全合法且预期的结果"。
5. 输出强制格式：`<why>` + ```` ```choice ````。

> 对我们的启示不是"照抄盲选"，而是：**证据要文件化、要完整、prompt 只做指针**。Brain 的 rollout JSONL 天然就是这种证据——但今天没有任何代码去**读**它。

### 1.5 可迁移性矩阵

这张表是本文档的取舍依据。**保留**=方法论直接可用；**改造**=思想可用但形态必须变；**放弃**=对桌宠是负资产。

| Harness² 的做法 | 判定 | 理由 / 改造方式 |
|---|---|---|
| 八组件树 + 路径白名单（`tree.is_allowed`） | **保留** | Brain 的提示词应当成为可 diff、可回滚、可校验的数据 |
| 校验即闸门，错误原文回喂重试（`_accept_tree`） | **保留** | 一次重试 + 可操作的错误 prose，比"静默丢弃"好得多 |
| always-on 字符上限（`always_on_max`） | **保留** | 直接对治"提示词无限膨胀" |
| autotrigger：技能没被常驻文本点名就是死重 | **保留** | 极好的一条硬规则，见 §5.4 |
| `cue/lesson/evidence/confidence` 经验库 | **保留** | 这是"跨任务变聪明"的载体 |
| 领域目录即检索（retrieval by construction） | **改造** | 桌宠的"领域"= **意图类**，用规则分类（§5.6） |
| INV / DOM 二分（怎么干 vs 懂什么） | **保留** | 直接映射成"全局护栏 / 领域经验"，并作为**风险分级**依据 |
| 盲选 + 匿名化 | **改造** | 桌宠无产物可盲选 → 改为**已知坏时刻的对比**（§5.9） |
| Propose–Probe–Compose（k 路并行） | **改造** | k=1 顺序化，且**移出请求路径**（§4.1） |
| 内容指纹缓存 + 账本（`ledger` / `runmark`） | **保留** | 防止重复烧钱，也防止"改了等于没改" |
| 多样性指标（line-Jaccard） | **保留** | 检测经验库塌缩成同一句话 |
| 答案泄漏 tripwire（`assert_no_grader_verdicts`） | **改造** | 改为"经验里不许出现本任务的具体事实"（反过拟合闸） |
| **模型写 Python 脚本并执行** | **放弃** | 在用户真机上等于提权通道（§3.3） |
| 子 agent 委派 | **放弃** | 桌宠无并行子任务场景；Harness² 自己也说只适合"大输入小答案" |
| benchmark / judge / adapter / Docker / Vertex | **放弃** | 与桌宠无关 |

---

## 2. 现状诊断：Brain 的天花板在哪

### 2.1 三个硬事实

**事实一：提示词是代码，不是数据。**

`BrainRollout.swift:226-268` 的 `systemPrompt(cwd:sandboxMode:approvalPolicy:networkAccess:)` 返回一个多行字符串字面量。后果：

- 用户改不了（除了 `persona.md` 那一段）；
- 改它要重新编译、发版；
- 没有 diff、没有版本、没有回滚；
- **没有校验**——于是出现了两个编号 `7`（`:261` 与 `:263`），以及第 4 条规则把"删除永远先问"这个**安全策略**写死在自然语言里（真正的强制在 `BrainSandbox.involvesDeletion`，但文本和行为已经开始各说各话）。

**事实二：会话是只写不读的。**

`BrainRollout` 把 `session_meta` / `turn_context` / `response_item` / `compacted` 落成 JSONL。`listSessions` / `titleForSession` 只读**文件头**（为了列表性能，这是对的）。**没有任何代码读取正文去学习**。所以每次对话，宠物对"上次这个用户是怎么纠正我的"一无所知。

**事实三：失败信号全都在，但全都被丢掉。**

`BrainAgent` 已经知道这些事，但只是丢掉：

| 信号 | 代码位置 | 现在的处理 |
|---|---|---|
| 工具报错 | `runLoop`：`output.hasPrefix("error:")` → `.toolFinished(isError:)` | 只进 UI chip |
| 用户拒绝审批 | `ApprovalCenter.respond(false)` | 只让工具失败 |
| 用户取消 | `cancel()` → `lastError = "cancelled"` | 只改状态 |
| 撞轮次上限 | `lastError = "reached max turns"` | 只改状态 |
| 说了要做但没做 | 无 | 根本没检测 |
| 用户重复提问 | 无 | 根本没检测 |

**这六个信号合起来，就是桌宠版的"代理奖励"。** 不需要 grader，不需要用户打分——用户的下一个动作就是评分。

### 2.2 为什么现在不会变聪明

一句话：**Brain 是一个"能力完整但无状态"的 agent**。它的全部能力都在代码里，全部经验都在上下文窗口里，窗口一关就归零。

`HANDOFF.md §8.4` 已经诚实地写了"Brain 与 codex 的差距"，并列了"明确不做"的清单。但那份清单回答的是**能力面**问题。本文档回答的是另一个问题：**同一个模型，用三个月之后，应该比第一天更懂这个用户。** 这件事今天的架构里没有任何机制承载。

### 2.3 你已经有的三样资产

不用从零开始——这三样东西是 Harness² 整套方法论的**必要输入**，而 Moppet 已经全有了：

1. **完整轨迹**：rollout JSONL 逐 item 落盘，含工具调用参数与输出。这就是 `context/rollouts/`。
2. **工具契约**：`BrainTools.Spec` 有 name/description/JSONSchema/risk，是结构化的、可生成的。这就是 `tool_guidance` 的数据源。
3. **安全裁决点唯一**：`SafetyGuard` + 沙箱 + 审批是**单一收口**。这意味着"可编辑面"可以画得很干净——**凡是绕过这三者的，一律不在可编辑面上**。

---

## 3. 设计目标与边界

### 3.1 北极星：什么叫"更聪明"

不用"分数上升"这种假指标。用三条用户能直接感知、且**可观测**的定义：

| 维度 | 用户感受 | 可观测指标 | 承载组件 |
|---|---|---|---|
| **记得住** | 不用重复交代"我只清浏览器"、"别动 Docker" | 同一偏好被重复交代的次数 ↓ | 记忆（§5.5） |
| **少走弯路** | 同样的活儿第二次更快、步骤更短 | 中位工具轮次 ↓、首轮成功率 ↑ | 技能（§5.4） |
| **不犯同样的错** | 同一个坑不掉第二次 | 同类工具错误复发率 ↓ | 经验库（§5.6） |

外加一条**反向指标**（防止"越改越飘"）：

| **稳定性** | 它别今天一个性格明天一个性格 | harness 版本变更频率、回滚次数 | 晋升门（§5.10） |

> **验收口径**：不是"harness 改了多少次"，而是"上面四个指标在 30 天滚动窗口里是否单调向好，且版本没有频繁抖动"。

### 3.2 三层时间尺度（核心架构决定）

Harness² 在一个任务内跑 `4k` rollout + `3k` 改进会话。桌宠**绝对不能**在用户等待时做这件事。所以按"能不能忍受延迟"切成三层：

| 层 | 时机 | 延迟预算 | 额外模型调用 | 干什么 |
|---|---|---|---|---|
| **L1 检索**（在线） | 每轮 submit 前 | **0 ms**（纯本地） | **0** | 按意图类取经验、按 cue 取记忆，拼进 developer message |
| **L2 反思**（会话后） | 回合结束后异步 | 用户不可感知 | 1 次（小上下文） | 判 TurnVerdict、蒸馏经验、写记忆候选 |
| **L3 演化**（空闲） | 空闲且**有预算**时 | 无（可随时抢占） | N 次（离线） | 提议改动 → 影子回放探针 → 晋升/丢弃 |

**硬约束**：L2/L3 **任何一步都必须可被用户的下一次 submit 立即抢占**。宠物绝不能因为"在思考自己的人生"而变慢。实现上：`Evolver` 每步前检查一个 `@Sendable` 的 `UserActivity.isBusy` 标志，`submit()` 第一行就把它置真并 `cancel()` 演化任务。

> **踩坑预警（来自 `HANDOFF.md §6.1`）**：无头模式（`--brain-smoke` / `--brain-exec`）下任何 `MainActor.run` 会永久挂起。L2/L3 的代码路径**必须在 Core 层用直接调用**，`@Observable` 状态更新才回主线程。新代码要能在这四种模式下都不死锁。

### 3.3 明确不做（以及为什么）

| 不做 | 原因 |
|---|---|
| **让宠物改安全层** | `SafetyGuard` / `BrainSandbox` / `ToolRegistry` 的破坏性门控**不在可编辑面**。宠物能改"怎么说、怎么记、怎么排步骤"，不能改"被允许做什么"。**这是本设计的宪法第一条。** |
| **模型生成并执行 Python 脚本** | Harness² 允许，因为它跑在一次性容器里。桌宠跑在用户真机上——这等于给模型一条提权通道。**脚本只能人写**，或由宠物生成后进入"待批准"队列，用户在 Settings 里看过再启用。 |
| **每轮在线跑 propose-probe** | 延迟不可接受。演化只在空闲期。 |
| **子 agent 委派** | 无场景。Harness² 自己也说只适合"大输入小答案"，桌宠的输入输出都不大。 |
| **benchmark / judge / adapter 层** | 无意义。 |
| **给用户看"宠物智商分"** | 假精确。只展示**行为事实**（"这周它少问了你 3 次偏好"）。 |

---

## 4. 总体架构

### 4.1 数据流

```
                    ┌──────────────────────────────────────────┐
   用户一轮对话 ───▶ │ BrainAgent.runLoop                       │
                    │  system  ← PetHarness.compose()  ◀───┐   │
                    │  developer ← AGENTS.md + Retrieval    │   │
                    │  tools   ← BrainTools.allSpecs()      │   │
                    └──────────────┬───────────────────────┘   │
                                   │ 轨迹                       │ L1 检索
                                   ▼                            │ (0 调用)
                    ┌──────────────────────────────┐            │
                    │ rollout JSONL (已有)          │            │
                    └──────────────┬───────────────┘            │
                                   │                            │
                                   ▼                            │
                    ┌──────────────────────────────┐            │
                    │ L2 Reflector（回合后异步）     │            │
                    │  · TurnVerdict 判定           │            │
                    │  · 蒸馏 cue/lesson/evidence   │            │
                    │  · 候选记忆事实                │            │
                    └──────┬───────────────┬───────┘            │
                           │               │                    │
              ┌────────────▼───┐   ┌───────▼─────────┐          │
              │ LessonLibrary  │   │ MemoryBank      │──────────┘
              │ (按意图类分域)  │   │ (facts/<slug>)  │
              └────────┬───────┘   └─────────────────┘
                       │
                       ▼
        ┌──────────────────────────────────┐
        │ L3 Evolver（空闲 + 预算内 + 可抢占）│
        │  Propose → ShadowProbe → Compose │
        └──────────────┬───────────────────┘
                       │ 候选 harness
                       ▼
        ┌──────────────────────────────────┐
        │ PromotionGate（晋升门）            │
        │  屏幕通过 → 影子实跑 → 灰度 → 采纳  │
        └──────────────┬───────────────────┘
                       │
                       ▼
              harness/active/  （版本化，可回滚）
```

### 4.2 与 Harness² 的逐层对应

| Harness² | 本设计 | 差异原因 |
|---|---|---|
| `context/` 证据树 | `~/.moppet/brain/growth/<session>/` 证据树 | 结构照搬，证据源换成 rollout |
| `Proposer`（独立 CLI 会话） | `HarnessEditor`（同一个 BrainModel，独立 system prompt） | 不引入第二个进程 |
| `tree.py` 可编辑面 | `HarnessSurface`（Swift，路径白名单） | 同构 |
| `validate()` | `HarnessValidator`（错误原文回喂） | 同构 |
| `run_parallel` / `run_sequential` | `Evolver`（k=1 顺序） | 成本 |
| `selection.py` 盲选 | `ShadowProber` 已知坏时刻对比 | **无产物可盲选** |
| `library.py` 经验库 | `LessonLibrary`（cue/lesson/evidence/confidence） | 同构，领域改为意图类 |
| `ledger.py` 预算 | `GrowthLedger`（日 token 预算 + 指纹缓存） | 同构 |
| `runmark.py` 指纹 | `HarnessFingerprint`（sha1 of tree） | 同构 |
| `judge` / benchmark | **无** | 用 `TurnVerdict` 代理 |

---

## 5. 详细设计

### 5.1 组件一：`PetHarness` —— 把提示词变成数据

#### 目录树

```
~/.moppet/brain/harness/
├── harness.json              # 版本元数据（见 §7.1）
├── systemprompt.md           # 常驻：角色 + 流程        ← c1
├── guardrails.md             # 常驻：长期规则            ← c2
├── memory/
│   ├── INDEX.md              # 常驻：只放 cue 行（≤1200 字） ← c3 索引
│   └── facts/<slug>.md       # 按需：完整事实             ← c3 正文
├── tool_guidance.md          # 常驻：工具怎么用           ← c4
├── skills/<name>/SKILL.md    # 按需：可复用工作流         ← c5
└── scripts/<name>.sh         # 按需：**仅人写**，模型不可新增 ← c7
```

不设 `sub_agents/`（§3.3）。`hooks`（c8）留到 P4，且**只允许声明式策略**，不允许代码：

```json
{ "hooks": [ { "on": "Stop", "require": "tool_call_if_promise" } ] }
```

#### 常驻预算

| 文件 | 上限（字符） | 理由 |
|---|---|---|
| `systemprompt.md` | 2 400 | 当前约 1 300，留一倍增长空间 |
| `guardrails.md` | 1 800 | 规则要短，长规则没人读 |
| `memory/INDEX.md` | 1 200 | 只放 cue，不放正文 |
| `tool_guidance.md` | 1 200 | 工具描述本身在 schema 里，这里只放"何时用哪个" |
| **合计** | **6 600** | ≈ 1 650 tokens。超过即**校验失败** |

> 为什么是 6600：`prompts.py:129` 的教训——常驻文本每一轮都在抢输出预算。Brain 单轮 `maxOutputTokens: 4096`，常驻吃掉 1.6k 输入是可以接受的；吃到 5k 就会开始出现"推理到没预算"。

#### 组装顺序（`composeSystemPrompt`）

```
persona.md（用户人格，优先级最高，永远在最前）
  → systemprompt.md（角色 + 流程）
  → guardrails.md（规则）
  → tool_guidance.md（工具指引）
  → memory/INDEX.md（记忆索引）
  → 环境块（cwd / sandbox / approval，动态生成，不可编辑）
```

**降级契约（必须实现）**：任何一个文件缺失 → 用**编译进二进制的种子版本**；种子也缺失 → 用当前硬编码提示词。**任何情况下 `systemPrompt` 都不允许返回空串**。这条要进 smoke（§11）。

#### 为什么先做这个

- 零行为变化（种子 == 现有文本）→ 可以单独发版验证；
- 立刻获得：**可 diff / 可回滚 / 可校验 / 用户可见**；
- 是后面所有组件的地基（技能要挂常驻文本、记忆要挂索引、演化要改文件）。

---

### 5.2 组件二：`HarnessValidator` —— 校验即闸门

照抄 `tree.validate` 的哲学：**一次性列出全部问题，用可操作的散文描述，原文回喂重试**。不要"静默修正"，也不要"第一个错误就返回"。

```swift
enum HarnessValidator {
    struct Census { let alwaysOnChars: Int; let skills: Int; let facts: Int }
    /// 失败时抛 HarnessViolation，message 是给"编辑者"看的可操作散文。
    static func validate(_ tree: HarnessTree) throws -> Census
}
```

校验规则（每条都要有断言）：

| # | 规则 | 错误文案要点（会被回喂） |
|---|---|---|
| V1 | 常驻总量 ≤ 上限 | 报实际值与上限，并提示"要加就得先砍" |
| V2 | 每个 `skills/*/SKILL.md` 必须有 `description:` frontmatter | 没有 description 的技能**会被静默丢弃**，所以要在这里拦住 |
| V3 | 技能名必须**逐字**出现在常驻文本里 | 没被点名的技能永远不会被打开，是纯死重（`autotrigger` 可自动修） |
| V4 | 技能引用的 `scripts/x.sh` 必须存在 | 引用了不存在的脚本 = 整个 harness 作废 |
| V5 | 路径不得逃逸（`..` / 绝对路径） | 照抄 `tree.normalize_rel` |
| V6 | `memory/facts/*.md` 必须有 `cue:` 行 | 没有 cue 就检索不到，等于没记 |
| V7 | **经验里不得出现本会话的具体事实** | 反过拟合闸，见 §5.6 |
| V8 | `harness.json` 版本号必须单调 +1 | 防并发写坏 |

**V3 的自动修复（`autotrigger`）**：校验前先跑一遍"补触发行"——对每个未被点名的技能，从它的 `description:` 生成一行 `当 <情境> 时，加载 <name> 技能。` 插进 `systemprompt.md`。若插入会超上限，则**跳过并报告**（不是硬失败）。

> 这个函数是 Harness² 里我最欣赏的一处小设计：它把"技能必须被点名"从**规则**变成了**不变量**——你没法忘记，因为系统会替你补。

---

### 5.3 组件三：`MemoryBank` —— 记忆分三层

这是"记得住"的实现。**关键设计：索引常驻、正文按需。**

```
memory/
├── INDEX.md                 # 常驻。每行一条：- [cue] → facts/<slug>.md
└── facts/
    ├── user-scope-preference.md
    │     cue: 用户指定清理范围时
    │     fact: 用户只用 Safari，Chrome 从不清理；Docker 永远不要动。
    │     source: session 2026-10-20T14:03  (user said "别动 docker")
    └── machine-dev-layout.md
          cue: 涉及本机开发目录时
          fact: 项目在 ~/code，构建产物在 ~/code/*/build；~/tmp 是临时区可清。
          source: session 2026-10-22T09:11
```

三层：

| 层 | 存哪 | 何时读 | 谁写 |
|---|---|---|---|
| **L0 人格** | `persona.md`（已有） | 永远，最前 | **只有用户** |
| **L1 事实** | `memory/facts/*.md` | 索引常驻；正文由 `recall` 工具按需取 | 宠物**提议**，用户默认自动采纳（可关） |
| **L2 经验** | `library/<intent>/` | 按意图类注入 cue | 反思器，需证据 |

**写入纪律**（防记忆污染）：

1. **只记"跨会话仍然为真"的东西**。一次性事实（"今天清 3.2GB"）不记。
2. **必须有 `source`**（哪个 session、用户原话）。没有来源的记忆是幻觉。
3. **用户偏好优先于机器事实**：两者冲突时以用户为准。
4. **同 slug 覆盖而非追加**：`facts/user-scope-preference.md` 只有一份，新的覆盖旧的（带 `updated:` 时间）。
5. **上限 40 条**，超了按"最近被检索命中"淘汰（LRU）——防止记忆无限膨胀吃掉索引预算。

> 这里刻意**不做向量检索**。Harness² 的做法是"目录即检索"（retrieval by construction），桌宠的量级（≤40 条事实 + ≤60 条经验）用 cue 关键词匹配就够，而且**确定性、可解释、零依赖**。上向量库是过度工程。

---

### 5.4 组件四：技能（Skills）—— 按需加载的工作流

这是"少走弯路"的实现，也是 Harness² 里**性价比最高的组件**：按需加载，常驻成本近零。

#### 形态

```
skills/cleanup-scope/SKILL.md
---
name: cleanup-scope
description: 用户指定清理范围（"只清浏览器"/"别动 Docker"）时，如何把范围翻译成工具参数
---
# 清理范围

1. 从用户话里抽出：类别（browsers/dev/caches…）、排除项、应用名。
2. `scan_clean` 的 `sections` / `items` **必须显式传**。两个都不传 = 全盘扫描，这是禁止的。
3. 输出第一行必须回报实际范围："扫描范围：browsers（Safari, Chrome）"。
4. 若用户说的类别匹配不到任何 id：**报错并列出可用 id**，绝不静默扩大范围。
```

#### 加载机制（关键：桌宠没有"框架帮你按需加载"）

OpenCode 会自动读 SKILL.md。Swift 侧没有这层，所以要**显式补一个工具**：

```swift
// 新增两个工具，加进 BrainTools.allSpecs
use_skill(name: String) -> String   // 返回 SKILL.md 正文
recall(cue: String) -> String       // 返回匹配的 memory fact 正文
```

常驻文本里只有**一行广告**：

```
可用技能（需要时调用 use_skill）：
- cleanup-scope: 用户指定清理范围时，如何翻译成工具参数
- uninstall-residue: 卸载应用后如何核对残留
- dev-artifacts: 判断哪些构建产物可以安全删除
```

**这就是 Harness² "name+description 广告、正文按需"在 Swift 里的等价实现。** 常驻成本 = 3 行，收益 = 一个完整工作流。

#### 初始技能清单（P1 交付）

从现有代码里**已经写好但没进提示词**的知识中提炼，不新造：

| 技能 | 来源 | 解决的问题 |
|---|---|---|
| `cleanup-scope` | `HANDOFF.md §6.22`（范围参数静默失效事故） | 用户说"只清浏览器"却全扫 |
| `uninstall-residue` | `UninstallEngine` 的双键扫描逻辑 | 残留漏扫 |
| `dev-artifacts` | `PurgeEngine` 的 21 类产物 | 误删源码/误留垃圾 |
| `slim-gate` | `HANDOFF.md §6.41`（Intel 主机硬门禁） | 在 Intel 机上"成功"剥出废件 |
| `approval-etiquette` | `HANDOFF.md §6.27`（dismiss 即 deny） | 审批被 Esc 后的死锁体验 |

> 注意：这五条都是**已经用血换来的教训**，今天只存在于 HANDOFF.md 里——一个模型永远读不到的文件。把它们变成技能，是**纯赚**。

---

### 5.5 组件五：`LessonLibrary` —— 经验库（cue/lesson/evidence/confidence）

这是"不犯同样的错"的实现，也是 Harness² 的 `library.py` 直译。

#### 磁盘形态

```
~/.moppet/brain/library/
├── cleanup/
│   ├── INDEX.md                    # 自动重建，列出所有条目 + cue
│   └── 2026-10-20-scan-scope/
│       ├── LESSON.md
│       └── snapshot/               # 当时的 harness 树（审计用）
├── uninstall/
├── analyze/
├── slim/
├── startup/
├── dev/
└── chat/
```

`LESSON.md` 严格四字段（照抄 `prompts.py:1157`）：

```markdown
# 2026-10-20-scan-scope

- **cue**: 用户提到"只清 X"、"别动 Y"这类范围限定时
- **lesson**: 调用 scan_clean 前先把范围翻译成 sections/items 并显式传参；
  匹配不到就报错列出可用 id，绝不省略参数。
- **evidence**: session 2026-10-20T14:03 — 用户说"只清浏览器"，模型省略了
  sections，结果扫了全部 24 条规则；用户随后取消并重复了原话（TurnVerdict=bad）。
- **confidence**: high（有明确的行为分歧 + 用户纠正）
```

#### 四条写入纪律（直接来自 Harness²，逐条对应）

| 纪律 | Harness² 原文 | 本设计的落地 |
|---|---|---|
| **只写一条** | "at most one durable entry, and only if the edit rows support it" | 一个会话最多产 1 条经验 |
| **cue 是情境形状，不是本任务事实** | "'when an instrument performs several sequential acts…' 而不是 'the fee rose to 250'" | 反例：cue 不许写"清理 Safari 缓存时" |
| **evidence 必须指向具体时刻** | "Cite the run and the point in the trajectory where behavior diverges" | 必须带 session id + item 序号 |
| **证据不足就写 NO_ENTRY** | "If the record shows no concrete, reusable execution contrast, write NO_ENTRY" | **不写条目是合法且常见的结果** |

> 第 4 条最容易被实现者忽略，也最重要。一个"每次反思都必须产出经验"的循环，必然产出垃圾经验，然后这些垃圾被检索进上下文，宠物**越学越蠢**。**必须允许"这轮没学到东西"。**

#### 检索（L1，零模型调用）

意图分类（规则，不用模型）：

```swift
enum IntentClass: String, CaseIterable {
    case cleanup, uninstall, analyze, slim, startup, optimize, status, dev, chat
}
```

分类依据（按优先级）：
1. 本轮**实际调用过的工具名**（最可靠，事后判定）；
2. 用户文本关键词（"清理/清/卸载/分析/瘦身/启动项/状态"）；
3. 兜底 `chat`。

> 在线检索用 ②（事前）+ 上一轮的 ①（会话内延续）；反思落库用 ①（事后，准确）。**同一个枚举，两个时机，不同证据源**——这是"retrieval by construction"在桌宠上的正确形态。

注入格式（进 developer message，**不是** system prompt，避免污染常驻预算）：

```
## 相关经验（本类任务）
- [cleanup] 用户提到范围限定时：先把范围翻译成 sections/items 并显式传参…
- [cleanup] 扫描结果为空时：先确认 Full Disk Access，再报"没有可清理项"…
```

最多注入 3 条，按 `confidence` + 最近命中排序。

---

### 5.6 组件六：`TurnOutcome` —— 信号采集（代理奖励）

这是整套闭环的**度量基础**。没有它，反思器无从判断好坏。

#### 数据结构

```swift
struct TurnOutcome: Codable, Sendable {
    let sessionID: String
    let turnIndex: Int
    let intent: IntentClass
    let startedAt: Date

    // 负面信号（全部来自已存在的代码路径，不新增埋点成本）
    var toolCalls: Int = 0
    var toolErrors: Int = 0
    var approvalDenied: Bool = false
    var userCancelled: Bool = false
    var maxTurnsHit: Bool = false
    /// 说了要做但没有任何"变更型"工具调用（write/apply_patch/shell/execute_clean）
    var promisedButNoAction: Bool = false
    /// 用户在本轮结束后 120s 内发了语义近似的话（说明上轮没解决）
    var reAskedWithin120s: Bool = false

    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var wallSeconds: Double = 0
}
```

#### 判定（`TurnVerdict`，三态 + 未知）

**不做 0–100 分**（假精确）。只做三态判定，规则硬编码、可审计：

```swift
enum TurnVerdict: String, Codable { case good, neutral, bad, unknown }

static func verdict(_ o: TurnOutcome) -> TurnVerdict {
    if o.userCancelled || o.approvalDenied || o.maxTurnsHit { return .bad }
    if o.promisedButNoAction { return .bad }
    if o.reAskedWithin120s { return .bad }
    if o.toolCalls > 0 && o.toolErrors * 2 >= o.toolCalls { return .bad }   // 错误率 ≥50%
    if o.toolCalls == 0 && o.intent != .chat { return .neutral }            // 只聊了两句
    if o.toolErrors == 0 { return .good }
    return .neutral
}
```

设计要点：

- **`bad` 有多个独立触发条件，任意一个成立即 bad。** 对应 Harness² 的 "judge the downside as heavily as the upside"——**坏信号权重远大于好信号**。
- **`good` 很保守**（零错误 + 有工具调用）。宁可大量 `neutral`，也不要虚高的 `good`。
- **`unknown`** 用于无头模式 / scripted model / 用户没反应的会话，**不参与任何统计**。

#### 落盘

在 `BrainRollout.Record` 里加一个 case：

```swift
case turnOutcome(TurnOutcome)   // JSONL: {"type":"turn_outcome","payload":{...}}
```

**兼容性已验证**：`BrainRollout.readRecords` 对无法解码的行 `continue`（`:209`），旧版本读到新记录会**跳过而不是崩溃**；新版本读到旧文件也不缺字段（全部有默认值）。这是安全的加字段方式。

---

### 5.7 组件七：`Reflector` —— 会话后反思

L2 的执行体。**一次模型调用，小上下文，异步，可失败**。

#### 输入（**压缩过的证据**，不是全文轨迹）

> **v2 修订（重要）**：初版把 `session.md` 全文喂给反思器。实测一个真实的清理会话（`scan_clean` 的 JSON 输出本身就 2–3k tokens，`find_large_files` 更夸张）整份轨迹 3.6–26k tokens，**每天 10 个会话就是 38 万 tokens，预算是 15 万**。所以输入必须压缩，且**不是所有会话都值得反思**。

```
~/.moppet/brain/growth/<sessionID>/reflect/
├── outcomes.md         # 结构化，≤300 tokens（逐轮 TurnOutcome + verdict）
├── focus/1.md          # 只放"坏点"上下文：坏信号前后各 3 个 item，工具输出截到 600 字符
├── focus/2.md          # 最多 2 个坏点（按严重度取前 2）
├── harness.md          # 只放常驻文本（≤1500 tokens），不放技能全文
└── MISSION.md          # 短指针
```

**不再提供 `session.md` 全文。** 理由：反思器要回答的是"**这一步为什么错了**"，不是"这次都发生了什么"。坏点前后 3 个 item 已经包含决策所需的全部上下文；剩下的都是噪声，而噪声是要花钱的。

压缩收益：单次输入 **8.5k → 4.2k**（典型会话），且**不再随会话变长而线性增长**——重会话从 26k 压到 5k，这才是关键（否则一个"分析全盘"的会话就能吃掉当天一半预算）。

`MISSION.md` 的形态**照抄 `context.mission`**——短指针 + "去读文件，不要只看这条消息"：

```
# 你的任务
这个会话刚刚结束，并且至少有一个回合被判为 bad。读 context/ 下的证据，回答两件事：
1. 那个坏点是怎么产生的？是 harness 缺了什么，还是这一次的偶发？
2. 有没有一条**能迁移到下次同类任务**的经验。

# 你的证据
outcomes.md   逐轮判定与信号（先读这个）
focus/*.md    每个坏点的上下文，前后各 3 个 item
harness.md    当时生效的 harness 常驻文本

不要复述本会话的具体事实（"清了 3.2GB"），那只属于这一次。
如果证据不足以支撑一条可复用的经验，就输出 NO_ENTRY——这是合法答案。
```

#### 输出契约（严格解析，解析失败即丢弃）

```
<edits>
component: guardrails.md
change: 增加了"范围必须显式传参"
observed: session 2026-10-20T14:03 第 7 个 item — scan_clean 无 sections，扫了全部
verdict: helped | hurt | no observed effect | confounded
</edits>

<experience>
cue: 用户提到范围限定时
lesson: 调用 scan_clean 前先把范围翻译成 sections/items 并显式传参；匹配不到就报错
evidence: session 2026-10-20T14:03，第 7 个 item，用户随后取消并重复原话
confidence: high
</experience>
```

或

```
NO_ENTRY
```

**解析纪律**：
- `cue` / `lesson` / `evidence` 三个字段**任一为空 → 整条丢弃**（照抄 `selection._distil` 的 `all(out.get(k) for k in (...))`）；
- `verdict == confounded` 的经验**不进库**，只进审计日志（照抄"a lesson resting only on confounded rows is a guess"）；
- 含具体事实（数字 + 单位、具体文件名）的 `cue` → 拒绝（V7）。

#### 触发时机（**好会话不反思**）

> 这是最省钱的一条，也是最容易做错的一条。初版写"会话结束就反思"——那等于把 70% 的钱花在"这次做得挺好"的会话上，而好会话恰恰学不到东西。

触发条件（**必须至少满足一条**）：

1. 会话结束 **且** `outcomes` 里至少 1 个 `bad`；
2. 累计 `bad` 判定 ≥ 2（会话中途就值得反思，不必等结束）；
3. 用户显式纠正（"不对"/"我说的是…"）；
4. 用户点了 👎（若做反馈 UI）。

**全 `good` / 全 `neutral` 的会话直接跳过，一个 token 都不花。** 这不是偷懒：Harness² 的核心纪律是"**只改证据支持要改的地方**"，一个没出问题的会话，证据不支持任何改动。

**每天最多反思 8 次**（从 20 降到 8：因为已经过滤掉了好会话，剩下的都是真有问题的），超了排队到次日。

---

### 5.8 组件八：`ShadowProber` —— 影子回放探针（核心创新）

> **要解决的问题**：候选 harness 比现有 harness 更好吗？没有 grader、没有产物、不能打扰用户。

#### 为什么不能照抄盲选

Harness² 的盲选需要"产物"（交付物），桌宠的"产物"是**它做过的事**——而重做一遍有副作用（可能真的删文件）。所以不能重跑，只能**回放**。

#### 核心洞察

**你无法判断"什么是好"，但你能判断"是否重犯了已知的错"。**

历史 rollout 里记录了每一次工具调用和它的输出，包括**失败的调用**（`error:` 前缀）。这些就是免费的"已知坏时刻"。候选 harness 的价值，就看它**在这些坏时刻上会不会做出不同的选择**。

#### 算法

```
输入：会话 S 的 rollout，候选 harness H'，基线 H0
输出：{mistakeReproduced, goodReproduced, diverged} 三个计数

1. 从 S 重建 items[]。
2. 找决策点：所有紧邻 function_call 的 index i。
3. 采样至多 P=3 个决策点，**优先选"记录里该调用失败了"的点**。
4. 对每个点：
   a. 用 H'.systemPrompt 重放 items[0..<i]（工具**只声明、不执行**）。
   b. 取模型第一个工具调用 (name', args')。
5. 分类（与记录的 (name, args) 比）：
   - 记录是失败调用：
       · name'/args' 与记录**等价**（同工具 + 同关键参数）→ mistakeReproduced += 1  ❌
       · 不同 → diverged += 1  （**只记"分歧"，不当"胜利"**）
   - 记录是成功调用：
       · 与记录等价 → goodReproduced += 1  ✅（无回归）
       · 不同 → diverged += 1  （**不判好坏**）
```

#### 打分（刻意不对称）

```
score(H') = goodReproduced - 2 × mistakeReproduced
```

- **重犯错误扣 2 分，保持正确只加 1 分**。这是 Harness² "judge the downside as heavily as the upside" 的量化版本。
- **`diverged` 不得分**。这是最关键的一条：如果给"分歧"加分，候选 harness 只要**随机乱改**就能刷分，整个闭环立刻失效。**只有当分歧发生在"已知是坏"的时刻，才可能有价值——而那个价值也无法在回放里证明，只能进影子实跑去验。**

#### 为什么这是合法的证据

回放用的是**真实历史前缀**（真实的用户输入、真实的工具输出），只替换了 system prompt。它测的是"同一个决策点，不同 harness 下模型的倾向"。这不是模拟环境，是**策略层面的反事实**。

**它测不到什么**（必须在文档里说清楚）：换了一个动作之后，后续观测会完全不同，回放看不到下游。所以：

> **回放只做筛选（screening），不做定论。定论必须来自影子实跑（§5.10 第二关）。**

#### 成本

每个决策点 1 次模型调用，上下文 = 该点之前的 items（通常 5–20 个 item）。**不执行任何工具**。一次会话 3 个点 × 2 个候选 = 6 次小调用。这是空闲期可以承受的。

#### 硬约束

- **绝不执行工具**：`ShadowProber` 只调用 `model.streamTurn`，拿到 tool call 就丢弃，不经过 `BrainTools.dispatch`。代码里要有一个 `assert(!didDispatch)` 级别的隔离（用一个假的 `BrainTools.Context`，其 `dispatch` 直接抛错）。
- **只读**：除了写 `growth/<session>/probe.json`，不改任何文件。
- **可抢占**：每两个决策点之间检查 `UserActivity.isBusy`。

---

### 5.9 组件九：`Evolver` + `PromotionGate` —— 演化与晋升

#### Evolver 调度（L3）

```swift
@available(macOS 14, *)
actor Evolver {
    func tick() async {
        guard GrowthSettings.enabled, Budget.remaining > 0 else { return }
        guard await UserActivity.shared.isIdle(for: .minutes(10)) else { return }

        // 1. 选域：最近 7 天 bad 率最高、且样本量 ≥ 5 的意图类
        guard let domain = await pickWorstDomain(minSamples: 5) else { return }

        // 2. 收集证据：该域最近 ≤ 8 个会话
        let evidence = await buildEvidence(domain: domain, limit: 8)

        // 3. Propose（1 次大调用，输出候选 harness 树）
        let candidate = try await HarnessEditor.propose(domain: domain, evidence: evidence)
        try HarnessValidator.validate(candidate)        // 不过就丢弃，不重试（空闲期不值得）

        // 4. Probe（影子回放，≤ 3 点 × 会话数）
        let screen = try await ShadowProber.screen(candidate, against: evidence, maxPoints: 3)

        // 5. Compose（仅在 screen 通过时才需要，k=1 时 == candidate）
        guard screen.passes else { await ledger.discard(candidate, reason: screen.reason); return }

        // 6. 交晋升门
        await PromotionGate.shared.submit(candidate, domain: domain, screen: screen)
    }
}
```

**关键决定：k=1。** Harness² 的 k 路并行是为了在 benchmark 上榨分。桌宠要的是**稳定小幅改进**，不是榨分。k=1 顺序化，配合"KEEP_BASE 合法"，产出质量靠**晋升门的严格**而不是**候选的多样**。

#### 晋升门（三关，逐关收紧）

| 关 | 判据 | 代价 | 风险 |
|---|---|---|---|
| **① 屏幕** | `score(H') > score(H0) + margin`，且 `mistakeReproduced < H0`，样本 ≥ 6 个决策点 | 离线，几美分 | 零（不生效） |
| **② 影子实跑** | 在**真实回合**上并行跑 H'，**丢弃输出**，只记 H' 的首个意图动作；连续 ≥ 10 轮，`bad` 率不高于 H0 | 2× token（仅该域） | 零（不生效） |
| **③ 灰度** | 该域**生效** H'，自动回滚：连续 2 次 `bad` 或 24h 内 `bad` 率 > H0 + 20% | 1× | 低（有回滚） |

**风险分级**（对应 Harness² 的 INV / DOM）：

| 改动类型 | 涉及文件 | 晋升要求 |
|---|---|---|
| **DOM（领域）** | `library/`、`skills/`、`memory/facts/` | ①②③ 自动通过即可 |
| **INV（全局）** | `systemprompt.md`、`guardrails.md`、`tool_guidance.md` | ①②③ **+ 用户显式确认**（Settings 里看 diff 点同意） |

> 这条分级是整个安全设计的支点：**局部的、可撤销的改动可以自动；全局的、影响所有对话的改动必须人点头。** 全局改动一旦跑偏，用户会在所有场景里感受到，而它又没有 grader 兜底。

#### 回滚

```
harness/
├── active -> versions/v7      （符号链接，原子切换）
└── versions/
    ├── v7/   （当前）
    ├── v6/
    └── … 保留最近 5 个
```

切换 = 写新目录 → `rename(2)` 换符号链接（原子）。回滚 = 指回上一版。`harness.json` 记录 `parent` 形成 DAG，可追溯"哪次改动导致了退化"。

---

### 5.10 组件十：`GrowthLedger` —— 预算与指纹

照抄 `ledger.py` + `runmark.py` 的两个核心思想：

**1. 预算是硬闸门，不是建议。**

```swift
struct GrowthBudget {
    var maxTokensPerDay: Int = 150_000     // ≈ 一次深度反思 + 两次探针
    var maxProbesPerDay: Int = 30
    var maxPromotionsPerWeek: Int = 2      // ← 防抖动的关键
}
```

`maxPromotionsPerWeek = 2` 是**反"越改越飘"**的核心旋钮：一个每周改两次的宠物是"在进化"，一个每天改五次的宠物是"精神不稳定"。

**2. 指纹防重复劳动。**

```swift
func fingerprint(_ tree: HarnessTree) -> String   // sha1 over sorted (path, content)
```

- 提议前先算指纹，命中历史则**直接复用结论**（`runmark.is_complete` 的思想）；
- 候选 harness 的指纹写进 `TurnOutcome`，这样"某个版本表现差"能精确归因到树，而不是"大概是昨天那个改动"。

---

### 5.11 组件十一：`DecisionRouter` —— 决策成本阶梯

> 本节回答一个具体问题：**能不能引入一个专职的轻量决策模型（小模型）来省 token？**
> **答案：省不了钱，但值得做——理由不是成本（§6.4 会证明成本大头在别处），而是准确率长尾、离线可用和延迟。** 而且真正该上小模型的地方不是"决策"，是"检索"。

#### 5.11.1 先把"决策"数清楚

整套设计里需要做判断的地方只有 10 个，逐个看它们该由谁来做：

| # | 决策 | 频率 | 误判后果 | 现在 | 该由谁做 |
|---|---|---|---|---|---|
| D1 | 意图分类（9 类） | 每轮 | 检索错经验（**可恢复**） | 规则 | 规则，模糊时小模型 |
| D2 | `TurnVerdict` 三态 | 每轮 | **污染经验库**（不可恢复） | 规则 | **只能规则** |
| D3 | 是否反思 | 每会话 | 多花/少花一次调用（可恢复） | 规则 | 规则 |
| D4 | 取哪 3 条经验 | 每轮 | 上下文里塞错东西（可恢复） | 关键词打分 | 规则 → **embedding**（见 5.11.4） |
| D5 | 是否重复提问 | 每轮 | 多记一条 bad（可恢复） | 规则（弱） | 小模型 + 双阈值 |
| D6 | 承诺未兑现 | 每轮 | 误判 bad（可恢复） | 规则（弱） | 规则 + 小模型兜底 |
| D7 | 蒸馏哪条经验 | 每会话 | **污染经验库** | 主模型 | **只能主模型** + 严格解析 |
| D8 | 提议 harness 改动 | ≤1/天 | 装坏 harness | 主模型 | **只能主模型** |
| D9 | 晋升判定 | 每候选 | **影响全局** | 规则 | **只能规则** |
| D10 | 是否回滚 | 每次生效 | 该回不回 | 规则 | **只能规则** |

#### 5.11.2 三级阶梯

```swift
enum DecisionRisk { case low, high }

protocol DecisionMaker: Sendable {
    /// 返回 nil = "我决定不了"，交给下一级。绝不返回猜测。
    func decide(_ q: DecisionQuery) async -> String?
}

struct RuleDecider: DecisionMaker       // 0 token，确定性，可单测
struct SmallModelDecider: DecisionMaker // 本地 Ollama 或 flash 级云端
struct MainModelDecider: DecisionMaker  // 兜底
```

路由规则只有一条：**规则先答，答不了才升级；`risk == .high` 的决策永不进入小模型。**

```swift
actor DecisionRouter {
    func decide(_ q: DecisionQuery) async -> String? {
        if let r = await RuleDecider().decide(q) { return r }        // 覆盖 ~85%
        guard q.risk == .low else { return nil }                     // 高风险到此为止
        if let s = await small?.decide(q) { return s }               // 长尾
        return await main?.decide(q)                                  // 兜底
    }
}
```

#### 5.11.3 关键原则：规则不是"廉价替代品"

对 D2/D7/D9/D10 这四类，**规则是唯一正确的实现，不是降级方案**。理由：

- **可审计**：用户问"为什么把我这轮判成 bad"，规则能给出确定答案；小模型只能说"我觉得"。
- **可测试**：`--brain-smoke` 能断言 `verdict(cancelled) == .bad`；小模型不能断言。
- **零延迟**：`verdict` 在 `runLoop` 的出口同步算，不能等一次网络往返。
- **错误代价不对称**：意图判错只是检索错经验，下一轮就纠正了；**`verdict` 判错会写进经验库，被之后所有同类任务检索到——这是永久性污染**。Harness² 的原话是 "an invented attribution poisons the library for every later task"。对不可恢复的错误，只能用在数学上可证明的规则。

> 这条和 §1.3 的"坏信号权重远大于好信号"是同一个道理的两种表述：**越靠近"会写进持久状态"的决策，越不能交给概率模型。**

#### 5.11.4 检索：别做语义匹配，把别名写死（**v3 修订，有实测**）

`cue` 匹配用关键词确实弱（中文同义表述多："别动 docker" vs "docker 不要清"）。但**三条"更聪明"的路都被实测否掉了**（详见 `docs/LOCAL-LLM-OPTIONS.md` §3.6）：

| 方案 | 每轮成本 | 延迟 | 离线 | 实测结论 |
|---|---|---|---|---|
| 问主模型"哪条相关" | ~300 tokens | 1–3 s | ❌ | 能用但贵且慢 |
| 问小模型 | ~120 tokens | 0.2–1 s | 半 | 能用，需装 Ollama |
| 本地 GGUF embedding | 0 token | ~10 ms | ✅ | 可用，但要多 ship 95–270 MB 模型 |
| ~~系统 `NLEmbedding`~~ | 0 | ~1 ms | ✅ | ❌ **实测区分度不可用** |
| ~~系统 `NLContextualEmbedding`~~ | 0 | ~10 ms | 半 | ❌ **中文资产拿不到** |

**系统 embedding 的实测数据**（查询 `"只清一下浏览器缓存，别动 docker"`）：

| 候选 cue | 余弦 |
|---|---|
| 帮我写一首关于春天的诗（域外） | **0.9626** |
| **用户要求不要清理 docker（域内·最相关）** | **0.9510** |
| 今天天气怎么样（域外） | 0.9174 |

**无关句排在相关句前面，全部分数挤在 0.90–0.97。** 我原方案里写的"`cos < 0.62` 丢弃"在这个分布下毫无意义。

**所以正确做法是：既然 cue 是我们自己写的，就给它显式挂别名。**

```markdown
- **cue**: 用户提到清理范围限定时
- **aliases**: 只清, 别动, 不要碰, 范围, 只清理, 别删, 排除, 除了, 仅, 只
```

匹配 = **别名命中数 + 字符 bigram 重合度**，确定性、可单测、0 依赖、0 延迟。经验库 ≤60 条、每条 ≤10 个别名，这个规模下**比任何 embedding 都可靠**——因为这是 Harness² 说的"构造即检索"（retrieval by construction），而不是"猜语义"。

> 只有一种情况才需要真 embedding：**经验库 > 200 条且别名维护不过来**。那时再上 GGUF（`bge-small-zh-v1.5` Q8 ≈ 95 MB），而不是用系统那个。

#### 5.11.5 如果一定要用"简单提示词让模型走决策"

可行，但必须遵守 5 条，否则省下的钱会被浪费掉：

```
system（固定不变，可命中 prompt cache）:
你是标签分类器。只输出标签本身，不要解释、不要标点、不要 JSON、不要引号。
可选标签：cleanup uninstall analyze slim startup status dev chat

user:
用户刚说：「只清一下浏览器缓存，别动 docker」

期望输出（≤8 tokens）:
cleanup
```

| # | 规则 | 为什么 |
|---|---|---|
| 1 | **不要 JSON** | `{"intent":"cleanup"}` ≈ 6–8 tokens，`cleanup` = 1 token。**5 倍浪费**，而且解析更脆 |
| 2 | `maxOutputTokens: 8` + `temperature: 0` | 不设上限它就会"解释一下"，一句话就把预算吃掉 |
| 3 | **解析失败直接降级到规则，不重试** | 重试比规则贵，而且规则本来就答得出 |
| 4 | 标签表放 system 且**永不改动** | 才能命中 prompt cache；每次改标签表 = 缓存全失效 |
| 5 | 一次调用出多个决策（3 行） | 固定开销（system + 指令）摊薄 3 倍：`intent: cleanup` / `repeat: no` / `promise: no` |

**配置成本几乎为零**：`AIVendor.ollama` 已经是一等公民（`AIAgent.swift:30`，`needsAPIKey = false`，默认 `http://127.0.0.1:11434/v1` + `qwen2.5:7b`）。所以 `SmallModelDecider` 只是**再建一个 `AISettings`**，不需要任何新管线。

> **防呆**：如果用户把小模型配成和主模型同一个（没装 Ollama 就填了云端 key），要检测并**直接禁用这一级**——否则"小模型"只是"更慢的主模型"，纯亏。

#### 5.11.6 结论

| 问题 | 答案 |
|---|---|
| 引入决策模型能省 token 吗？ | **不能**。决策全走主模型也只占优化后总量的 32%，而三处工程优化能省 94%（§6.4） |
| 那要不要做 `DecisionRouter`？ | **要**，但目的是：长尾准确率（D1/D5/D6）、离线可用、延迟 |
| 能不能用简单提示词让现有模型走决策？ | **能**（5.11.5），但它省不了钱——**规则才是省钱的那一个** |
| 最该上小模型的地方？ | ~~检索~~ → **没有**。检索用别名（§5.11.4 实测）；小模型只在 D1/D5/D6 的长尾兜底 |
| 本地模型能替代主脑吗？ | **不能**。8 GB M1 上常驻上限约 0.6B，工具调用会崩（`docs/LOCAL-LLM-OPTIONS.md` §5） |

---

## 6. 关键算法汇总

### 6.1 意图分类（零模型调用）

```
1. 若本轮有工具调用：取调用次数最多的工具所属域（scan_clean→cleanup, execute_clean→cleanup,
   uninstall_app→uninstall, analyze_disk→analyze, scan_slim→slim, scan_launch_items→startup,
   system_status→status, shell/apply_patch/read_file→dev）
2. 否则若会话上一轮有：沿用
3. 否则按用户文本关键词匹配（中英各一套）
4. 兜底 chat
```

### 6.2 经验检索打分

**v1（关键词，无依赖）**：

```
score(lesson) = 3 × (cue 关键词命中数) + confidenceBonus(high=2, medium=1, low=0)
                - 0.5 × (最近 7 天已注入次数)     // 防同一条经验反复刷屏
取 top 3，score > 0 才注入
```

**v2（别名 + bigram，仍然是零依赖）**：见 §5.11.4。

```
hit    = 3 × (aliases 命中数)
overlap = 2 × (cue 与用户输入的字符 bigram Jaccard)
score  = hit + overlap + confidenceBonus + 0.1 × recency
取 top 3，score ≥ 3 才注入
```

v1 先上，**v2 只需要给每条 cue 补一行 `aliases:`**——这是编辑工作，不是工程工作。

> **不要换成 embedding。** 系统自带的两种都实测不可用（§5.11.4），引入 GGUF embedding 要多 ship 95–270 MB，换来的收益在"≤60 条、自己写的 cue"这个规模上几乎为零。

### 6.3 晋升决策

```
if screen.samples < 6:                    reject("证据不足")          // 对应 KEEP_BASE
if screen.mistakeReproduced >= base.mistakeReproduced: reject("未改善")
if screen.score <= base.score + margin:   reject("改善不显著")
if shadow.badRate > base.badRate + 0.20:  reject("影子实跑退化")
if isInv(change) && !userApproved:        hold("等待用户确认")
else:                                     promote()
```

### 6.4 Token 经济学（实测测算）

假设：每天 10 个会话、每会话 6 轮、`scan_clean` 返回 40 条。

#### 初版设计（每个会话都反思 + 喂全文轨迹）

| 会话类型 | 单次输入 | 每天 10 次的日计 |
|---|---|---|
| 轻（只 scan 一次） | 3,600 | 36,000 |
| 典型（scan + 执行 + 复核） | 8,500 | 85,000 |
| 重（大文件 / 全盘分析） | 26,000 | 260,000 |
| **合计** | | **381,000 / 天**（1,143 万 / 月） |

预算 15 万/天 → **上线第二天就超 2.5 倍**。这是初版设计的实际缺陷。

#### 三处纯工程优化（不引入任何新模型）

| 措施 | 机制 | 节省 |
|---|---|---|
| ① 跳过好会话 | 只有 `bad` 才反思（§5.7） | 调用次数 10 → 3（**-70%**） |
| ② 压缩输入 | 只喂坏点前后 3 个 item（8.5k → 4.2k；重会话 26k → 5k） | 单次 **-50%**，且**不随会话变长线性增长** |
| ③ 合并调用 | 反思 + 提经验合成 1 次（原设计隐含 2 次） | 调用次数 **-50%** |

| 优化后 | 日计 |
|---|---|
| 反思 4,200 × 3 | 12,600 |
| 演化提议 1 次 × 10,000 | 10,000 |
| **合计** | **22,600 / 天（67.8 万 / 月）** |

**降幅 94%。**

#### 成本

| 模型 | 月输入 | 月成本 |
|---|---|---|
| `gemini-2.0-flash-lite`（$0.075/1M） | 0.68M | **$0.05** |
| `claude-sonnet-4-5`（$3/1M） | 0.68M | **$2.03** |

> 结论：优化之后，**成长功能的钱根本不是问题**（几美分到两美元/月）。真正该担心的不是账单，是 §10 的"越学越蠢"。

#### 决策层的占比（为什么决策必须走规则）

| 方案 | 日 token | 占优化后总量 |
|---|---|---|
| 60 次决策 × 120 tokens，全走主模型 | 7,200 | **32%** |
| 规则（0 token） | 0 | 0% |
| 小模型（本地 Ollama） | 7,200 | 32%（但**0 元**） |

> **决策频率高（60 次/天）、单次便宜（120 tokens）；反思频率低（3 次/天）、单次贵（4,200 tokens）。** 所以"省 token"的杠杆在**把高频决策变规则**（已做），而不是"给决策换个便宜模型"——后者省的是钱，不是 token，而钱本来就不是问题。

---

## 7. 数据结构

### 7.1 `harness.json`

```json
{
  "version": 7,
  "parent": 6,
  "createdAt": "2026-10-28T09:12:00Z",
  "createdBy": "evolver",
  "domain": "cleanup",
  "summary": "scan_clean 范围参数改为必填检查",
  "evidence": { "sessions": ["..."], "probe": { "mistakeReproduced": 0, "goodReproduced": 9 } },
  "stats": { "turns": 0, "bad": 0, "good": 0 }
}
```

### 7.2 `SKILL.md` frontmatter

```yaml
---
name: cleanup-scope          # 必须与目录同名
description: 用户指定清理范围时，如何翻译成工具参数   # 必填，否则静默丢弃
---
```

### 7.3 `LESSON.md`

见 §5.5。四字段强制，`confidence ∈ {high, medium, low}`。

### 7.4 新增 Swift 文件清单

```
Sources/Moppet/Brain/Harness/
├── PetHarness.swift          # 树模型、读取、组装、种子
├── HarnessSurface.swift      # 路径白名单（is_allowed 的 Swift 版）
├── HarnessValidator.swift    # 校验 + autotrigger
├── HarnessStore.swift        # 版本、原子切换、回滚、指纹
├── MemoryBank.swift          # facts 读写 + LRU
├── SkillCatalog.swift        # 技能索引 + use_skill 后端
├── LessonLibrary.swift       # 经验读写 + INDEX 重建
├── IntentClass.swift         # 意图分类
├── TurnOutcome.swift         # 信号 + verdict
├── DecisionRouter.swift      # 决策阶梯：Rule → Small → Main（§5.11）
├── CueMatcher.swift          # 别名 + bigram 检索（零依赖，§6.2）
├── Reflector.swift           # L2 反思
├── ShadowProber.swift        # 回放探针
├── Evolver.swift             # L3 调度
├── PromotionGate.swift       # 三关晋升
├── GrowthLedger.swift        # 预算 + 指纹缓存
└── HarnessSmokeTest.swift    # 新增断言（并入 --brain-smoke）
```

---

## 8. 接入点（精确到函数）

| 现有代码 | 改动 | 风险 |
|---|---|---|
| `BrainRollout.swift:226` `systemPrompt(...)` | 改为 `PetHarness.compose(...)`，保留原实现为 `legacySystemPrompt` 兜底 | 低 |
| `BrainRollout.swift:298` `assembleDeveloperMessage` | 追加"相关经验"与"记忆索引"两段 | 低 |
| `BrainRollout.swift:18` `enum Record` | 加 `case turnOutcome(TurnOutcome)`（编解码两处） | 低（已验证向后兼容） |
| `BrainAgent.swift:637` `runLoop()` | 循环外建 `TurnOutcome` 收集器；`return` 前落盘 | 中（要覆盖所有 return 路径：取消/错误/完成/超限） |
| `BrainAgent.swift:376` `submit()` | 首行 `UserActivity.busy = true`；`cancel()` 里 `Evolver.cancel()` | 低 |
| `BrainAgent.swift:720` 工具并行块 | 记录 `isError` 计数与调用名 | 低 |
| `BrainTools.swift` `allSpecs` | 追加 `use_skill` / `recall` 两个只读工具 | 低 |
| `ToolRegistry` | **不动**（安全层不可编辑） | — |
| `SettingsView` | 加 "Brain Growth" 卡片：版本、diff、回滚、预算、开关 | 中（新 UI） |
| `BrainSmokeTest` | 加 §11 的断言 | 低 |

> **`BrainAgent.runLoop` 有 4 个 return 出口**（取消 `:650`、流错误 `:682`、正常完成 `:716`、超限 `:768`）。`TurnOutcome` 必须在**全部四个**出口落盘——这正是 `HANDOFF.md §6.40`（"等待交互必须有无人应答出口"）的同类教训：**任何多出口函数，每个出口都要有人收尾**。

---

## 9. 分阶段路线

### P0 · 外置提示词（0.5–1 天，零行为变化）

- `PetHarness` + `HarnessSurface` + `HarnessStore`（种子写入、读取、降级）
- 首次启动把当前硬编码文本写成种子文件
- **验收**：`--brain-smoke` 断言"树内容 == 种子时，组装的 prompt 与旧 `legacySystemPrompt` **逐字节相同**"

> 这一步单独发版的价值：把"提示词"从代码资产变成**用户可看的数据**，同时暴露那两个编号 7。

### P1 · 技能 + 记忆（2–3 天，用户可感知）

- `SkillCatalog` + `use_skill` 工具 + 5 个初始技能
- `MemoryBank` + `recall` 工具 + INDEX 注入
- `HarnessValidator`（V1–V6）+ `autotrigger`
- Settings 只读展示（看到技能列表、记忆列表、常驻字数）

> **这一步是投入产出比最高的。** 不动模型、不动演化，只把"已经写在 HANDOFF 里的教训"变成模型能读到的技能。用户会立刻感到"它记得我说过别动 Docker"。

### P2 · 反思（3–5 天，开始学习）

- `TurnOutcome` + `TurnVerdict` + 落盘
- `Reflector` + `LessonLibrary` + 检索注入
- **输入压缩（§5.7）+ 跳过好会话（§5.7 触发时机）必须和反思同批上线**——不是优化项，是前置条件。否则第一天就烧掉 38 万 tokens
- Settings 展示"本周学到的 N 条经验"，可删可改

### P2.5 · 检索增强（0.5 天，纯编辑工作）

- 给每条 cue 补 `aliases:` 行 + `CueMatcher`（§6.2 v2）
- **不需要任何模型**：系统 embedding 实测不可用（§5.11.4），GGUF embedding 在 ≤60 条规模上不划算

### P3 · 自演化（5–8 天，开始自己改自己）

- `ShadowProber` + `Evolver` + `PromotionGate` + `GrowthLedger`
- `DecisionRouter`（§5.11）—— 此时才有足够决策量值得抽这一层
- 三关晋升、自动回滚、版本 diff UI
- **默认关闭**，用户主动开启

### P4 · 可选

- 声明式 hooks（`Stop` 时检查"承诺未兑现"）
- 跨设备同步经验库（iCloud Drive）

### 9.4 待决策

| # | 问题 | 建议 |
|---|---|---|
| 1 | P3 默认开还是关？ | **默认关**。开启前跑够 7 天 P2 数据，让用户看到"它在学"再交出方向盘。 |
| 2 | 日预算多少？ | 15 万 token。用户可调，UI 显示"本月成长花费"。**实测优化后约 2.3 万/天，预算其实很宽裕**（§6.4）。 |
| 3 | 宠物能否自主新增技能？ | **能，但只能进 `staging/`**，用户批准后才进 `active/`（技能是"怎么做事"，比记忆更该被审） |
| 4 | 记忆默认自动采纳吗？ | **是**（可关）。记忆写错只影响一条事实，影响面小；技能写错影响一整类任务。 |
| 5 | 要不要给用户看"智商分"？ | **不要**。只展示行为事实（"这周它少问了你 3 次偏好"）。 |
| 6 | 要不要启用小模型（`DecisionRouter` 第 2 级）？ | **P2 之后再做，默认"跟随主模型配置"**。没装 Ollama 就自动禁用，不要逼用户装。**优先级低于 embedding 检索**（§5.11.4）。 |

---

## 10. 风险与防线

| 风险 | 后果 | 防线 |
|---|---|---|
| **提示词漂移**：越改越长、越来越像"通用助手" | 宠物失去性格、变慢、变笨 | always-on 硬上限 + "加一条必须砍一条" + 版本 diff 可见 |
| **过拟合单次会话** | 为一次异常改全局规则 | 重复证据要求（≥2 次）+ `confounded` 不入库 + 反事实事实检查（V7） |
| **垃圾经验污染上下文** | **越学越蠢**（最危险） | `NO_ENTRY` 合法 + 三字段强校验 + 检索 top-3 上限 + 用户可删 |
| **自我修改破坏安全** | 用户数据受损 | **安全层不在可编辑面** + 路径白名单 + 沙箱仍由代码裁决 |
| **演化抢占用户请求** | 宠物变慢 | 每步检查 `UserActivity`，`submit()` 立即 cancel |
| **版本抖动** | 用户感觉"性格不稳定" | `maxPromotionsPerWeek = 2` + 三关晋升 + 自动回滚 |
| **无头模式死锁** | CI/自测挂死 | L2/L3 走 Core 层直接调用，禁 `MainActor.run`（`HANDOFF §6.1`） |
| **Token 费用失控** | 用户账单 | 日预算硬闸 + 免费厂商兜底 + 默认关闭 P3 + **跳过好会话 / 压缩输入**（§6.4，-94%） |
| **小模型误判写进持久状态** | 经验库被污染 | **高风险决策（verdict / 经验采纳 / 晋升 / 回滚）永不进入小模型**（§5.11.3） |
| **小模型只是"更慢的主模型"** | 白等一次往返 | 检测到与主模型同厂商同模型时自动禁用该级 |
| **记忆写错且被反复引用** | 错误固化 | 每条带 `source`；用户可在 Settings 一键删；LRU 上限 40 |

---

## 11. 测试计划（并入 `--brain-smoke`）

沿用现有风格（stderr `✓/✗`，非零退出码）。预计 +38 条断言（51 → 89）。

**Harness 基础**
1. 首次启动写出种子树；文件数与预期一致
2. 树 == 种子 → 组装 prompt 与 `legacySystemPrompt` 逐字节相同
3. 删除 `systemprompt.md` → 回落到种子（**不为空**）
4. 删除整个 harness 目录 → 回落到 legacy（**不为空**）

**校验器**
5. 常驻超上限 → 抛错，文案含实际值与上限
6. 技能缺 `description:` → 抛错
7. 技能未被点名 → `autotrigger` 补行成功且幂等（跑两次结果相同）
8. 技能引用的脚本不存在 → 抛错
9. 路径 `../../etc/passwd` → 拒绝
10. 一次校验列出**全部**问题（不是第一个就返回）

**记忆**
11. fact 缺 `cue:` → 拒绝
12. 同 slug 写入覆盖而非追加
13. 超过 40 条 → LRU 淘汰最久未命中
14. `recall` 命中返回正文；未命中返回明确的"没有相关记忆"（不返回空串）

**信号与判定**
15. 取消 / 拒绝审批 / 撞上限 → 均判 `bad`
16. 承诺未兑现（无变更型调用）→ `bad`
17. 零错误 + 有调用 → `good`
18. 无头模式 → `unknown`，且不参与统计
19. `turnOutcome` 记录 round-trip；旧文件（无该记录）可正常加载

**反思**
20. 缺 `evidence` 字段 → 整条丢弃
21. `NO_ENTRY` → 不写任何条目，不报错
22. `confounded` 经验 → 只进日志，不进库

**探针（最关键）**
23. 回放**不执行任何工具**：给假 context，其 dispatch 直接抛错；断言全程未触发
24. 已知坏时刻：候选重犯 → `mistakeReproduced +1`
25. 分歧但非坏时刻 → **不计分**（防刷分）
26. 打分对候选顺序不敏感（确定性）

**晋升与回滚**
27. 样本 < 6 → 拒绝
28. 未改善 → 拒绝，**active 不变**
29. 通过 → 切换后 `active` 指纹 == 候选指纹
30. 回滚 → 指纹 == 上一版（逐字节）

**决策阶梯（§5.11）**
31. `RuleDecider` 能答时**不调用**任何模型（注入计数桩，断言 0 次）
32. `risk == .high` 的决策**永不**进入 `SmallModelDecider`（D2/D7/D9/D10 各一条）
33. 小模型返回 `nil` / 超时 → 降级到主模型，不抛错
34. 小模型被配成与主模型同厂商同模型 → 该级自动禁用（防"更慢的主模型"）
35. 决策输出解析失败 → **不重试**，直接走规则

**预算与成本**
36. 全 `good` 的会话**不触发**反思（断言 0 次调用）
37. 单次反思输入 > 6,000 tokens → 触发压缩告警（防止回归成"喂全文"）
38. 日预算耗尽 → `Evolver.tick()` 直接返回，不发起任何调用

---

## 12. 度量与验收

**上线 30 天后，看这四张图（都在 Settings → Brain Growth 里）：**

| 指标 | 期望 | 反例信号 |
|---|---|---|
| 偏好重复交代次数 | ↓ | 没降 → 记忆没生效或 cue 写错 |
| 中位工具轮次（同域） | ↓ | 上升 → 技能太长 / 提示词膨胀 |
| 同类工具错误复发率 | ↓ | 没降 → 经验没被检索到 |
| 版本变更频率 | ≤ 2 次/周 | 超了 → 晋升门太松，在乱改 |

**验收判据（P1 结束时）**：同一句"只清浏览器，别动 Docker"，第二次对话时宠物**不再追问范围**，且 `scan_clean` 的 `sections` 参数正确。

**验收判据（P3 结束时）**：连续 2 周无人工干预，至少发生 1 次"探针否决了一个看起来合理的改动"——**能拒绝自己，才叫会学习**。

---

## 13. 附录 A：Harness² 源码对照表

| 概念 | Harness² 文件 | 本设计对应 |
|---|---|---|
| 八组件树 | `core/tree.py` | `HarnessSurface.swift` |
| 路径白名单 | `tree.is_allowed` | `HarnessSurface.isAllowed` |
| 校验 | `tree.validate` | `HarnessValidator.validate` |
| 自动补触发行 | `tree.autotrigger` | 同名 |
| 树差异 | `tree.diff_summary` | `HarnessStore.diff` |
| 多样性 | `tree.diversity`（line-Jaccard） | 经验库塌缩检测 |
| 证据树 | `core/context.py:build` | `growth/<sid>/` |
| 任务说明（短指针） | `context.mission` | `MISSION.md` |
| 提议 | `core/proposer.py` + `prompts.propose` | `HarnessEditor.propose` |
| 合成 | `prompts.aggregate` | `Evolver.compose`（k=1 时退化为候选本身） |
| 盲选 | `core/selection.py:run_selection` | `ShadowProber`（形态改变） |
| 反思蒸馏 | `selection._distil` | `Reflector` |
| 经验库 | `core/library.py` | `LessonLibrary` |
| 预算账本 | `core/ledger.py` | `GrowthLedger` |
| 指纹 | `core/runmark.py` | `HarnessStore.fingerprint` |
| 反答案泄漏 | `context.assert_no_grader_verdicts` | `HarnessValidator` V7 |
| 并行/顺序递归 | `core/recursion.py` | `Evolver`（仅顺序，k=1） |

---

## 14. 附录 B：默认 harness 种子（P0 交付物）

`systemprompt.md` 从现有硬编码文本**逐字迁移**，只做两处修正：

```diff
- 7. Long-running commands: use exec_command ...
- 7. request_user_input is for genuine decisions only ...
+ 7. Long-running commands: use exec_command ...
+ 8. request_user_input is for genuine decisions only ...
+ 9. Keep responses concise. Answer in the user's language. Stay in character.
- 8. Keep responses concise. ...
```

并把"环境块"（cwd / sandbox / approval）**移出文件**，改为运行时注入——它是动态的，不该出现在可编辑面里（否则用户一改就与真实配置不符）。

`guardrails.md` 只保留**行为约束**，删掉与代码重复的安全描述（`BrainSandbox.involvesDeletion` 才是真相），避免"文本和行为各说各话"：

```markdown
# 行为护栏

1. 先看再做：读文件、跑只读命令，再动手。
2. 改文件用 apply_patch，不要用 shell heredoc。
3. 删除类操作永远先问用户——不要试图绕开（真正的拦截在代码里，绕不过去）。
4. 清理任务：先 scan_clean 展示结果，用户同意后再 execute_clean。
5. 范围必须显式：用户点名了类别/应用就必须传参，绝不省略。
6. 长命令用 exec_command 轮询，不要用一个巨大的 timeout 堵住回合。
7. 回答简短，用用户的语言，保持角色。
```

---

## 15. 一句话收尾

Harness² 真正教给我们的，不是"让 agent 自我进化"这个口号，而是三件很朴素的事：

**把 harness 当成可校验的数据；没有真值时就只在"已知是坏"的地方对比；证据不足就不改。**

桌宠要变聪明，缺的从来不是更强的模型，而是**记住这次、下次别犯**。这三件事，正好够用。
