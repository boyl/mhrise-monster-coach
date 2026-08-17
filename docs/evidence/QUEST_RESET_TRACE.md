# 原生任务重置轨迹

## 运行时

- 游戏：Steam《怪物猎人崛起：曙光》16.0.2.0
- REFramework：`mhrise / TDB 71`
- 任务：陪练轰龙，Quest ID `200032001`
- 采集策略：只读 Hook；未调用任何游戏业务方法

## 已观测顺序

玩家在游戏菜单确认“重置任务”后：

1. `snow.QuestManager.notifyReset()` 进入。
2. `snow.QuestManager.onQuestReturn()` 由其内部同步调用并返回。
3. `snow.QuestManager.notifyReset()` 返回。
4. 约 0.22 秒后 `isPlayQuest` 变为 `false`，Quest ID 仍为 `200032001`。
5. 约 1.17 秒后调用 `reqOpenDialogQuestReturn()`。

## 工程结论

- `notifyReset()` 是本版本中已通过真实菜单流程观测到的零参数高层入口。
- `onQuestReturn()` 属于 `notifyReset()` 的内部步骤，不应独立调用。
- 该流程负责安全退出并恢复受理任务前状态，不等同于自动重新接取和加载任务。
- 下一候选只允许在支持版本、单人、目标陪练任务、非加载状态下调用 `notifyReset()`。
- 自动重新接取与出发必须作为后续状态机，在确认返回据点后执行；不得将未观测的 Load 方法串联猜测。

## 已否决方案

直接反复调用 `via.Transform.set_Position/set_Rotation` 恢复猎人位置，在第三次实机重置时触发原生 `c0000005`。该路径永久禁用，不作为回退。
