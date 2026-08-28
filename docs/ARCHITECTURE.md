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
- `training_timeline.lua` 是有界的纯领域对象，只接受 Action 起点、判定开闭、受击和结果五类事件；它不读取游戏、不渲染 UI、不写校准文件。
- `runtime.lua` 集中隔离类型名、字段、方法、输入、TimeScale、位置与生命操作。
- `runtime.lua` 通过 `EnemyManager.getBossEnemyCount/getBossEnemy` 轮询专用任务中的大型怪物，不挂钩 `EnemyCharacterBase.update`。
- `action_reader.lua` 是游戏版本变化最大的边界，优先沿怪物继承链查找明确白名单中的零参数 Getter 或字段。直接成员不可用时，只枚举已知只读对象 `EnemyActionParam` 的成员定义，并且只读取 ActionNo/ActionID/ActionCategory 精确白名单字段或调用精确白名单零参数 Getter；枚举出的其他方法只记录名称，不执行。仍不可用时才降级为 `via.motion.Motion` 第 0 层的 `MotionBankID:MotionID` 状态键，并复用一个 `via.motion.MotionInfo` 查询名称和结束帧；脚本重载时释放该实例。诊断必须分别标记 `action_param_field`、`action_param_method` 或 `motion`。
- `view.lua` 只消费 Model 和屏幕尺寸，不决定固定/随机派生。单轮复盘由 `timeline_presenter.lua` 把领域快照压缩为一行语义摘要，View 按修订号缓存并在绘制前用当前字体测量最终宽度。
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

猎人实时动作采用 `player_action_reader → player_action_observer → PlayerCombatState.action_state.evidence → player_action_semantics → Model` 的单向依赖。Reader 只接触 REFramework 对象，Observer 负责去重和有界历史，语义解析器只消费武器数据包，Model 记录稳定契约。动作节点到“见切/居合”等名称的映射禁止写入 Reader、Controller 或 View。社区来源的节点只标记为候选；本机观察表示“节点确实出现”，不等于映射已经实机验证，更不等于反击成功。

开发期自动校准额外使用 `runtime_player_action_signal.json` 作为只读适配边界。它只在离线、支持版本且 Quest ID 为 `200032002` 时启用，只在节点转换时写当前节点与修订号；外部白名单输入适配器依据该信号连接复合按键。动作模板只声明 `primary_attack`、`secondary_attack`、`weapon_special`、`evade` 等稳定业务角色；运行前由只读 `snow.StmInputConfig` 契约把角色解析为本机 main/sub 键鼠绑定，再在 Windows 输入边界转换为白名单物理操作。输入计划同时读取活动红/蓝书的替换技，并把技能前置条件不满足的步骤写入 `excluded_steps`；显式请求不适用步骤、绑定读取不完整或物理键尚无白名单实现时均失败关闭。招式预期节点仍属于输入计划/数据契约，不下沉到通用按键桥或游戏 Runtime。正常陪练任务不产生该信号。

外部输入适配器只允许在会话开始时取得一次游戏焦点。后续每个输入操作都要求游戏仍是前台窗口；玩家切走窗口即视为接管，采集器释放白名单按键并失败关闭，不得再次抢回焦点。临时请求只在匹配终态报告后删除，避免误删其他开发会话；正式 Mod 不依赖此外部输入路径。

键位名称与 Win32 raw 值在输入边界集中转换。Capcom Windows 默认配置的 `Mouse Button 4` 映射到 Win32 `XBUTTON1 / dwData 0x0001`，不得按字符串中的数字误用 `XBUTTON2 / 0x0002`；映射依据同时保留[官方武器操作页](https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6)和[微软 `mouse_event` 定义](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-mouse_event)。默认模板仅用于离线结构测试；真实校准必须消费完整、零失败、未截断的当前绑定契约，main 不可用时只回退到同设备 sub。Windows 桥只允许转换 `MOUSE_L/R/EX1/EX2` 与 `Space`，并采用微软推荐的批量 `SendInput`；这只证明操作被系统接受，不代表 MHR 已识别相应武器语义。`MOUSE_EX1` 的旧/新 API 两轮均未形成见切节点，因此复合气刃动作不再走 Windows 物理输入。手柄绑定属于 `snow.Pad.Button`，产品快捷键属于 `via.hid.GamePadButton`，两者在取得跨枚举证据前不得按名称或 raw 值互换。动作信号超时、玩家接管焦点和输入发送失败是三个不同的外部结果，批处理器保存当前步骤证据后，只对玩家接管立即停止。

`input_motion_adapter` 的语义输入调查边界是独立的只读契约：只检查 `snow.StmInputManager`、`snow.StmPlayerInput`、`snow.player.PlayerInput` 与 `snow.StmInputManager.InputUI` 四个明确类型，并保存 `CommandButton2` 枚举、过滤后的字段/方法签名、已知 `getOn/getTrg/getRel/getDelay/isOn/isTrg/isRel/isDelay` 查询方法及受管单例可用性。契约不调用发现的方法、不安装 Hook、不写位集，并以 `gameplay_method_calls=0`、`gameplay_writes=0` 暴露安全不变量。它只负责回答“语义命令由谁持有、在哪个更新点可观察”，后续受控写入实验必须作为单独版本实现和验收，不能在元数据发现阶段顺手注入。

上一层元数据在实机确认后，`semantic_bitset_contract` 才允许对 `snow.StmInputManager` 的 `getOn/getTrg/getRel/getDelay` 四个精确零参数 getter 各调用一次。全局上限固定为 4；调用失败、对象缺失和类型不可读分别记录。返回对象只做元数据检查，禁止调用其 `set/clear/add/remove/reset/toggle` 候选方法。结果按 Adapter 实例缓存，避免 Overlay 每帧重复读取；自动分析即使发现修改候选也保持 `experiment_allowed=false`。

`player_input_owner_contract` 使用显式依赖方向：Runtime 负责通过既有 `PlayerManager.findMasterPlayer()` 生命周期取得当前猎人，输入 Adapter 只接受这个可空实例并生成序列化只读契约。它先按字段名和声明类型过滤 `input/command/button`，再读取命中的字段，避免为了找输入对象遍历或触碰猎人的所有状态。契约只记录字段声明类型、实际对象是否存在及实际类型，不持有游戏对象，不调用发现的方法。标题阶段的空玩家结果不会缓存，进入任务后可在同一 Adapter 中重新解析；成功快照才缓存，防止 Overlay 每帧反射。

### 离线怪物数据管线

- `extract_monster_ai.py` 是 PAK/文件列表边界，只选择目标 `emXXX` 的 AI 入口并计算资源引用闭包；不同怪物 ID 和变体是输入值，不进入 Mod 业务代码。
- `rsz_ai_dump` 是第三方 RszTool 的薄适配器，只输出实例类型、字段、值和引用 ID；领域层不依赖 RszTool 对象。
- `rsz_ai_dump --include-timing-assets` 额外导出 RCOL 的分组、碰撞形状、RequestSet 和内嵌 RSZ。RszTool 0.3.5 解析 MHR `.rcol.20` 前必须应用 `tools/rsz_ai_dump/patches/RszTool-0.3.5-mhrise-rcol.patch`；适配器会自行纠正该版本库对多位扩展名的误读。
- `build_monster_behavior_graph.py` 只消费结构化 RSZ JSON，输出稳定的 ThinkState、Action、Condition 和 Transition 契约。`fixed_action_edges` 采用保守证明规则：当前状态只有一条 `EnemyActionEnd` 边，且两端各有一个该怪物的编号攻击 Action。这样更换 REasy、RszTool 或新版 RSZ dump 时，不影响 Mod 的 Model/View/Controller。
- 原始 PAK、解出的 `.user.2` 和完整 RSZ dump 仅留在本地研究目录，不提交、不打包、不发布。

### BranchPrediction

- `fixed`：来自校准数据的确定派生。
- `conditional`：存在明确条件但当前尚不能唯一确定的候选。
- `random`：由原生随机选择的候选，不得显示为条件或固定。
- `observed`：数据包仅保存运行观察，尚未证明条件或随机机制。
- `unresolved`：来源冲突、类型未知或数据自称固定却包含多个候选。
- `observed_single` / `observed_candidates`：来自本次会话计数，只描述观察结果。
- 样本不足时返回空预测并显示“正在采集”。

上述确定性必须在数据包、Model、派生树与 Overlay 间端到端保留，不能把所有非固定边折叠成 `conditional/candidate`。固定边必须且只能有一个候选；违反该不变量时降级为 `unresolved`。

### TrainingTimeline

时间轴 schema v2 除怪物动作、判定开闭、伤害与结果外，还可记录只读 `player_action`。该事件区分 `attempt`、`stance`、`activation` 与成功专用节点；结果分类不得仅凭“未受伤”推断见切或居合成功。

- 每次 Action 开始建立一轮，事件严格按观察顺序保存；判定与受击事件同时保留 Motion 帧，不能用渲染帧或墙钟时间冒充动画时机。
- 开启结果追踪时，Action 切换可得 `hit` 或 `no_damage`；只读模式只能给出 `observed_hit` 或 `unclassified`，不得把“未观察到掉血”升级为成功。
- 活跃事件默认最多 128 条，溢出时显式累计 `dropped_events`；快照是只读副本，上一完整轮可跨普通重置保留以供复盘。
- 当前契约不包含视频、世界状态、玩家关键输入或防御/回避语义。后两项只有在 Runtime 提供已验证的语义事件后才能扩展，不能由 Action 结果反推。

### TrainingScenario

训练场景不再以“逐个强制播放一串 Action”为核心。默认语义是“指定一个起手，后续交还怪物原生 AI”：Mod 只在已证明的稳定空闲状态请求一次根动作，随后停止动作写入，由运行时观察 Action/FSM 转换；Model 对照静态派生图输出固定、条件、随机候选和本轮实际路径。

- `single_move`：仅用于已证明可独立退出、可安全重复的单招时机练习。
- `native_branch`：核心模式，包含根动作、上下文预设、观察深度、停止条件和派生图引用；根动作之后不得逐项注入后续 Action。
- `native_combo`：仅当高层 Combo/FSM 入口及完整退出条件已由静态 AI 和实机共同确认时开放；请求的是原生组合入口，不模拟一串 Action ID。
- `natural_condition`：产品 MVP 的原生派生模式；场景数据声明目标距离带、根动作和预期固定后继，Controller 只给出站位引导并观察 AI 自然选择，不调用动作请求接口。

训练重复次数是场景证据的一部分，而不是全局 UI 承诺。`max_verified_repeats` 给出该场景已通过的上限；Controller 必须把用户选择钳制到此上限并在菜单说明原因。没有该字段的旧场景沿用全局上限，以保持数据包向后兼容。
- 目标分支优先通过距离、朝向、怒气、形态等真实上下文诱导；强制后续分支只能作为醒目标注的实验模式，不能冒充真实 AI。

任何场景在已验证根动作、已验证请求方法、稳定空闲入口、退出/停止条件和失败恢复齐全前不得执行。一次注入成功只能证明请求机制，不足以证明该动作可重复训练；Action 20 的 `1/3` 后不退出证据已用于否决其用户入口。

首个 `native_branch` MVP 的完成定义是：选择根动作 → 必须先查看该根动作的派生树 → 用户确认开始 → 成功进入根动作 → 原生续接至少一层 → Overlay 在转换后一帧内显示当前路径和下一候选 → 固定边准确、条件/随机边不伪装为唯一答案 → 达到停止条件后给出本轮路径并可重试。未查看当前场景派生树时，Controller 本身拒绝开始，不能只依赖按钮隐藏。

运行时派生观测采用两层证据：Action Reader 提供战斗动作编号与动画，Behavior Tree Reader 从怪物 `GameObject` 的 `via.motion.MotionFsm2` 逐层读取树及活动节点。后者只读 `getLayer/get_tree_object/get_node/status/name`，不调用 `setCurrentNode`。实机已在轰龙咆哮期间解析出 `Attack.Roar` 与 `Attack.Roar.End`，因此后续根动作和实际路径应优先用 FSM 节点语义关联，Action ID 仅作为兼容与时序辅助信号。

原生派生入口采用双证据门禁：首先在自然 AI 中观察到根节点与后继节点；随后只触发一次候选根入口，并确认在不追加动作写入时仍由引擎续接相同后继。轰龙 Action 5000 已形成关键反例：自然 AI 中出现 `BiteHookHalfTurnStartShortRange -> BiteHookHalfTurnAttackNormal`，直接 Action 请求却在起手结束后转入 `Move.Dash`。因此 `setActionUnique` 只可承担已验证独立单招，不得作为 `native_branch`/`native_combo` 的根入口；原生派生必须激活保留 Think/FSM 决策上下文的高层入口，或通过可复现的距离、朝向、状态条件诱导 AI 自行选择。

Think Context Reader 以 `(ThinkInfoData 地址, StateNo, TreeNodeID)` 为运行时复合键，并只读导出每个状态的 Action 类型与编号、Condition 的 `_NextStateID`、引用子 ThinkData 路径。不能只用 `StateNo`：同一怪物同时存在多个子树且状态编号重复。轰龙半转身钩咬的 7200 帧验收已定位同一 12 状态子树中的状态 8（Action 5000）、状态 6（Action 5001）和状态 9（远距离 Action 5002）。任何高层写实验必须按完整子树身份匹配，并在调用前再次核对状态内 Action 契约。

条件诱导层只控制正常玩家输入，不写怪物 Transform、Action 或 Think。它使用运行时玩家—怪物水平距离和相机基向量进入 Profile 提供的观测距离带，再以 `(FSM 节点名, Action category/no, 原生后继)` 判断是否命中目标根。StateNo 仅作为诊断证据：实测同一 Action 5000 可由多个上层 Think 上下文选中，因此不得把单个 StateNo 当作生产入口或唯一身份。

训练派生契约兼容单一 `expected_successor`，并支持数据包声明多个 `expected_branches`。Controller 只接受数据包明确列出的后继，命中任一合法分支即记录实际 Action、名称、条件与分支类型；未知后继必须失败并保留诊断，不得以高频或强制 Action 退出路径自动宣称固定、条件或随机派生。派生语义来自静态 Think/FSM 与自然运行时证据，强制注入只验证起手自身的安全退出。

条件诱导的业务状态与移动执行器分离。开发验收执行器可在游戏外发送正常键盘输入，用于无人值守回归；产品 Lua 路径不得依赖窗口焦点或外部按键。`via.hid.GamePadDevice` 的通用轴 setter 已由三种时序实验否定，不能作为产品实现。MVP 的产品执行器为“距离引导”：View 显示接近/远离及当前距离，玩家正常移动，Controller 自动识别目标根并接管后续派生反馈。未来原生自动执行器必须实现相同语义契约并独立通过释放、异常、多人禁用和重复运行门禁。

直接激活未进入活动栈的 ThinkData 已被实验否定：`nextJumpThinkData` 能返回对象，但不会单独完成活动栈切换；追加 `startActionTable` 也不能建立完整生命周期，而返回对象和当前活动栈均不是目标 12 状态子树。不得通过手工构造 `ThinkInfoData`、直接写活动栈或跳 Motion FSM 节点继续放大风险。指定原生派生改用“条件诱导 + AI 自选根动作 + 目标筛选”：自动维持距离/朝向/状态条件，要求引擎自然选中目标根动作，命中后停止干预并观察原生后继。

## 新增怪物的最小改动

已确定会变化的只有三条边界：怪物知识、游戏运行时、训练场景。新增怪物时：

1. 增加一个与 `profile_tigrex.lua` 同契约的数据包和独立校准 JSON。
2. 在组合根选择目标 Profile；Model、View、Controller 不接触原始怪物 ID。
3. 运行同一套 Model 契约测试，再增加该怪物的固定/条件/随机派生测试。
4. 只有第二个真实 Profile 落地时才提取 Profile Registry，避免当前提前构建插件系统。

新增游戏版本时只改 `runtime.lua`/`action_reader.lua` 的显式版本分支，并保留 16.0.2.0 分支。未知版本默认只读校准，不自动沿用写操作。

怪物数据包在进入 Model 前必须通过 `monster_pack_validator.lua`。校验器只验证跨怪物稳定契约：怪物标识与 Action 类别、数值动作键、派生类型、后继招式存在性、固定边唯一性、条件边条件说明，以及公开训练场景的唯一 ID、根动作、执行模式、验证状态和重复上限。条件诱导场景还必须声明位置带，预期后继必须属于同一派生图。任何错误都使整个数据包安全降级为空包，不能把部分有效数据与错误训练入口混合加载；具体怪物的招式枚举仍只存在于数据包和对应测试中。

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
