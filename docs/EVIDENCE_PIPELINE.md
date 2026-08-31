# 怪物行为证据流水线

## 目标

开发探针只负责采集运行时事实；离线分析器只负责生成候选；怪物数据包负责审核后的产品语义。三层不得相互替代。

## 数据流

1. `run_probe_session.ps1` 完成或失败时，先把原始报告复制到 `artifacts/probe_reports/<session>.<kind>.<status>.json`。
2. 自然行为调查交给 `analyze_behavior_survey.py`，从中提取攻击起手和下一攻击候选，并与怪物数据包已有边交叉验证。
3. 训练场景验收交给 `analyze_training_timeline_acceptance.py`，统一审核轮次完成、事件连续性、判定窗、结果分类、证据等级和完成依据；ActionNo 真实变化使用 `action_transition`，ActionNo 粘滞但攻击树退出使用 `behavior_tree_attack_exit`，其他值全部拒绝。
4. 带 `-TrainingResponseStep` 的自动验收另存同名 `.response.json`：它只证明外部白名单输入在某一轮发送过；分析器仍必须在原始游戏时间轴中找到预期玩家状态，二者会话、场景和轮次全部一致才通过。
5. `run_core_acceptance.ps1` 在同一游戏进程和同一任务中顺序调用上述安全单场景执行器，再由 `analyze_core_acceptance.py` 聚合审核；它不另建 Lua 批量状态机，也不把一个场景的状态带入另一个场景的证据合同。
6. 未被怪物包审核的边始终输出为 `observed_next_attack_candidate`，无论出现多少次。
7. 只有静态 Think/FSM 结构与自然运行时证据共同支持后，才允许在怪物包中声明 `fixed` 或 `conditional`。
8. 强制 Action 探针仅验证起手能否安全进入和退出，不用于证明后继关系。

## 离线分析

```powershell
python tools/analyze_behavior_survey.py `
  artifacts/probe_reports/<report>.json `
  reframework/data/MHRiseMonsterCoach/tigrex_static_ai.json `
  --output artifacts/probe_reports/<report>.analysis.json
```

`artifacts/` 被 Git 忽略。值得长期保留的结论需提炼为 `docs/evidence/` 下的小型证据文件，不提交包含易变内存地址的整份运行时报告。

`run_probe_session.ps1 -TrainingScenarioId <id>` 在归档终态报告后会自动生成同名 `.analysis.json`；`-ResumeExisting` 恢复终态时也执行同一分析，不重新发送输入。分析结果把 `violations` 与 `coverage_gaps` 分开：前者表示证据契约不可信，后者表示结构可信但缺少完整判定窗或行为树退出证据。

训练终态绑定 `training_timeline.last_round`，不要求整个实时观察器停止。目标轮通过白名单完成依据结束后，Model 可以立即开始观察不同 `state_key` 的下一动作；分析器将其标记为 `post_round_observation_active=true`。活动时间轴仍属于刚完成的目标 `state_key`、缺少活动起点或状态键不可核对时，继续以 `target_timeline_still_active` 失败关闭。

首个玩家响应验收命令为 `run_probe_session.ps1 -TrainingScenarioId tigrex_rotate_attack_right_single -TrainingRepeatCount 1 -TrainingResponseStep dodge`。该模式拒绝 `-ResumeExisting`，因为“本进程是否已对该轮发送输入”是实现至多一次语义的必要状态，不能从旧报告猜测恢复。

轰龙 MVP 集中门禁使用 `run_core_acceptance.ps1`。默认计划来自 `tools/tigrex_core_acceptance_plan.json`，每个场景必须已经在怪物数据包标为 `verified`，并且请求轮数不得超过其 `max_verified_repeats`。第一项完成部署与启动，后续项传递 `-SkipDeployment` 并复用运行中的游戏；子项失败后立即停止，避免自动重试把第一次失败覆盖掉。批次摘要与统一分析位于 `artifacts/core_acceptance/<batch-id>/`。全部 8 项都必须完成、合同有效并产生显式结果等级；Native 判定窗采用计划声明的代表性最低覆盖数，因为投石等投射物判定不一定出现在怪物本体 Provider。`unclassified` 是不可计分但合法的证据等级，不会被伪装成成功。

## 不变量

- UI 探针不得覆盖尚未归档的自然调查证据。
- 频率不是概率，单一高频后继也不是固定派生证明。
- 跨 `Normal.Search` 的下一攻击默认只是候选，除非上层 Think/FSM 明确证明属于同一连段。
- 未解析条件必须显示“条件尚未完全解析”，不得猜测距离、怒气或边界阈值。
- `observed_hit`、社区成功候选和动作尝试不可计分为成功；只有生命追踪或已验证成功节点满足对应证据契约时，分析器才输出 `scoreable=true`。
