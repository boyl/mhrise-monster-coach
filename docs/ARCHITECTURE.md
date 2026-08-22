# 架构与扩展契约

## 体验简报

目标用户是在高容错成本下练习怪物招式的猎人。唯一核心任务是：在同一单人任务中反复观察一个招式、决定是否减速、完成应对并立即重置。完成证据是本轮结果与累计成功/受击统计；退出路径是松开 F6、关闭功能或重载脚本；失败后可查看明确原因并保留校准记录。

## 依赖方向

```text
app (composition root)
 ├─ controller ──> model
 │       ├──────> runtime adapter ──> REFramework / MHRise
 │       └──────> view ─────────────> draw / imgui
 ├─ config
 └─ monster profile (Tigrex)
```

任务重开由 `quest_restart.lua` 保存跨场景状态，只依赖 Runtime 提供的语义操作：原生重置、据点就绪、柜台接取和出发。Controller 只启动用例并展示状态；任务 ID 来自怪物 Profile。运行时实现参考 AutoQuest 已验证的任务柜台 FSM 入口，但不依赖或复制其模块。

- `model.lua` 只处理训练状态、动作转换、派生语义和有界历史，不调用游戏 API。
- `runtime.lua` 集中隔离类型名、字段、方法、输入、TimeScale、位置与生命操作。
- `runtime.lua` 通过 `EnemyManager.getBossEnemyCount/getBossEnemy` 轮询专用任务中的大型怪物，不挂钩 `EnemyCharacterBase.update`。
- `action_reader.lua` 是游戏版本变化最大的边界，优先沿怪物继承链查找明确白名单中的零参数 Getter 或字段。直接成员不可用时，只枚举已知只读对象 `EnemyActionParam` 的成员定义，并且只读取 ActionNo/ActionID/ActionCategory 精确白名单字段或调用精确白名单零参数 Getter；枚举出的其他方法只记录名称，不执行。仍不可用时才降级为 `via.motion.Motion` 第 0 层的 `MotionBankID:MotionID` 状态键，并复用一个 `via.motion.MotionInfo` 查询名称和结束帧；脚本重载时释放该实例。诊断必须分别标记 `action_param_field`、`action_param_method` 或 `motion`。
- `view.lua` 只消费 Model 和屏幕尺寸，不决定固定/随机派生。
- `controller.lua` 拥有输入边沿、单人安全门、生命周期和用例编排。
- `profile_tigrex.lua` 与校准 JSON 保存怪物知识；原始 Action ID 不散布在业务代码中。

## 稳定契约

### MonsterFrameState

当前 MVP 输出 `enemy_id`、`action`、任务/联机状态、玩家生命与动作开始时间。距离、朝向、形态和怒气待相应 Getter 获得真实运行时证据后加入 Runtime 输出；不得由 Model 猜测。

怪物阶段由纯函数 `monster_phase.lua` 解析。它只消费怪物数据包中状态为 `confirmed` 的有效判定窗口，并可校验 Motion 名称；当前帧早于首个窗口为前摇，首个至最后一个窗口之间为攻击阶段，最后窗口之后为收招。多段攻击的窗口间隙仍视为攻击阶段，避免过早提示高承诺反击。缺少数据、Motion 不匹配或窗口非法时统一返回 `unknown`。

`hitbox_provider_native.lua` 是正式的实时物理判定来源；`hitbox_provider_hitboxviewer.lua` 仅为可选交叉验证后端，`hitbox_provider.lua` 负责选择和比较。Runtime 读取统一样本，Model 把判定边沿归入当前 Action，阶段解析与武器建议不依赖第三方模块。Native 不可用时可暂时回退到 Viewer 或怪物数据包的已确认窗口。

自动证据达到 `confirmed` 后无需人工复制到怪物 Profile：Model 会按 `ActionCategory + ActionNo + Motion` 生成只读 timing view，并直接交给阶段解析和武器应对引擎。运行时活动判定仍具有最高优先级；历史窗口用于前摇预判、收招判断以及 Native 暂不可用时的降级。

### MoveDefinition

- 输入：Action 字符串键、名称、短名称、应对建议、派生类型和候选列表。
- 不变量：`fixed` 只能有一个经验证的候选；观测数据不得升级为 `fixed`。
- 未知动作：显示 raw Action 并进入有界未知集合，不影响游戏。
- 自动名称：已校准名称优先；否则可显示 `MotionInfo` 返回的开发者名称，但其确定性只能标记为 `engine_name`，不能自动当作已确认的战斗语义。
- `engine_motion_cluster` 名称来自同一 ActionNo 下实机 Motion 名称的聚类，只用于可读提示；若同一 ActionNo 跨上下文复用，名称必须明确标注歧义，不能据此升级派生确定性。
- 动画进度仅显示引擎当前帧/结束帧；在命中窗口尚未从动作数据解析前，不把任意百分比命名为前摇、攻击或收招。

### 自动采集与低成本标注

- 每帧只查询当前状态，不扫描 MotionBank，也不枚举类型成员。
- `observed_state_metadata` 保存状态键到 Motion 名称、Bank/ID 和结束帧的映射；`observed_history` 保存有界的时序与持续时间；`observed_transitions` 保存聚合派生。
- `EnemyActionParam.get_ActionNo()` 与 `get_ActionCategory()` 是 TDB 71 实机确认的联合主状态键，规范形式为 `ActionCategory:ActionNo`。ActionNo 只在所属 Category 内有意义；不同 Category 下的同号动作不得共享名称、元数据或转换学习。只有攻击 Category 4 才能匹配静态攻击图。
- Motion 读取器在 ActionNo 可用后仍作为低优先级元数据源运行，把同一帧的 Motion 名称、Bank 和 ID 附加到 ActionNo；它永远不能反向取代 ActionNo 成为主键。只读诊断模式在 ActionNo 改变时更新单个本地状态快照，避免人工录屏和导出。
- 首次实机采样用于验证引擎名称质量。确认有效后，再基于名称、连续时间线和重复派生自动聚类候选招式；玩家只确认少量中文语义，不采集视频证据。
- 自动名称查询失败时退化为原始状态键和时间线，不中断实时观察。

### 武器上下文应对

静态 `MoveDefinition.advice` 只是无玩家上下文时的保底提示。武器专属建议采用 `MonsterMoveContext + PlayerCombatState → ResponseCandidate[]`，详细契约见 `RESPONSE_ENGINE.md`。Runtime 只负责把游戏字段转换为稳定语义，Model 保存状态并运行纯规则，View 不判断见切、居合或登龙是否可用。首个实现固定为太刀；第二种真实武器落地前不建立武器插件注册表。

### 离线怪物数据管线

- `extract_monster_ai.py` 是 PAK/文件列表边界，只选择目标 `emXXX` 的 AI 入口并计算资源引用闭包；不同怪物 ID 和变体是输入值，不进入 Mod 业务代码。
- `rsz_ai_dump` 是第三方 RszTool 的薄适配器，只输出实例类型、字段、值和引用 ID；领域层不依赖 RszTool 对象。
- `rsz_ai_dump --include-timing-assets` 额外导出 RCOL 的分组、碰撞形状、RequestSet 和内嵌 RSZ。RszTool 0.3.5 解析 MHR `.rcol.20` 前必须应用 `tools/rsz_ai_dump/patches/RszTool-0.3.5-mhrise-rcol.patch`；适配器会自行纠正该版本库对多位扩展名的误读。
- `build_monster_behavior_graph.py` 只消费结构化 RSZ JSON，输出稳定的 ThinkState、Action、Condition 和 Transition 契约。`fixed_action_edges` 采用保守证明规则：当前状态只有一条 `EnemyActionEnd` 边，且两端各有一个该怪物的编号攻击 Action。这样更换 REasy、RszTool 或新版 RSZ dump 时，不影响 Mod 的 Model/View/Controller。
- 原始 PAK、解出的 `.user.2` 和完整 RSZ dump 仅留在本地研究目录，不提交、不打包、不发布。

### BranchPrediction

- `fixed`：来自校准数据的确定派生。
- `conditional` / `random`：来自校准数据的候选及条件。
- `observed_single` / `observed_candidates`：来自本次会话计数，只描述观察结果。
- 样本不足时返回空预测并显示“正在采集”。

### TrainingScenario

训练场景不再以“逐个强制播放一串 Action”为核心。默认语义是“指定一个起手，后续交还怪物原生 AI”：Mod 只在已证明的稳定空闲状态请求一次根动作，随后停止动作写入，由运行时观察 Action/FSM 转换；Model 对照静态派生图输出固定、条件、随机候选和本轮实际路径。

- `single_move`：仅用于已证明可独立退出、可安全重复的单招时机练习。
- `native_branch`：核心模式，包含根动作、上下文预设、观察深度、停止条件和派生图引用；根动作之后不得逐项注入后续 Action。
- `native_combo`：仅当高层 Combo/FSM 入口及完整退出条件已由静态 AI 和实机共同确认时开放；请求的是原生组合入口，不模拟一串 Action ID。
- 目标分支优先通过距离、朝向、怒气、形态等真实上下文诱导；强制后续分支只能作为醒目标注的实验模式，不能冒充真实 AI。

任何场景在已验证根动作、已验证请求方法、稳定空闲入口、退出/停止条件和失败恢复齐全前不得执行。一次注入成功只能证明请求机制，不足以证明该动作可重复训练；Action 20 的 `1/3` 后不退出证据已用于否决其用户入口。

首个 `native_branch` MVP 的完成定义是：选择根动作 → 必须先查看该根动作的派生树 → 用户确认开始 → 成功进入根动作 → 原生续接至少一层 → Overlay 在转换后一帧内显示当前路径和下一候选 → 固定边准确、条件/随机边不伪装为唯一答案 → 达到停止条件后给出本轮路径并可重试。未查看当前场景派生树时，Controller 本身拒绝开始，不能只依赖按钮隐藏。

运行时派生观测采用两层证据：Action Reader 提供战斗动作编号与动画，Behavior Tree Reader 从怪物 `GameObject` 的 `via.motion.MotionFsm2` 逐层读取树及活动节点。后者只读 `getLayer/get_tree_object/get_node/status/name`，不调用 `setCurrentNode`。实机已在轰龙咆哮期间解析出 `Attack.Roar` 与 `Attack.Roar.End`，因此后续根动作和实际路径应优先用 FSM 节点语义关联，Action ID 仅作为兼容与时序辅助信号。

原生派生入口采用双证据门禁：首先在自然 AI 中观察到根节点与后继节点；随后只触发一次候选根入口，并确认在不追加动作写入时仍由引擎续接相同后继。轰龙 Action 5000 已形成关键反例：自然 AI 中出现 `BiteHookHalfTurnStartShortRange -> BiteHookHalfTurnAttackNormal`，直接 Action 请求却在起手结束后转入 `Move.Dash`。因此 `setActionUnique` 只可承担已验证独立单招，不得作为 `native_branch`/`native_combo` 的根入口；原生派生必须激活保留 Think/FSM 决策上下文的高层入口，或通过可复现的距离、朝向、状态条件诱导 AI 自行选择。

Think Context Reader 以 `(ThinkInfoData 地址, StateNo, TreeNodeID)` 为运行时复合键，并只读导出每个状态的 Action 类型与编号、Condition 的 `_NextStateID`、引用子 ThinkData 路径。不能只用 `StateNo`：同一怪物同时存在多个子树且状态编号重复。轰龙半转身钩咬的 7200 帧验收已定位同一 12 状态子树中的状态 8（Action 5000）、状态 6（Action 5001）和状态 9（远距离 Action 5002）。任何高层写实验必须按完整子树身份匹配，并在调用前再次核对状态内 Action 契约。

条件诱导层只控制正常玩家输入，不写怪物 Transform、Action 或 Think。它使用运行时玩家—怪物水平距离和相机基向量进入 Profile 提供的观测距离带，再以 `(FSM 节点名, Action category/no, 原生后继)` 判断是否命中目标根。StateNo 仅作为诊断证据：实测同一 Action 5000 可由多个上层 Think 上下文选中，因此不得把单个 StateNo 当作生产入口或唯一身份。

条件诱导的业务状态与移动执行器分离。开发验收执行器可在游戏外发送正常键盘输入，用于无人值守回归；产品 Lua 路径不得依赖窗口焦点或外部按键。`via.hid.GamePadDevice` 的通用轴 setter 已由三种时序实验否定，不能作为产品实现。MVP 的产品执行器为“距离引导”：View 显示接近/远离及当前距离，玩家正常移动，Controller 自动识别目标根并接管后续派生反馈。未来原生自动执行器必须实现相同语义契约并独立通过释放、异常、多人禁用和重复运行门禁。

直接激活未进入活动栈的 ThinkData 已被实验否定：`nextJumpThinkData` 能返回对象，但不会单独完成活动栈切换；追加 `startActionTable` 也不能建立完整生命周期，而返回对象和当前活动栈均不是目标 12 状态子树。不得通过手工构造 `ThinkInfoData`、直接写活动栈或跳 Motion FSM 节点继续放大风险。指定原生派生改用“条件诱导 + AI 自选根动作 + 目标筛选”：自动维持距离/朝向/状态条件，要求引擎自然选中目标根动作，命中后停止干预并观察原生后继。

## 新增怪物的最小改动

已确定会变化的只有三条边界：怪物知识、游戏运行时、训练场景。新增怪物时：

1. 增加一个与 `profile_tigrex.lua` 同契约的数据包和独立校准 JSON。
2. 在组合根选择目标 Profile；Model、View、Controller 不接触原始怪物 ID。
3. 运行同一套 Model 契约测试，再增加该怪物的固定/条件/随机派生测试。
4. 只有第二个真实 Profile 落地时才提取 Profile Registry，避免当前提前构建插件系统。

新增游戏版本时只改 `runtime.lua`/`action_reader.lua` 的显式版本分支，并保留 16.0.2.0 分支。未知版本默认只读校准，不自动沿用写操作。

## 陪练任务列表位置契约

- 陪练任务保留其怪物与任务参数对应的星级，不得为了醒目统一塞入其他星级。
- 完全自定义陪练任务依赖 RiseQuestLoader 在原版同星级任务之后执行追加；运行时适配器捕获返回列表，并在调用链完全返回后的下一次更新中，只把已登记的陪练 Quest ID 移除并重新追加，因此陪练任务区位于其他自定义任务之后。
- 同星级只有一个陪练任务时，它就是列表最后一项；同星级有多个陪练任务时，它们共同组成末尾的陪练任务区。
- 陪练任务区内部顺序由组合根登记顺序决定；其他任务的相对顺序必须保持不变。排序 Hook 只在受支持运行时安装，安装或执行失败时记录一次警告并保留 QuestLoader 原始顺序。

## 状态与交互矩阵

| 状态 | 触发 | 可见反馈 | 可用操作 | 清理/保留 |
|---|---|---|---|---|
| 初始/等待 | 未进任务 | 提示进入单人任务 | 设置 | 保留配置 |
| 观察 | 未找到轰龙或读取器未定 | 显示等待/校准原因 | 导出元数据 | 保留采样 |
| 准备 | 找到读取器但无动作 | 显示读取器就绪 | F8、设置 | 清空本轮临时量 |
| 执行 | Action 可读 | 当前动作、派生、F6/F7/F8 | 减速、重置 | 有界记录历史 |
| 成功 | 动作切换且未掉血 | No damage 与 streak | 重试、继续 | 保留统计 |
| 失败 | 检测到生命下降 | 本轮受击量 | F7、继续 | 清空本轮伤害 |
| 重开中 | 任务内按一次 F7 | 返回据点/接取/出发/加载的当前阶段 | 等待；忽略重复 F7 | 成功进入同一任务后完成；失败时关闭柜台并停止 |
| 禁用 | 联机任务或运行时指纹不匹配 | 明文说明写操作禁用 | 只读观察、退出 | 立即恢复 1.0x |
| 错误 | 回调异常 | 显示带阶段的错误 | 查日志、重载 | 立即恢复 1.0x；保留配置 |

## 生命周期与内存边界

- 所有回调只在入口加载时注册一次。
- Action 历史最多 256 条，学习源动作最多 128 个；未知集合受学习上限间接约束。
- 屏幕绘制不构建目录、不读写 JSON、不扫描元数据。
- 脚本重置、联机切换、离开任务和 REFramework 设置界面打开时恢复 1.0x。
- 配置只在实际变化或 REFramework 保存时写入；脚本重置只做清理。
