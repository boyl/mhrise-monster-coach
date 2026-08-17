# AutoQuest 一键任务重开研究

## 结论

Monster Coach 的一键任务重开采用游戏高层流程，不写猎人或怪物 Transform：

1. 已实机验证的 `snow.QuestManager.notifyReset()` 返回据点。
2. `LobbyFacilityUIManager.activateOnly(QuestCounter)` 激活任务柜台。
3. `GuiQuestCounterFsmCreateQuestSessionAction` 驱动游戏原生接取流程；选择 Hook 只返回 Profile 中固定的陪练 Quest ID。
4. 接取成功后关闭柜台，并通过 `GuiManager.get_refQuestStartFlowHandler().requestGoQuest(true)` 自动出发。

AutoQuest 不是在 `isPlayQuest=false` 后立刻打开柜台：它检测玩家状态从 `Quest` 进入 `Lobby`，再等待约 10 秒。Monster Coach 同样要求 `GameStatePlayer.Lobby`、柜台可调用且任务未激活连续稳定约 10 秒，避免在场景卸载/据点初始化期间过早创建柜台 FSM。

`activateOnly(QuestCounter)` 只发出激活请求，`GuiQuestCounterFsmManager` 会在后续帧异步创建。状态机必须保持在 `START_SESSION` 等待实例出现，不能把首帧的 `nil` 当作失败；只有阶段超时才终止。

流程由有界状态机执行，重复 F7 被拒绝；多人、非目标任务或不支持运行时禁止启动；任一阶段失败或超时会关闭临时柜台 UI 并停止，不自动重试。

## 来源与边界

- 研究来源：[AutoQuest](https://github.com/kmy0/AutoQuest) 的公开 `routine_post.lua` 与 `hook.lua`。
- 只内化必要的引擎 API 与状态顺序，没有引入 AutoQuest 依赖，也没有复制其完整功能、配置或数据模型。
- AutoQuest 仓库未发现明确 LICENSE，因此本仓库保留独立实现和来源说明，不复制发布其源码文本。
