# 猎人动作证据层

## 目标

应对建议最终需要知道猎人当前是否处于回避、受击、攻击，以及正在执行哪一个武器动作。该信息必须先成为可复核的只读证据，才能用于“见切成功”“居合成功”等训练结论；不能仅凭未受伤或一次动作节点变化推断成功。

## 当前契约

`player_action_reader.lua` 每次只读采样：

- `PlayerBase.getMotionFsm2()` 的第 0 层当前节点 ID；优先用树的 `get_node_by_id` 只解析当前出现的节点并有界缓存，树支持枚举时才批量建立最多 4096 项的 `node ID → full name` 目录；
- `PlayerBase.isActionStatusTag(ActStatus)` 的 `Attack`、`Escape`、`Damage`、`Jump`、`WireJump`、`Ride` 与可用时的 `Guard` 标签；
- 采样来源、可用性与缺失字段。

`player_action_observer.lua` 只在节点、标签或玩家武器运行时类型变化时记录事件，默认最多保存 128 项并显式记录丢弃数量。每个事件单独携带 `player_type`，防止切换武器后把旧动作误归入当前武器；离线分析器对旧版无逐事件类型的证据显式标记 `legacy_top_level_fallback`，武器专属知识包与当前玩家类型不匹配时拒绝生成语义映射。完整节点目录也随证据保存；运行时最多每 60 个采样帧落盘一次，稳定帧会冲刷尚未写出的最后变化，避免每个动作转换都写磁盘。`runtime_player_combat_state.json` 不以动作变化作为落盘键；实时 Model 仍取得每帧内存状态。运行证据写入 `runtime_player_action_evidence.json`，它不是静态数据包，也不会由开发部署覆盖。

`0.49.0` 起，`long_sword_knowledge.json` 可提供版本限定的动作节点候选，`player_action_semantics.lua` 以“最长精确匹配优先、其次最长前缀”的确定性规则解析。当前候选来自公开的 [MHRS Custom GP Frames](https://github.com/AlexQFMM2/MHRS-Custom-GP-Frames) 实现，只参考其只读节点名称与查询接口；本项目自行实现解析，不引入其动作树修改、GP 帧修改或自动反击代码。候选在本机被观察后仍保留来源与 `community_candidate` 状态，直到单独的实机动作验收将其升级。

当前明确不做：

- 不安装 `PlayerMotionControl.lateUpdate` 或伤害计算钩子；
- 不修改伤害返回值、玩家动作或行为树；
- 不把第三方 Mod 的动作哈希直接作为已验证映射；
- 不把 `Escape=true` 自动解释为见切，不把 `Damage=false` 自动解释为反击成功。

## 来源与证据等级

[REFramework](https://github.com/praydog/REFramework) 提供 RE Engine 托管对象反射与 Lua 访问能力。[MHR AutoDodge](https://github.com/Atomoxide/MHR_AutoDodge) 的公开实现证明 `getMotionFsm2()`、`getCurrentNodeID(0)`、`isActionStatusTag(...)` 及 `PlayerMotionControl` 动作字段可在 MHR 运行时访问；本项目只采用这些互操作接口事实，未复制其自动反击逻辑或动作表。该仓库没有可发现的许可证，因此其数字映射只作为研究线索，不进入本仓库。

[MHRice](https://github.com/wwylele/mhrice) 继续作为武器、技能与游戏数据结构的优先静态来源，但其当前代码不提供猎人实时动作语义。因此静态目录与运行时节点关联仍然是两个独立证据层。

[Custom GP Frames](https://github.com/AlexQFMM2/MHRS-Custom-GP-Frames) 的公开实现提供了玩家 Motion FSM 树可通过 `get_node_by_id(node_id):get_full_name()` 直接解析当前节点这一互操作事实。实机证明玩家树可能在当前版本返回 `get_node_count() == 0`，因此本项目采用“当前节点直查、出现后缓存”，不复制其 GP 帧覆盖、行为树跳转或奖励补偿逻辑。

## 后续一次性实机门禁

部署后用一个有界会话同时覆盖站立、普通攻击、翻滚、见切、特殊纳刀、居合与红蓝书切换。若节点全名本身具有稳定语义，离线分析优先直接使用名称；否则才聚类节点/标签转换，再由人工只确认聚类名称，而不是逐帧抄 Action ID。只有重复样本一致、游戏版本匹配且动作上下文明确的映射，才进入独立太刀动作数据包。

条件派生与固定派生不受此层影响：怪物派生树继续完整展示 `fixed`、`conditional`、`random/observed`，猎人动作证据只负责训练结果与武器建议的可信度。

证据生成后运行：

```powershell
python tools/analyze_player_action_evidence.py `
  <游戏目录>\reframework\data\MHRiseMonsterCoach\runtime_player_action_evidence.json `
  --output artifacts\player_action_analysis.json
```

分析器默认加载仓库的 `long_sword_knowledge.json`，同时输出探索性名称关键词候选和严格、版本限定的 `semantic_mappings`。后者会注明动作语义、尝试/成功角色、匹配方式、社区来源以及本机观察次数；本机出现节点不会自动把 `community_candidate` 升级为已验证语义。

分析器汇总目录覆盖、实际节点、标签组合与运行时转换，并按 `foresight/mikiri`、`iai`、`sacred` 等名称词根列出候选。词根命中只用于缩小审核范围，输出明确标记为候选，不会直接写回运行时语义映射。

部署后的确定性门禁使用 `tools/run_probe_session.ps1 -PlayerActionEvidence`。探针自动进入战斗层，只有当前玩家节点 ID 与全名都可读取时才完成；报告同时保存实际武器类型和当前训练时间轴快照。探针只读，不切换装备、红蓝书或技能。任意训练场景验收报告也携带同一时间轴快照，因此判定窗、玩家状态、受击和结果分类可以与起手验收一次采集。

## 自动校准任务与输入采集器

`0.49.11` 增加独立的开发期校准任务 `200032002`，用于自动关联太刀输入与玩家 Motion FSM。它不替换正式陪练任务 `200032001`，也不会进入普通部署清单：`tools/run_player_action_calibration.ps1` 只在游戏完全关闭后暂存校准任务，完成或失败后先正常关闭游戏，再校验并删除该文件；流程前后都会核对正式轰龙任务 SHA-256 未变化。

校准任务使用普通狩猎任务类型和零生成位，不生成大型怪物、不发放奖励。选择普通狩猎类型是因为 RiseQuestLoader 的公开实现只把 `TOUR` 放入探索任务入口，而 `HUNTING` 会进入普通大师任务列表；任务 ID 仍由 Quest Loader 动态注册。该任务只消除“等待怪物、死亡回营、任务污染”等采样噪声，不作为玩家可见功能分发。

自动采集器的安全边界：

- 先通过同一原生任务发布、自动出发、正常奔跑和原生区域传送链进入古塔战斗层；
- 仅接受官方 Windows 默认键位定义中的白名单键鼠输入，并在每步后读取运行时证据；
- 进入战斗层后保留 12 秒有界稳定期，避免古塔到达动画吞掉首批输入；
- 接受收刀 `wait.main` 与拔刀 `atk.atk_wait.atk_wait_main.atk_wait_main` 两种稳定中间态；
- 只记录实际武器、红蓝书、替换技和动作节点，不选择或写入装备、替换技、生命、伤害、存档与奖励；
- 外层已完成并校验部署时，内层探针复用安装收据，不重复部署。

开发者可在游戏关闭时运行：

```powershell
pwsh -NoProfile -File tools/run_player_action_calibration.ps1
```

当前实机证据已证明：独立任务可被原生接取、自动进入、自动穿越准备区，且在无怪物战斗层读取到实际太刀与红蓝书配置；白名单输入也已产生 `attack`、`escape` 和可读动作节点。上一次完整动作批次受古塔到达动画吞键以及拔刀待机未列入稳定态影响，只完成部分动作，因此仍标记为“启动链已验证、完整语义批次候选”。12 秒稳定期和拔刀待机修复已进入源码，留待下一次集中部署一次性复验，不要求玩家逐招手动标注。摘要证据见 `docs/evidence/PLAYER_ACTION_CALIBRATION_BOOTSTRAP_2026-08-27.json`。
