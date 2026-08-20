# 直接局内重置研究契约

## 目标

在不退出当前任务、不返回据点、不重新加载地图的前提下，恢复猎人、轰龙和训练轮次到可重复练习的初始状态。

## 完整性要求

- 猎人：安全位置/朝向、生命、耐力、翔虫、武器临时状态和受击状态。
- 怪物：安全位置/朝向、生命、AI/FSM、动作、部位破坏、异常、疲劳/怒气及残留攻击判定。
- 场景：陷阱、投射物、掉落物和本轮临时对象不污染下一轮。
- 生命周期：连续 20 次不崩溃、不冻结、不累积对象；多人和非陪练任务禁用。

## 路径优先级

1. 游戏原生训练/任务内重置入口。
2. 由 `EnemyManager` 销毁并按任务配置重新生成目标怪物，同时使用玩家管理器的原生重生/Warp 流程。
3. 经过状态机协调的逐子系统恢复。

已证明会触发原生 `c0000005` 的直接 `Transform.set_Position/set_Rotation` 写回永久排除。`forceResetThink` 等 AI 方法只覆盖思考状态，不能单独作为完整重置。

## 当前探针

启动时自动生成 `runtime_in_place_reset_probe.json`，只枚举目标类型及其父类中与 spawn、despawn、destroy、arrange、reset、restart、revive、warp 等相关的方法签名和字段；不调用任何候选方法。

## 第一阶段候选

- F8 记录用户选择的猎人位置；只复制坐标值，不保留临时 Transform 引用。
- F9 等待怪物活动判定结束，然后调用 `PlayerBase.setPosWarpConsiderDogRide` 和 `EnemyCharacterBase.warpEnemyInitPos`，并恢复双方生命。
- 本阶段不宣称清除部位破坏、异常、怒气、投射物或陷阱；目的仅是验证原生 Warp 连续调用是否安全。
- F7 任务重开保持不变，作为完整且已验证的回退路径。

### 已知跨区域风险

准备区锚点在战斗区直接交给 `PlayerBase.setPosWarpConsiderDogRide` 会绕过 StageManager 区域切换并导致原生崩溃。F8 现通过 `snow.CharacterBase.get_AreaNo()` 保存真实 AreaNo，F9 在 AreaNo 不一致时执行硬拒绝，不再使用距离猜测。最终跨区设计需要通过 `StageManager.setPlWarpInfo`、`requestAreaMoveQuest` 与 WarpFlow 完成原生区域切换，再恢复语义快照。

环境生物管理器已定位为 `snow.envCreature.EnvironmentCreatureManager`；后续从其重生、创建与区域生命周期成员中确定最小原生重建序列。
