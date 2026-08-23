# 猎人动作证据层

## 目标

应对建议最终需要知道猎人当前是否处于回避、受击、攻击，以及正在执行哪一个武器动作。该信息必须先成为可复核的只读证据，才能用于“见切成功”“居合成功”等训练结论；不能仅凭未受伤或一次动作节点变化推断成功。

## 当前契约

`player_action_reader.lua` 每次只读采样：

- `PlayerBase.getMotionFsm2()` 的第 0 层当前节点 ID；首次遇到该 FSM 实例时只读建立最多 4096 项的 `node ID → full name` 目录，后续按 ID 常数时间查名；
- `PlayerBase.isActionStatusTag(ActStatus)` 的 `Attack`、`Escape`、`Damage`、`Jump`、`WireJump`、`Ride` 与可用时的 `Guard` 标签；
- 采样来源、可用性与缺失字段。

`player_action_observer.lua` 只在节点或标签变化时记录事件，默认最多保存 128 项并显式记录丢弃数量。完整节点目录也随证据保存；运行时最多每 60 个采样帧落盘一次，稳定帧会冲刷尚未写出的最后变化，避免每个动作转换都写磁盘。`runtime_player_combat_state.json` 不以动作变化作为落盘键；实时 Model 仍取得每帧内存状态。运行证据写入 `runtime_player_action_evidence.json`，它不是静态数据包，也不会由开发部署覆盖。

当前明确不做：

- 不安装 `PlayerMotionControl.lateUpdate` 或伤害计算钩子；
- 不修改伤害返回值、玩家动作或行为树；
- 不把第三方 Mod 的动作哈希直接作为已验证映射；
- 不把 `Escape=true` 自动解释为见切，不把 `Damage=false` 自动解释为反击成功。

## 来源与证据等级

[REFramework](https://github.com/praydog/REFramework) 提供 RE Engine 托管对象反射与 Lua 访问能力。[MHR AutoDodge](https://github.com/Atomoxide/MHR_AutoDodge) 的公开实现证明 `getMotionFsm2()`、`getCurrentNodeID(0)`、`isActionStatusTag(...)` 及 `PlayerMotionControl` 动作字段可在 MHR 运行时访问；本项目只采用这些互操作接口事实，未复制其自动反击逻辑或动作表。该仓库没有可发现的许可证，因此其数字映射只作为研究线索，不进入本仓库。

[MHRice](https://github.com/wwylele/mhrice) 继续作为武器、技能与游戏数据结构的优先静态来源，但其当前代码不提供猎人实时动作语义。因此静态目录与运行时节点关联仍然是两个独立证据层。

## 后续一次性实机门禁

部署后用一个有界会话同时覆盖站立、普通攻击、翻滚、见切、特殊纳刀、居合与红蓝书切换。若节点全名本身具有稳定语义，离线分析优先直接使用名称；否则才聚类节点/标签转换，再由人工只确认聚类名称，而不是逐帧抄 Action ID。只有重复样本一致、游戏版本匹配且动作上下文明确的映射，才进入独立太刀动作数据包。

条件派生与固定派生不受此层影响：怪物派生树继续完整展示 `fixed`、`conditional`、`random/observed`，猎人动作证据只负责训练结果与武器建议的可信度。

证据生成后运行：

```powershell
python tools/analyze_player_action_evidence.py `
  <游戏目录>\reframework\data\MHRiseMonsterCoach\runtime_player_action_evidence.json `
  --output artifacts\player_action_analysis.json
```

分析器汇总目录覆盖、实际节点、标签组合与运行时转换，并按 `foresight/mikiri`、`iai`、`sacred` 等名称词根列出候选。词根命中只用于缩小审核范围，输出明确标记为候选，不会直接写回运行时语义映射。
