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

- `model.lua` 只处理训练状态、动作转换、派生语义和有界历史，不调用游戏 API。
- `runtime.lua` 集中隔离类型名、字段、方法、输入、TimeScale、位置与生命操作。
- `runtime.lua` 通过 `EnemyManager.getBossEnemyCount/getBossEnemy` 轮询专用任务中的大型怪物，不挂钩 `EnemyCharacterBase.update`。
- `action_reader.lua` 是游戏版本变化最大的边界，优先沿怪物继承链查找明确白名单中的零参数 Getter 或字段。直接成员不可用时，只枚举已知只读对象 `EnemyActionParam` 的成员定义，并且只读取 ActionNo/ActionID/ActionCategory 精确白名单字段或调用精确白名单零参数 Getter；枚举出的其他方法只记录名称，不执行。仍不可用时才降级为 `via.motion.Motion` 第 0 层的 `MotionBankID:MotionID` 状态键，并复用一个 `via.motion.MotionInfo` 查询名称和结束帧；脚本重载时释放该实例。诊断必须分别标记 `action_param_field`、`action_param_method` 或 `motion`。
- `view.lua` 只消费 Model 和屏幕尺寸，不决定固定/随机派生。
- `controller.lua` 拥有输入边沿、单人安全门、生命周期和用例编排。
- `profile_tigrex.lua` 与校准 JSON 保存怪物知识；原始 Action ID 不散布在业务代码中。

## 稳定契约

### MonsterFrameState

当前 MVP 输出 `enemy_id`、`action`、任务/联机状态、玩家生命与动作开始时间。距离、朝向、形态和怒气待相应 Getter 获得真实运行时证据后加入 Runtime 输出；不得由 Model 猜测。

### MoveDefinition

- 输入：Action 字符串键、名称、短名称、应对建议、派生类型和候选列表。
- 不变量：`fixed` 只能有一个经验证的候选；观测数据不得升级为 `fixed`。
- 未知动作：显示 raw Action 并进入有界未知集合，不影响游戏。
- 自动名称：已校准名称优先；否则可显示 `MotionInfo` 返回的开发者名称，但其确定性只能标记为 `engine_name`，不能自动当作已确认的战斗语义。

### 自动采集与低成本标注

- 每帧只查询当前状态，不扫描 MotionBank，也不枚举类型成员。
- `observed_state_metadata` 保存状态键到 Motion 名称、Bank/ID 和结束帧的映射；`observed_history` 保存有界的时序与持续时间；`observed_transitions` 保存聚合派生。
- 首次实机采样用于验证引擎名称质量。确认有效后，再基于名称、连续时间线和重复派生自动聚类候选招式；玩家只确认少量中文语义，不采集视频证据。
- 自动名称查询失败时退化为原始状态键和时间线，不中断实时观察。

### 离线怪物数据管线

- `extract_monster_ai.py` 是 PAK/文件列表边界，只选择目标 `emXXX` 的 AI 入口并计算资源引用闭包；不同怪物 ID 和变体是输入值，不进入 Mod 业务代码。
- `rsz_ai_dump` 是第三方 RszTool 的薄适配器，只输出实例类型、字段、值和引用 ID；领域层不依赖 RszTool 对象。
- `build_monster_behavior_graph.py` 只消费结构化 RSZ JSON，输出稳定的 ThinkState、Action、Condition 和 Transition 契约。`fixed_action_edges` 采用保守证明规则：当前状态只有一条 `EnemyActionEnd` 边，且两端各有一个该怪物的编号攻击 Action。这样更换 REasy、RszTool 或新版 RSZ dump 时，不影响 Mod 的 Model/View/Controller。
- 原始 PAK、解出的 `.user.2` 和完整 RSZ dump 仅留在本地研究目录，不提交、不打包、不发布。

### BranchPrediction

- `fixed`：来自校准数据的确定派生。
- `conditional` / `random`：来自校准数据的候选及条件。
- `observed_single` / `observed_candidates`：来自本次会话计数，只描述观察结果。
- 样本不足时返回空预测并显示“正在采集”。

### TrainingScenario

后续强制出招场景的数据结构放在怪物校准包中，但在以下四项齐全前不得执行：已验证 Action、已验证请求方法、前置状态检查、安全空闲状态。首版场景列表为空，因此 UI 明确显示锁定原因。

## 新增怪物的最小改动

已确定会变化的只有三条边界：怪物知识、游戏运行时、训练场景。新增怪物时：

1. 增加一个与 `profile_tigrex.lua` 同契约的数据包和独立校准 JSON。
2. 在组合根选择目标 Profile；Model、View、Controller 不接触原始怪物 ID。
3. 运行同一套 Model 契约测试，再增加该怪物的固定/条件/随机派生测试。
4. 只有第二个真实 Profile 落地时才提取 Profile Registry，避免当前提前构建插件系统。

新增游戏版本时只改 `runtime.lua`/`action_reader.lua` 的显式版本分支，并保留 16.0.2.0 分支。未知版本默认只读校准，不自动沿用写操作。

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
| 禁用 | 联机任务或运行时指纹不匹配 | 明文说明写操作禁用 | 只读观察、退出 | 立即恢复 1.0x |
| 错误 | 回调异常 | 显示带阶段的错误 | 查日志、重载 | 立即恢复 1.0x；保留配置 |

## 生命周期与内存边界

- 所有回调只在入口加载时注册一次。
- Action 历史最多 256 条，学习源动作最多 128 个；未知集合受学习上限间接约束。
- 屏幕绘制不构建目录、不读写 JSON、不扫描元数据。
- 脚本重置、联机切换、离开任务和 REFramework 设置界面打开时恢复 1.0x。
- 配置只在实际变化或 REFramework 保存时写入；脚本重置只做清理。
