# 冰牙龙离线 AI 提取证据（2026-09-03）

## 目标与边界

本轮用于验证第二只真实怪物能否复用既有数据管线和 Profile 契约，不启动游戏、不写入游戏目录，也不把离线静态边直接升级为可执行陪练场景。

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

因此该数据包标记为 `research_only`，动作名称标记为 `offline_static_candidate`，公开训练场景保持为空。下一阶段只需对少量高价值起手做批量运行时关联，而不再要求玩家逐招猜测全部动作。

## 参考

- HunterPie 怪物 ID：<https://github.com/HunterPie/HunterPie-legacy/blob/master/HunterPie/Languages/en-us.xml>
- mhrice（优先核对游戏数据结构；当前不输出 Action/FSM/Think 行为图）：<https://github.com/wwylele/mhrice>
