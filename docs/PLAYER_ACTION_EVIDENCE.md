# 猎人动作证据层

## 目标

应对建议最终需要知道猎人当前是否处于回避、受击、攻击，以及正在执行哪一个武器动作。该信息必须先成为可复核的只读证据，才能用于“见切成功”“居合成功”等训练结论；不能仅凭未受伤或一次动作节点变化推断成功。

## 当前契约

`player_action_reader.lua` 每次只读采样：

- `PlayerBase.getMotionFsm2()` 的第 0 层当前节点 ID；优先用树的 `get_node_by_id` 只解析当前出现的节点并有界缓存，树支持枚举时才批量建立最多 4096 项的 `node ID → full name` 目录；
- `PlayerBase.isActionStatusTag(ActStatus)` 的 `Attack`、`Escape`、`Damage`、`Jump`、`WireJump`、`Ride` 与可用时的 `Guard` 标签；
- 采样来源、可用性与缺失字段。

`player_action_observer.lua` 只在节点、标签或玩家武器运行时类型变化时记录事件，默认最多保存 128 项并显式记录丢弃数量。每个事件单独携带 `player_type`，防止切换武器后把旧动作误归入当前武器；离线分析器对旧版无逐事件类型的证据显式标记 `legacy_top_level_fallback`，武器专属知识包与当前玩家类型不匹配时拒绝生成语义映射。完整节点目录也随证据保存；运行时最多每 60 个采样帧落盘一次，稳定帧会冲刷尚未写出的最后变化，避免每个动作转换都写磁盘。`runtime_player_combat_state.json` 不以动作变化作为落盘键；实时 Model 仍取得每帧内存状态。运行证据写入 `runtime_player_action_evidence.json`，它不是静态数据包，也不会由开发部署覆盖。

`0.49.0` 起，`long_sword_knowledge.json` 可提供版本限定的动作节点候选，`player_action_semantics.lua` 以“最长精确匹配优先、其次最长前缀”的确定性规则解析。当前候选来自公开的 [MHRS Custom GP Frames](https://github.com/AlexQFMM2/MHRS-Custom-GP-Frames) 实现，只参考其只读节点名称与查询接口；本项目自行实现解析，不引入其动作树修改、GP 帧修改或自动反击代码。候选在本机被观察后仍保留来源与 `community_candidate` 状态，直到单独的实机动作验收将其升级。

当前明确不做：

- 不安装 `PlayerMotionControl.lateUpdate` 或伤害计算钩子；
- 不修改伤害返回值、玩家动作或行为树；
- 不把第三方 Mod 的动作哈希直接作为已验证映射；
- 不把 `Escape=true` 自动解释为见切，不把 `Damage=false` 自动解释为反击成功。

## 来源与证据等级

[REFramework](https://github.com/praydog/REFramework) 提供 RE Engine 托管对象反射与 Lua 访问能力。[MHR AutoDodge](https://github.com/Atomoxide/MHR_AutoDodge) 的公开实现证明 `getMotionFsm2()`、`getCurrentNodeID(0)`、`isActionStatusTag(...)` 及 `PlayerMotionControl` 动作字段可在 MHR 运行时访问；本项目只采用这些互操作接口事实，未复制其自动反击逻辑或动作表。该仓库没有可发现的许可证，因此其数字映射只作为研究线索，不进入本仓库。

[MHRice](https://github.com/wwylele/mhrice) 继续作为武器、技能与游戏数据结构的优先静态来源，但其当前代码不提供猎人实时动作语义。因此静态目录与运行时节点关联仍然是两个独立证据层。

[Custom GP Frames](https://github.com/AlexQFMM2/MHRS-Custom-GP-Frames) 的公开实现提供了玩家 Motion FSM 树可通过 `get_node_by_id(node_id):get_full_name()` 直接解析当前节点这一互操作事实。实机证明玩家树可能在当前版本返回 `get_node_count() == 0`，因此本项目采用“当前节点直查、出现后缓存”，不复制其 GP 帧覆盖、行为树跳转或奖励补偿逻辑。

## 后续一次性实机门禁

部署后用一个有界会话同时覆盖站立、普通攻击、翻滚、见切、特殊纳刀、居合与红蓝书切换。若节点全名本身具有稳定语义，离线分析优先直接使用名称；否则才聚类节点/标签转换，再由人工只确认聚类名称，而不是逐帧抄 Action ID。只有重复样本一致、游戏版本匹配且动作上下文明确的映射，才进入独立太刀动作数据包。

条件派生与固定派生不受此层影响：怪物派生树继续完整展示 `fixed`、`conditional`、`random/observed`，猎人动作证据只负责训练结果与武器建议的可信度。

证据生成后运行：

```powershell
python tools/analyze_player_action_evidence.py `
  <游戏目录>\reframework\data\MHRiseMonsterCoach\runtime_player_action_evidence.json `
  --output artifacts\player_action_analysis.json
```

分析器默认加载仓库的 `long_sword_knowledge.json`，同时输出探索性名称关键词候选和严格、版本限定的 `semantic_mappings`。后者会注明动作语义、尝试/成功角色、匹配方式、社区来源以及本机观察次数；本机出现节点不会自动把 `community_candidate` 升级为已验证语义。

分析器汇总目录覆盖、实际节点、标签组合与运行时转换，并按 `foresight/mikiri`、`iai`、`sacred` 等名称词根列出候选。词根命中只用于缩小审核范围，输出明确标记为候选，不会直接写回运行时语义映射。

部署后的确定性门禁使用 `tools/run_probe_session.ps1 -PlayerActionEvidence`。探针自动进入战斗层，只有当前玩家节点 ID 与全名都可读取时才完成；报告同时保存实际武器类型和当前训练时间轴快照。探针只读，不切换装备、红蓝书或技能。任意训练场景验收报告也携带同一时间轴快照，因此判定窗、玩家状态、受击和结果分类可以与起手验收一次采集。

## 自动校准任务与输入采集器

`0.49.11` 增加独立的开发期校准任务 `200032002`，用于自动关联太刀输入与玩家 Motion FSM。它不替换正式陪练任务 `200032001`，也不会进入普通部署清单：`tools/run_player_action_calibration.ps1` 只接受游戏已关闭的前置状态，再暂存校准任务；完成或失败后校验并删除该文件。流程前后都会核对正式轰龙任务 SHA-256 未变化。

校准任务使用普通狩猎任务类型和零生成位，不生成大型怪物、不发放奖励。选择普通狩猎类型是因为 RiseQuestLoader 的公开实现只把 `TOUR` 放入探索任务入口，而 `HUNTING` 会进入普通大师任务列表；任务 ID 仍由 Quest Loader 动态注册。该任务只消除“等待怪物、死亡回营、任务污染”等采样噪声，不作为玩家可见功能分发。

自动采集器的安全边界：

- 先通过同一原生任务发布、自动出发、正常奔跑和原生区域传送链进入古塔战斗层；
- 仅接受官方 Windows 默认键位定义中的白名单键鼠输入，并在每步后读取运行时证据；
- 进入战斗层后保留 12 秒有界稳定期，避免古塔到达动画吞掉首批输入；
- 接受收刀 `wait.main` 与拔刀 `atk.atk_wait.atk_wait_main.atk_wait_main` 两种稳定中间态；
- 只记录实际武器、红蓝书、替换技和动作节点，不选择或写入装备、替换技、生命、伤害、存档与奖励；
- 外层已完成并校验部署时，内层探针复用安装收据，不重复部署。

开发者可在游戏关闭时运行：

```powershell
pwsh -NoProfile -File tools/run_player_action_calibration.ps1
```

当前实机证据已证明：独立任务可被原生接取、自动进入、自动穿越准备区，且在无怪物战斗层读取到实际太刀与红蓝书配置；白名单输入也已产生 `attack`、`escape` 和可读动作节点。上一次完整动作批次受古塔到达动画吞键以及拔刀待机未列入稳定态影响，只完成部分动作，因此仍标记为“启动链已验证、完整语义批次候选”。12 秒稳定期和拔刀待机修复已进入源码，留待下一次集中部署一次性复验，不要求玩家逐招手动标注。摘要证据见 `docs/evidence/PLAYER_ACTION_CALIBRATION_BOOTSTRAP_2026-08-27.json`。

`0.49.12` 进一步把采集后的人工翻阅移出流程。校准脚本会自动生成同名 `.analysis.json`，列出七步完整性、每步相关节点、跨步骤共享节点、单步独占节点与终态候选；任一步缺失、未观察或只有待机节点都会令完整门禁失败。分析结果始终标记为 `input_correlated_candidates_are_not_success_semantics`，不会自动写回正式太刀知识包，也不会把“按下见切/居合组合键”误判成招式成功。

`0.49.13` 根据首轮完整自动运行修正采样边界。运行时事件真实存在于 sample 64–177，但证据文件按最多 60 个采样节流落盘，旧工具用固定 2.2 秒窗口读取，导致前六步被误报为未观察、动作尾部被归到后续步骤。新工具按证据修订动态等待，并要求观察到相关节点、期望标签且动作重新进入稳定态后才封闭当前步骤。第二轮证明动态等待能隔离后四项，但正常 60 采样刷新仍会令简单动作超过外部超时；最终实现只在临时、无怪物的校准 Quest ID 中把刷新间隔降为 5，退出该任务立即恢复 60。分析器同时拒绝 WindowsApps 的 Python 占位入口，只接受可执行的仓库虚拟环境、Codex 运行时或真实系统 Python。

第三轮实机在 `0.49.13` 上完成 7/7 输入传输与步骤隔离，但语义门禁仍为 `partial`：首次左键只执行拔刀，固定延迟后的复合键只产生普通 `atk_101/102/106`，没有出现已知的见切 `atk_147`、特殊纳刀 `atk151.atk_152` 或居合气刃斩 `atk151.atk_155`。该结果被明确记录为“输入可达，招式语义未通过”，详见 `docs/evidence/PLAYER_ACTION_CALIBRATION_ACCEPTANCE_2026-08-27.json`。

`0.49.14` 将拔刀准备移出七个正式样本，并取消复合招式的 `250/1100ms` 固定猜测。临时校准任务中，运行时只在玩家动作节点变化时写入小型 `runtime_player_action_signal.json`；外部输入适配器等到真实普攻或特殊纳刀姿态后再发送后续组合键。正常任务不写该信号。报告分开 `transport_status` 与招式节点语义门禁；只有两者同时完整时，自动校准才返回成功。该版随后完成部署，但首次集中语义校准被人工中止，没有形成新语义结论。

`0.49.15` 根据一次被人工中止的部署校准收紧开发自动化生命周期。脚本不再关闭一个已经运行的游戏；它只在启动时取得一次焦点，玩家切换窗口后立即停止输入且不再抢回。终态探针请求会按会话 ID 清理，临时任务文件仍按校验和删除；校准结束默认保留游戏进程，只有显式传入 `-CloseGameAfterCalibration` 才正常关闭。该约束仅保护开发采集器，不改变普通玩家的 Mod 输入或任务行为。

`0.49.15` 部署后的集中运行完成标题、据点、任务发布、准备区导航和原生传送，并采到 18 次玩家动作转换。直斩、突刺和翻滚均命中预期节点；所有依赖气刃键的步骤只产生普通 `atk_101`。排查确认输入表把 Capcom 默认 `Mouse Button 4` 错发成了 Win32 `XBUTTON2`，而 [Win32 文档](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-mouse_event)规定第一个 X 按钮为 `XBUTTON1 / 0x0001`。`0.49.16` 修正该 raw 映射，并将超时、玩家接管和发送失败分开记录；单步超时不再丢弃整轮，也不会阻止后续独立步骤采样。

`0.49.16` 修正后的完整七步复测仍只有直斩、突刺和翻滚命中预期语义；见切与特殊纳刀只产生普通 `atk_101`，两个后续居合步骤在等待特殊纳刀节点时超时。整批没有玩家接管，所有七项均被执行并保留部分证据，证明新的错误分类与批处理恢复有效，也证明 XBUTTON1 不是充分修复。该报告还确认活动红书为 `sacred_sheathe_combo`、蓝书才是 `special_sheathe_combo`；因此红书下要求特殊纳刀/居合三项属于测试计划错误，而非玩家动作失败。摘要见 `docs/evidence/PLAYER_ACTION_LOADOUT_RETEST_2026-08-28.json`。

`0.49.17` 将活动书替换技提升为校准计划契约。默认批次仅执行当前配装适用步骤，报告同时保存 `expected_step_ids`、活动技能和带原因的 `excluded_steps`；分析器据此判断完整性。显式请求未装备的特殊纳刀或居合时直接拒绝，不自动切书或覆盖玩家配置。mhrice 的公开仓库提供静态游戏资源提取但不含运行时按键绑定解析；REFramework 提供 TDB/HID 访问但没有《崛起》现成的武器语义绑定 API。为避免继续猜侧键，既有输入元数据探针现只读筛选已知 `snow.StmInputManager` 层级中与 input/key/keyboard/mouse/button/bind/device/config 相关的字段和方法签名，等待下一次集中部署一次取证。

`0.49.17` 的集中实机取证确认 `snow.StmInputManager` 直接提供 `getOn/getTrg/getRel/getDelay` 位集，以及接收 `snow.player.PlayerInput.CommandButton2` 的 `isOn/isTrg/isRel/isDelay` 查询；采样时 `get_LastInputDevice` 返回 `via.hid.GamePadDevice`，但 `_ActiveDevice=3` 所属的 `ActiveGameDevice` 尚未取得可解释成员，不能借用另一个 `ActiveDevice` 枚举下结论。这是“此前侧键猜测不可靠”的强证据，但尚不能证明用户的每个物理绑定。`0.49.18` 因此只读提取 `CommandButton2`、设备与键位配置的精确类型契约，先建立稳定的游戏语义层，再决定自动校准入口；本阶段仍不调用发现的方法。

`0.49.18` 的实机结果完整取得 56 个语义命令；`snow.StmInputConfig` 同时暴露 `TryGet_main_pl_Conf(PL_INPUT, InGameMouseKeyBoardKey)`、`TryGet_sub_pl_Conf(...)` 和 `TryGet_pad_pl_Conf(PL_INPUT, snow.Pad.Button)`。这说明当前绑定可以沿游戏原生配置读取，而无需让用户反复猜按键。`0.49.19` 先以同一只读探针补齐这些参数枚举和 `snow.StmPlInputData` 父类型契约；解析/调用映射接口必须在该元数据门禁通过后单独实现和验收。

`0.49.20` 只为方法签名增加参数名称、位置与 `is_by_ref` 证据。若映射的物理键参数是引用参数，后续读取器必须使用 REFramework 值类型缓冲区并核对布尔返回值；若是普通输入参数，则只能采用受限候选匹配，不得用全 TDB 或逐帧全值域暴力枚举。两种路径都保持在 `input_motion_adapter` 外部边界，不把物理键码泄漏到 Response 或训练 Model。

`0.49.20` 实机结果选择了第二条路径：main/sub/pad 的物理键参数均为普通输入值，方法返回布尔匹配结果。`0.49.21` 的读取器仅解析 `ACTION_ESCAPE`、`ACTION_X_ATTACK`、`ACTION_A_ATTACK`、`ACTION_EX_GUARD_FIRE` 四项，并分别返回逻辑角色、枚举名称和 raw 值；结果只用于开发校准输入边界，不改变玩家装备、替换技或产品 Response。

`0.49.21` 首轮调用在每条路径的 `None/NONE=0` 候选抛出异常，12 次均被捕获，游戏与任务继续运行；这证明失败隔离有效，但不构成非零候选不可用的证据。`0.49.22` 排除哨兵、最大值和按钮掩码候选，孤立候选异常继续并记录首个错误，累计 32 次立即停止。完整首轮证据见 `docs/evidence/BINDING_PREDICATE_FIRST_ATTEMPT_2026-08-28.json`。

`0.49.22` 第二轮实机证据排除了“只因 `None/NONE=0` 失败”：43 个非零候选调用全部抛出异常，游戏保持运行，输入适配器的玩法请求和写入均为零。谓词枚举路径因此退役，不再增加第三轮猜测。`0.49.23` 直接读取四个已暴露的绑定字典字段，仅提取字段 owner、声明/实际对象类型与精确字典方法元数据；本版本不调用任何字典方法。完整失败证据见 `docs/evidence/BINDING_PREDICATE_SECOND_ATTEMPT_2026-08-28.json`。

`0.49.23` 实机验证四个绑定字段与实际字典对象全部存在；main/sub 为静态键鼠字典，pad/player-static 为实例手柄字典。所有对象均暴露精确的 `ContainsKey(Int32)` 与 `get_Item(Int32)`，且返回类型与字段值类型一致。`0.49.24` 在这一门禁后才加入四个逻辑动作的 main/sub/pad 有界读取，最多 24 次并缓存一次；完整契约证据见 `docs/evidence/BINDING_DICTIONARY_CONTRACT_2026-08-28.json`。

`0.49.24` 的真实读取以 23 次调用解析了全部键鼠主键、副键和三项独立手柄键，零调用失败、零值解析失败。结果确认当前配装的武器特殊键是 `MOUSE_EX1`，不再依赖 Win32 侧键顺序猜测；手柄字典没有该逻辑 ID，读取器保留 `key_unavailable`，不把组合语义伪装成单按钮。完整结果见 `docs/evidence/CURRENT_BINDING_READ_2026-08-28.json`。

`0.49.25` 将动作模板中的物理键降为带来源的默认参考，正式自动校准只消费 `primary_attack`、`secondary_attack`、`weapon_special` 与 `evade` 四个语义角色。`player_action_evidence` 预检必须同时产出完整、零失败、未截断的当前绑定契约；PowerShell 边界仅把已解析的 main/sub 键鼠值转换为白名单 Windows 输入。未知键名、缺失角色、字典调用失败或只有手柄绑定时均停止，不回退到默认侧键，也不跨用 `snow.Pad.Button`。报告保存活动替换技、绑定策略、绑定来源与每个角色的实际解析结果，使“输入发送成功”和“动作语义出现”可以分别复核。

证据升级采用按风险分级的最小重复数，不再统一要求五次：同一构建和配装下，按键—动作节点关联连续一致 2 次可标记为已验证；动作节点出现不等于反击成功，见切/居合结果仍需至少 2 次与怪物判定窗及玩家结果事件一致。固定派生需自然连续出现 3 次；条件派生的每个关键条件分支各需 2 次；同一 Action/Motion 的判定窗需稳定 3 次。任一重复结果冲突时自动追加第 3 次或保持候选，不用多数票掩盖不稳定数据。

`0.49.25` 的两次完整自动实机对照分别使用旧 `mouse_event` 和微软推荐的批量 `SendInput`。两轮均读取同一当前绑定、完成 4/4 传输观察，并稳定命中直斩、突刺和翻滚；见切两轮都只出现 `atk_101`，没有 `atk_147`。因此当前绑定读取已验证，但 Windows 物理侧键注入不能作为 MHR 气刃语义入口；该路线停止，不再试 `x1/x2` 或延长人工轮次。后续仅调查有边界的 `snow.StmPlayerInput` / `CommandButton2` 游戏语义链。摘要见 `docs/evidence/RUNTIME_BINDING_CALIBRATION_2026-08-28.json`。

`0.49.26` 先建立只读语义输入元数据门禁，不把“枚举中存在 `Atk_R_A` 等名称”直接解释为见切输入。契约只覆盖四个精确类型、语义命令枚举、过滤后的字段/方法和八个明确查询方法，读取可能的受管单例存在性；它不调用查询方法、不 Hook 更新函数、不写命令位。源码离线测试以会在调用时立即报错的假方法验证零调用边界。探针完成后自动分析并归档实例所有者、查询签名和更新候选，分析结果固定为 `experiment_allowed=false`。只有后续一次集中只读采集能明确所有者、更新入口和签名，才允许在独立版本中设计可恢复的按下/释放实验；否则保持外部校准仅支持已验证的普通攻击与回避。

`0.49.26` 的集中实机取证确认四个目标类型均存在、`CommandButton2` 共 56 项，且 `snow.StmInputManager` 是唯一直接可取得的实例。Manager 暴露 `getOn/getTrg/getRel/getDelay`，但真正含 `setButton/clearButton` 的 `snow.StmPlayerInput` 不是受管单例，故不能根据类型存在就直接调用。报告的元数据契约、Adapter 请求和写入均为零。`0.49.27` 只把四个已确认的 Manager getter 提升为有界只读调用，用于取得返回位集的实际类型与精确方法；四次调用后缓存，任何失败均阻止后续实验，位集修改方法在本版仍只记录不调用。

`0.49.27` 的真实集中报告确认四个 getter 全部解析为同一 `snow.BitSetFlag<CommandButton2>` 对象，调用 4/4、失败 0、Adapter 请求与写入 0；但精确类型本身没有公开成员。外层归档第一次遇到 bootstrap ack 的瞬时 `AccessDenied`，游戏端终态此前已经完成；恢复工具随后复用匹配的 `completed` 报告完成归档、分析和请求清理，没有重放输入。`0.49.28` 因而一次性补查返回对象父类型和当前猎人字段层级。只有元数据已匹配的玩家字段才允许读取实际对象，任何 `StmPlayerInput` 候选仍只进入下一层只读查询，不直接调用 `setButton/clearButton`。
