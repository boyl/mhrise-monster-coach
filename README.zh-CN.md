# 《怪物猎人崛起》怪物陪练 Mod

版本：`0.5.3-action-catalog-candidate`

> 2026-08-16 安全通告：实机出现原生访问冲突后，本版本默认进入只读诊断模式，不安装怪物 Update Hook，也不执行时间、生命或位置写入。只读模式仅通过 `EnemyManager` 轮询目标怪物，并尝试读取白名单中的 Action Getter/字段。

## 专用陪练任务候选

本包新增一个由 RiseQuestLoader 加载的静态自定义任务：

- 名称：`[陪练] 轰龙·塔之秘境`
- Quest ID：`200032001`
- 入口：集会所任务 → 大师等级 → 4★ → 任务列表最后
- 地图：塔之秘境（Map 14）
- 目标：普通大师等级轰龙一头（Monster 32）
- 任务奖励：金钱、点数和 HRP 均为 0
- 限制：单人测试；不得在公开联机大厅使用

当前菜单只显示已支持的这一项任务和当前 Quest ID，不会调用未经验证的“立即开始任务”方法。任务 JSON 已通过结构测试，但仍需第一次真实加载验证出生点、寻路和退出流程；在验证完成前称为候选任务。

RiseQuestLoader 会先生成原版任务列表，再追加完全自定义任务；本 Mod 在该调用链完全返回后的下一次更新中，仅把已登记的陪练 Quest ID 移到所有其他自定义任务之后。因此每个陪练任务保留怪物所属星级，并进入该星级任务列表末尾；同星级有多个陪练任务时，它们按登记顺序共同组成末尾的陪练任务区。

这是一个面向 Steam PC《怪物猎人崛起：曙光》的 REFramework Lua MVP。当前版本优先解决两个痛点：

1. 在同一任务内恢复猎人与怪物生命、回到预设位置，减少结算、回大厅、接任务和重新加载地图的次数。
2. 实时记录轰龙 Action 转换，显示当前动作、观测到的后续候选、按住减速和本轮是否受击。

## 当前能力边界

- 已实现：单人专用任务检测、通过 `EnemyManager` 轮询轰龙、白名单 Action 读取器、`via.motion.Motion` 状态键后备读取、引擎 Motion 名称与结束帧自动提取、未知动作记录、观测派生学习和提示 Overlay。时间倍率、生命与位置功能保留在代码中，但只读诊断模式下不会执行。
- `MotionBankID:MotionID` 只表示当前播放动作的校准状态键，不冒充已经确认的 AI/FSM Action ID；它可用于首版招式名称、变化与应对提示映射。
- 校准导出使用 schema v3，包含有界的按时间排列状态历史、前一状态持续时长、聚合转换图，以及每个状态键对应的引擎 Motion 名称和结束帧。只读模式不再生成虚假的“无伤、成功或连胜”结果。
- 兼容门禁：当前包只允许 `mhrise / TDB 71` 执行时间、生命和位置写操作；其他运行时仍可显示诊断，但自动进入只读状态。
- REFramework 未提供 `imgui.text_wrapped` 时，设置界面自动回退到普通文本，并对相同回调错误限流，避免逐帧刷日志。
- 需要实机校准：当前游戏构建实际暴露的 Action getter/field、Action ID 对应的中文招式名、前摇阶段和应对说明。
- 尚未开放：强制指定怪物招式。公开资料不足以证明当前 16.0.2.0 构建的安全请求入口；猜测入口或 ID 可能造成冻结、T-Pose 或崩溃。
- 原地重置恢复生命与位置，但不会伪造“AI 已回到绝对初始节点”。怪物当前动作结束后再按 F7 最稳定。
- 不包含自定义异常调查或奖励数据，也不写存档。

这一区分很重要：代码、打包和自动测试通过，不等于已经在真实任务中验收。

## 安装

前置条件：

- Steam 版《怪物猎人崛起：曙光》；
- REFramework；
- 建议备份存档；
- 只在单人任务中使用。

把本目录中的 `reframework` 文件夹复制到游戏根目录，与现有 `reframework` 文件夹合并。入口最终应位于：

```text
MonsterHunterRise/reframework/autorun/MHRiseMonsterCoach.lua
```

Mod 检测到联机任务后会禁用时间控制、生命修改、位置重置等玩法写操作。

## 自动校准流程

1. 进入单人轰龙任务，靠近轰龙。
2. Overlay 显示 `Calibrating the action reader` 后正常观察/应对；Mod 自动读取状态键、引擎 Motion 名称、结束帧、持续时间和后续状态。
3. 在希望作为重置起点的位置按 F8，保存猎人与轰龙的位置锚点。
4. 按住 F6 进入 `0.25x`，松开立即恢复 `1.00x`。
5. 按 F7 原地恢复生命、耐力、怪物生命和双方位置。
6. 打开 REFramework → `Script Generated UI` → `Monster Coach`。若 `Engine Motion` 有值，说明自动命名入口有效；点击 `Export calibration evidence` 保存结果。

生成文件：

- `reframework/data/MHRiseMonsterCoach/tigrex_calibration.json`：实际观察到的状态、引擎名称、时间线和转换计数。
- `reframework/data/MHRiseMonsterCoach/runtime_action_param_probe.json`：只包含 `EnemyActionParam` 类型成员名称与最终白名单选择，用于自动诊断 ActionNo 桥接；不包含游戏资产。
- `reframework/data/MHRiseMonsterCoach/runtime_action_state.json`：只读诊断模式下在 ActionNo 或 Category 改变时更新，保存最近 256 个 ActionNo、ActionCategory 和同帧 Motion 名称，开发侧可直接读取而无需玩家录屏或手工导出。
- `tools/analyze_runtime_evidence.py`：直接汇总上述自动证据中的攻击 Action、Motion 聚类和相邻攻击边；用于把每轮实机样本并入分析，不要求玩家逐条观察或手工导出。
- `tools/deploy_dev.ps1`：开发版自动部署器。可等待游戏正常退出，按白名单安装并逐文件校验 SHA-256，保留配置、校准和运行证据，并可通过 Steam 自动重启游戏。

设置界面的 `Reload static AI data` 可在任务内重新载入 `tigrex_static_ai.json`。招式名称、提示和静态派生数据更新后不需要退出游戏；只有修改底层 Lua 读取器、生命周期或 Hook 时才要求完整重启。

不再要求玩家录屏、截图或人工对时。引擎名称通常是开发用标识符，并不保证能直接翻译为准确招式语义；后续工具只需让玩家从自动聚类出的少量候选中确认“冲锋/吼叫/甩尾”等中文名称和应对建议。

如果自动读取器没有找到变化值，先记录界面的 `Reader` 与日志，不要自行猜测成员名。只有经 Object Explorer 人工确认是零参数只读成员后，才在 `config.json` 中把 `action_reader.kind` 改为 `method` 或 `field` 并填写 `name`；不要填写动作执行函数。

## 操作

| 操作 | 默认按键 | 行为 |
|---|---:|---|
| 按住减速 | F6 | 单人任务内设置场景为配置倍率；松开恢复 1.0 |
| 原地重置 | F7 | 恢复资源、怪物生命及双方位置 |
| 捕获锚点 | F8 | 保存当前猎人与轰龙位置 |
| 设置界面 | Insert | 打开 REFramework 的 Script Generated UI |

生命保护默认开启。它会检测生命下降、记录本轮受击量，然后恢复生命；这能显著减少猫车和重新接任务，但“未受伤”结果目前只代表没有检测到生命下降，不代表识别了武器专属 GP、看破、居合或防御判定。

## 为轰龙标注招式

### 离线 AI 提取（开发流程）

`tools/extract_monster_ai.py` 使用 MHRise 文件列表和 RETool，从指定怪物的 `ai_fsm_user_data` 开始递归追踪 UTF-16 资源引用，只提取该怪物实际依赖的 Action、Combo、Routine 等 `.user.2` 文件。它不会完整展开游戏 PAK，也不会把原始游戏资源写入仓库。

`tools/rsz_ai_dump` 通过外部 RszTool 项目和 `rszmhrise.json`，把已提取文件批量转换为结构化 RSZ JSON。构建时必须显式传入 `-p:RszToolProject=...`；项目不内置或分发第三方解析器、Capcom 文件和 RSZ dump。

需要离线分析攻击碰撞体时，先为 RszTool 0.3.5 应用 `tools/rsz_ai_dump/patches/RszTool-0.3.5-mhrise-rcol.patch`，再向导出命令追加 `--include-timing-assets`。该模式会导出 RCOL 分组、形状、RequestSet 和内嵌 RSZ；导出失败会写入带异常类型、RCOL 头和调用栈的 manifest，不会静默跳过。

`tools/build_monster_behavior_graph.py` 再把结构化 RSZ JSON 转为与解析器无关的行为图，保留 ThinkState、动作实例、条件、下一状态与资源来源。它只把“唯一 `EnemyActionEnd` 边，且起点和终点都各有一个轰龙攻击 Action”的关系列入 `fixed_action_edges`；距离、角度、随机或多边状态不会被误报成固定派生。传入 `--runtime-pack-output` 和实机确认的攻击 Category 后，可自动生成 Mod 使用的紧凑静态派生包。

当前开发实测从 140 个轰龙入口文件收敛到 424 个引用闭包文件；424 个文件全部解析成功，得到 3,090 个状态、3,920 条条件边、48 个 ActionNo 和 14 条严格固定攻击边，诊断为 0。原始文件和约 3.7 MB 的研究图只保存在本地 `work` 目录，不进入 Mod 包。此结果属于静态结构证据，招式中文语义和运行时 ActionNo 对接仍需独立验证。

TDB 71 实机已确认 `EnemyActionParam.get_ActionNo()` 与 `get_ActionCategory()` 可安全轮询，攻击 Category 为 4。领域状态键必须是 `(ActionCategory, ActionNo)`，显示为 `4:26`；不同 Category 下相同的 ActionNo 不得共享招式名称、派生学习或应对提示。运行时只在 Category 4 下查询 `tigrex_static_ai.json`。15→2 已累计 5 次、18→2 已累计 4 次实机一致观测，16→2 保留静态唯一边但尚未在实机遇到；2 和 24 因实机后继超出局部 FSM 边而被撤下，避免把缺少上下文的局部图冒充全局预测。

轰龙攻击枚举名称优先采用社区从游戏数据整理的 [`Monster Action IDs (P–Z)`](https://github.com/mhvuze/MonsterHunterRiseModding/wiki/Monster-Action-IDs-%28P-%E2%80%90-Z%29)，不再通过 Motion 名人工猜测。该表解决 `EmAttackNo → 内部英文名`，但不证明攻击阶段、判定帧、条件派生或最佳应对；这些仍分别来自静态 AI 解析和实机验证。来源优先级为：社区/游戏枚举名 → 可读引擎 Motion → `未命名攻击 (Category:Action)`，任何降级都保留原始键。

校准文件中的 `moves` 以 Action 字符串为键：

```json
{
  "moves": {
    "123": {
      "name": "三连冲锋·起手",
      "short_name": "冲锋起手",
      "advice": "保持侧向移动，确认转向后再处理下一段。",
      "next_kind": "fixed",
      "next": [
        { "action": "124" }
      ]
    }
  }
}
```

只有从 FSM/AI 文件或大量实测确认唯一下一段时才使用 `fixed`。距离、怒气或随机权重会改变结果时应使用 `conditional` 或 `random`，并写明条件。纯观测学习只会显示 `observed_single` 或候选概率，不会冒充固定派生。

## 卸载与异常恢复

- 删除 `reframework/autorun/MHRiseMonsterCoach.lua` 和同名子目录即可卸载。
- 配置和校准记录位于 `reframework/data/MHRiseMonsterCoach`，可选择保留。
- 脚本重载会主动恢复 `1.0x`。若游戏或 REFramework 本身异常退出，再次进入任务前确认速度正常。
- 若启动异常，先移除本 Mod 并检查 `re2_framework_log.txt`；不要删除其他用户 Mod 或配置。

## 验证状态

- 已完成：模块边界、JSON、Lua 语法、纯 Model 状态机自动测试和包内容审计。
- 未完成：真实游戏加载、轰龙 Action getter 确认、20 次原地重置、100 次动作转换、暂停菜单恢复、各种武器受击结果和强制出招。

详细扩展契约与验收矩阵见 `docs/ARCHITECTURE.md`、`docs/RESPONSE_ENGINE.md` 和 `docs/REAL_GAME_ACCEPTANCE.md`。

## 风险提示

Capcom 不保证非官方 Mod 的兼容性，也不为修改数据造成的故障提供支持。请备份存档、限制单人使用，并在游戏更新后先关闭玩法写操作完成兼容验证。
