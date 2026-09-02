# 冰牙龙离线 AI 提取证据（2026-09-03）

## 目标与边界

本轮用于验证第二只真实怪物能否复用既有数据管线和 Profile 契约，不启动游戏、不写入游戏目录，也不把离线静态边直接升级为可执行陪练场景。

`0.50.1` 增加独立 Quest ID `200042001` 与任务驱动的自动 Profile 选择。切换会清理旧目标、锚点和逐怪证据，并将 F7 重开目标同步到当前任务；冰牙龙仍保持 `research_only`，没有训练场景，Controller 和 Runtime 均拒绝强制 Action。本阶段只完成离线合同，尚未部署到真实游戏。任务倍率表沿用已验证的普通 MR 陪练基线，目的是提供稳定观察节奏，并非声称复刻某一原版冰牙龙任务；发布前必须集中验证任务加载、目标生成、自动选包和 F7 重开。

`0.50.2` 将上述发布前门禁实现为 `profile_acceptance` 自动会话。外部包装器只接受显式目标 Quest ID 与预期 Profile ID；游戏侧再次用注册任务白名单约束目标。会话稳定后先验证 Profile 和怪物已加载，再调用受限探针证明 `research_only` 在进入原生 Action 写入前拒绝请求，随后复用已验证的 QuestRestart 状态机重开并核对同一 Profile 与目标恢复。离线状态机测试已覆盖该完整合同。

真实会话 `bdf3682927d841d08acdd2b03277cc3d` 已无人值守完成：首次进入与原生重开后均得到 `profile_id=barioth_mr_normal`、`target_found=true`；受限 Action 19 请求返回 `This monster profile is research-only; forced actions are locked`，证明没有落到原生 Action 写入。完整报告位于本地忽略目录 `artifacts/probe_reports`，SHA-256 为 `5A1415CE5CF0D127CB80254AD1CD047FB6CC95F621FDACCED048767C03847110`。同一报告额外确认运行时 Think Action 类型为 `Em042_00ActionSetMove`，当前树包含 Move Action 18/19/20 与 Fly Action 5，未用于提升静态攻击派生可信度。

怪物标识为 `em042_00`（Barioth / 冰牙龙）。身份交叉参考 HunterPie 的怪物 ID 语言表；资源与行为事实来自用户本机 Steam `16.0.2.0` 游戏 PAK，而不是从第三方仓库复制。

## 自动化结果

- 文件列表中的 `em042/00/ai_fsm_user_data` 入口：128 个；
- 按资源引用闭包提取：591 个文件；
- 未解析引用：0；
- RSZ 解码：591 成功、0 失败；
- 行为图：591 个含状态文件、4,123 个状态、5,318 条转换；
- 动作号：41 个；
- 保守 `EnemyActionEnd` 直接边：11 条，0 诊断；
- 过滤为普通 `action/combo` 范围后保留 3 个根动作：`33 -> 34`、`35 -> 5005`、`5005 -> 5002`。

完整 PAK、`.user.2`、RSZ dump 和完整行为图只保留在本地研究目录，不提交、不打包。仓库只保留压缩后的候选数据及来源路径。

## 证据解释

唯一 `EnemyActionEnd` 边能够证明对应静态状态内存在唯一直接后继，但不能证明：

- 运行时 Action category 与编号在当前怪物实例上完全一致；
- 该动作能从安全空闲状态请求；
- 起手动作的中文战斗语义；
- 距离、形态、部位破坏或飞行状态等进入条件；
- 可重复训练与失败恢复安全。

因此该数据包标记为 `research_only`，初始占位名称标记为 `offline_static_candidate`，公开训练场景保持为空。下一阶段只需对少量高价值起手做批量运行时关联，而不再要求玩家逐招猜测全部动作。

随后从社区 `Barioth / EmAttackNo` 目录补齐了这 5 个动作的枚举语义。名称证据与派生证据保持分离：目录名称不会把 `research_only` 升级为实机可信。当前优先候选为：

1. `35 FullPowerTailAttackStartTurn -> 5005 FullPowerTailAttackStartJump -> 5002 FullPowerTailAttackFirstAttack`：高价值完整起手链，适合验证跳跃与部位状态上下文。
2. `33 TurnAttackWallBreak -> 34 TurnAttackWallLoopAndEnd`：依赖墙面/破坏态的条件型候选，用于验证复杂环境条件，不作为首个强制入口。

## 上层上下文复核

`em042_act_200` 内存在两套独立但同构的状态路径：

- State `20 -> 21 -> 9`：Action `35 -> 5005 -> 5002`；
- State `23 -> 22 -> 8`：Action `35 -> 5005 -> 5002`。

每一步均只有一条 `EnemyActionEnd` 后继，因此链内顺序可信；两套状态说明同一动作链可从不同上层上下文进入，不能把单一 StateNo 当作唯一身份。

引用该动作表的 `combo_033` 至 `combo_036` 进一步给出三类进入条件证据：目标距离阈值 `10/13/15/16/28`、左右翼部位破坏检查，以及普通/愤怒的 Range2/Range3 例程引用。由此确定下一次运行时批量验收至少要覆盖：

1. 普通状态，中距离带；
2. 愤怒状态，中/远距离带；
3. 至少单侧翼破坏后的分支。

这些条件只用于构造候选矩阵；尚未确认 `_DistanceType=0` 的运行时度量与条件优先级，因此暂不写入可执行 `TrainingScenario`。

## 参考

- HunterPie 怪物 ID：<https://github.com/HunterPie/HunterPie-legacy/blob/master/HunterPie/Languages/en-us.xml>
- mhrice（优先核对游戏数据结构；当前不输出 Action/FSM/Think 行为图）：<https://github.com/wwylele/mhrice>
