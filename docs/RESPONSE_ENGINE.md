# 武器上下文应对引擎

## 决策结论

`Response` 不再被定义为怪物招式上的固定文案。最终提示由怪物威胁、玩家当前武器、红/蓝替换技书、装备技能、实时资源和动作状态共同决定。静态建议仅在玩家状态不可读或尚未支持该武器时降级使用。

官方《曙光》说明每套红/蓝替换技书各保存五个替换技，并允许任务内切换：<https://game.capcom.com/manual/Multi-Platform/en/xone/page/10/2>。因此只读取任务开始时的配装不够，必须读取当前书及两套配置。

## MVC 职责与依赖

- Runtime：只读获取武器类型、当前替换技书、两套替换技、武器资源、翔虫、玩家动作和装备技能；把游戏枚举转换为稳定语义。
- Model：持有 `PlayerCombatState`，组合怪物上下文并调用纯规则；不依赖 REFramework 对象。
- `response_long_sword.lua`：首个具体规则入口。输入符合契约的两个状态，返回排序后的候选，不读游戏对象、不绘制 UI。
- Controller：编排采样和更新，不复制领域状态。
- View：显示推荐、不可用原因、时机与风险，不自行判断技能条件。

只有第二种真实武器实现后，才从具体入口提取武器分发注册表。

## 数据契约

### `MonsterMoveContext`

- `state_key`：必填，规范形式 `ActionCategory:ActionNo`。
- `phase`：`startup | active | recovery | unknown`。
- `hit_profile`：`single | multi | projectile | roar | unknown`。
- `tracking`、`direction`、`guardability`、`startup_frames`、`active_frames`、`recovery_frames`：未知时显式为 `unknown`/`nil`，不得猜测。
- `branch_certainty`：`fixed | conditional | random | observed | unknown`。

### `PlayerCombatState`

- `weapon_type`：稳定语义，例如 `long_sword`，不向 Model 暴露游戏数字枚举。
- `active_scroll`：`red | blue | unknown`。
- `switch_skills.red/blue`：各五个稳定技能 ID；不可读时返回带原因的 unavailable 状态。
- `resources`：太刀气刃槽、刃色、翔虫数量与冷却等实时资源。
- `action_state`：当前动作、是否可取消、武器是否出鞘；只使用已验证字段。
- `equipment_skills`：技能稳定 ID 到等级，例如 `quick_sheathe = 3`。
- `distance`、`facing`：相对怪物的距离和方向。

Runtime 读取失败必须返回可观察的 `unavailable_reason`；不得把未知替换技当成默认技能。

TDB 71 当前实机证据：`_playerWeaponType = 2` 且武器控制器类型为 `snow.player.PlayerWeaponCtrlLS_Sword` 时转换为 `long_sword`。必须同时满足两个证据，单独遇到 raw `2` 或相似类型名时保持 unknown；其他武器的 raw 映射在真实实现前不预填。

太刀资源白名单来自两个成熟开源实现：Bimmr 的 Buffer 在 `snow.player.LongSword.update` 中使用 `_LongSwordGauge` 与 `_LongSwordGaugeLv`；MHR Overlay 使用 `get_LongSwordGaugeLv()`。本项目只读这些成员，并优先使用 getter、字段作为兼容回退：<https://github.com/Bimmr/Monster-Hunter-Rise-Reframework-Scripts-/blob/main/Buffer/autorun/Buffer/Modules/LongSword.lua>、<https://github.com/GreenComfyTea/MHR-Overlay/blob/main/reframework/autorun/MHR_Overlay/Buffs/weapon_skills.lua>。

### `ResponseCandidate`

- `action`：稳定语义，如 `foresight_slash`、`iai_spirit_slash`、`spirit_helmbreaker`、`evade`。
- `availability`：`available | wait | unavailable | unknown`。
- `timing`：简短时机语义，如 `during_startup` 或 `after_recovery`。
- `reason`：推荐或不可用的具体原因。
- `risk`：`low | medium | high | unknown`。
- `required_resources`：消耗或前置资源。
- `input_action`：语义输入，不写死键盘或手柄按钮；输入适配层负责显示实际绑定。

候选按“当前可执行性 → 生存可靠性 → 训练目标 → 输出收益”排序。追击技与防御技分开：登龙只能在确认收招窗口后成为追击推荐，不能替代当前攻击的防御提示。

## 太刀 MVP 规则范围

首版只覆盖：见切斩、特殊纳刀＋居合拔刀气刃斩、神威居合、飞翔踢＋气刃兜割、樱花铁虫气刃斩和普通回避。

- 未装备特殊纳刀时不得提示居合拔刀气刃斩。
- 当前书没有飞翔踢、翔虫不可用或刃色不满足时，登龙必须显示不可用原因。
- 多段攻击或固定后续尚未结束时，不把高承诺追击排在保底应对之前。
- 纳刀术等级只影响经实测验证的准备窗口；未建立时间模型前不得声称“来得及居合”。
- 玩家动作不可取消时，见切显示为 `wait/unavailable`，不能只根据气刃槽推荐。
- 所有武器规则失败时降级为怪物包的通用站位/回避建议，并明确标记“武器状态不可用”。

## 实施顺序与验收

1. 静态知识：优先导入官方手册、Kiranico 与 MHRice 已有的招式、交换技和技能目录，记录来源与数据版本；不在游戏内重新枚举这些静态名称和说明。
2. 最小运行时读取：只读取当前武器、当前书、当前书的五个交换技、太刀槽/刃色、翔虫、动作可取消状态和确实会改变时机模型的装备技能等级。新字段必须先有明确用途和精确白名单，禁止全量枚举技能记录。
3. 证据快照：把原始字段与转换后的稳定语义写入有界诊断 JSON，方便一次实机确认。
4. 纯规则：先用构造状态测试上述六种太刀候选及所有不可用原因。
5. Overlay：显示一条当前推荐、最多两条备选及原因；可独立关闭武器建议。
6. 实机门禁：至少覆盖红/蓝书切换、特殊纳刀/神威居合互斥、翔虫 0/1/2、不同刃色、动作不可取消和多段攻击。

首版不自动执行玩家动作，不修改替换技或装备，不将一次成功应对直接解释为规则正确。
