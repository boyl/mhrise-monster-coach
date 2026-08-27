# 《怪物猎人崛起：曙光》怪物陪练 Mod

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个面向 Steam PC 单人任务的 REFramework Lua Mod。目标不是把怪物变成木桩，而是降低反复练习真实招式与派生的成本：显示当前招式和后续分支、按需减速、选择高价值起手，并在一轮结束后解释玩家的应对时机。

> 当前状态：开发预览版 `0.49.12-player-calibration-analysis`。轰龙核心闭环已有多项实机证据，但仓库源码可能领先于已安装副本；尚未发布面向普通玩家的一键安装包。仅限单人使用，并请先备份存档。

## 当前体验闭环

1. 进入专用任务 `[陪练] 轰龙·塔之秘境`。
2. 在“精选起手目录”中先查看派生树，再选择一个高价值起手。
3. Mod 只负责安全启动已验证起手，或引导玩家进入触发条件；后续由怪物原生 AI 续接。
4. Overlay 实时显示招式名、阶段、固定/条件/随机/仅观察派生和太刀上下文建议。
5. 按 F6 切换全局子弹时间；一轮结束后查看判定、玩家动作与结果时间轴。
6. 按 F7 一键执行游戏原生任务重开，再次进入同一陪练任务。

这种设计保留怪物真实 AI 上下文，不把一串 Action ID 强行拼成与实战无关的脚本。

## 功能状态

| 能力 | 状态 | 说明 |
|---|---|---|
| 专用轰龙陪练任务 | 候选 | MR 4★、塔之秘境、普通大师等级轰龙；可正常进入，列表排序仍待优化 |
| 实时 Action/Motion 解析 | 已验证 | 读取 `ActionCategory:ActionNo`、Motion、动画帧和行为树状态 |
| 招式名、阶段和派生提示 | 候选 | 严格区分固定、条件、随机、仅观察和未解析，不把候选冒充确定结果 |
| 太刀上下文应对 | 候选 | 结合红/蓝书、资源、姿态与怪物阶段；不会修改玩家装备或替换技 |
| F6 全局子弹时间 | 核心路径已验证 | 单击在 `0.25x` 与 `1.0x` 间切换；菜单、退出和脚本重载恢复仍需补齐集中验收 |
| F7 一键重开任务 | 已验证 | 使用游戏原生重置、重新建会话和出发流程；不是危险的局内 Transform 回写 |
| 精选起手与原生派生 | 部分已验证 | 独立、固定和条件三类入口已贯通；只开放有安全证据的场景 |
| 训练结果与事件时间轴 | 源码候选 | 记录受击、动作/状态尝试、相对判定帧和“可能偏晚”；不把无伤自动判为成功 |
| 手柄快捷键 | 候选、默认关闭 | 尚未完成实际绑定读取与冲突检测；键鼠路径不受影响 |
| F9 直接局内复位 | 禁用 | 旧 Transform 写回路径会触发原生崩溃；F7 始终是安全回退 |
| 仅怪物减速 / 世界状态回放 | 不开发 | 前者会扭曲实战速度比例，后者缺少安全完整的引擎快照机制 |

“候选”表示代码和自动测试已通过，但仍需要一次集中实机验收；它不等同于已发布能力。完整门禁见[开发路线图](docs/ROADMAP.md)。

## 当前轰龙训练目录

| 类型 | 起手 | 当前门禁 |
|---|---|---|
| 独立关键招式 | 咆哮、MR 左投石、正面咬击 | 已完成产品入口实机验收 |
| 独立关键招式 | 大咬、右回旋攻击 | 已通过批量动作证据，等待下一次集中部署完成产品入口验收 |
| 固定派生起手 | 短距半回转钩咬、长距半回转钩咬 | 由距离引导等待 AI 自然选择起手，并观察原生固定续接 |
| 条件派生起手 | 直线冲锋派生 | 展示急停与漂移再冲锋候选；精确距离、边界和 AI 上下文条件仍在解析 |

训练目录刻意控制规模：优先覆盖值得反复练习的起手和主要派生，而不是把所有内部 Action 直接暴露给用户。

## 默认操作

| 操作 | 按键 | 行为 |
|---|---:|---|
| 切换子弹时间 | F6 | 单击切换配置倍率与 `1.0x` |
| 一键重开任务 | F7 | 退出当前任务、重建同一陪练任务会话并自动出发 |
| 记录重置锚点 | F8 | 保存当前锚点；属于后续安全局内重置研究数据 |
| 直接局内复位 | F9 | 当前禁用，避免已知崩溃路径 |
| 打开 REFramework | Insert | 进入 `Script Generated UI → Monster Coach` |

F7 与 F9 的语义不同：F7 让游戏原生系统完整重建任务对象、AI、环境和碰撞；F9 若只写回坐标并不能恢复这些状态，因此在找到安全原生机制前不会开放。

## 安全边界

- 仅支持 Steam PC《怪物猎人崛起：曙光》单人训练。
- 不修改存档、任务奖励、正式任务装备、替换技或联机数据。
- 多人环境自动禁用时间、任务和怪物玩法写入。
- 未确认 Action、条件分支和玩家成功判定会明确降级，不猜测确定答案。
- 不分发 Capcom 原始资源；离线工具只生成结构化研究结果。
- 游戏或 REFramework 更新后，需要先通过兼容门禁再重新开放写入能力。

## 玩家安装

### 必需依赖

| 依赖 | 用途 | 当前验证基线 |
|---|---|---|
| Steam《怪物猎人崛起：曙光》 | 游戏本体 | `16.0.2.0` |
| [REFramework](https://github.com/praydog/REFramework) | Lua 运行时、游戏对象访问和 Overlay | `mhrise / TDB 71`；实机使用 `v1.5.9+7-5bae4701` |
| [RiseQuestLoader](https://github.com/Fexty12573/RiseQuestLoader) | 加载专用陪练任务 JSON | 必需 |

[HitboxViewer 2.2.0](https://www.nexusmods.com/monsterhunterrise/mods/2182) 只是可选的判定交叉验证后端；不安装也能使用原生只读判定提供器。手柄快捷键同样不是必需项，且当前默认关闭。

### 从源码安装

当前还没有面向普通玩家的稳定 Release 安装包。希望试用开发预览版时：

1. 备份 Steam App `1446780` 的存档，并确保只进入单人环境。
2. 按各自上游说明安装 REFramework 与 RiseQuestLoader；启动一次游戏，确认 Insert 菜单和 Quest Loader 均能正常出现。
3. 下载本仓库当前分支，正常退出游戏。
4. 把仓库中的 `reframework` 文件夹合并到游戏根目录；不要删除或整体替换已有 `reframework` 目录。
5. 核对入口文件为 `MonsterHunterRise/reframework/autorun/MHRiseMonsterCoach.lua`，任务文件为 `MonsterHunterRise/reframework/quests/q200032001.json`。
6. 启动游戏并进入离线大厅，在集会所 MR 4★ 任务中选择 `[陪练] 轰龙·塔之秘境`。

升级时保留 `reframework/data/MHRiseMonsterCoach/config.json`、校准文件和运行证据。仓库源码可能领先于已安装副本，请以游戏目录中的 `dev_install_receipt.json` 和运行日志为准。

## 开发环境

### 基础依赖

- Windows 10/11 64 位；
- PowerShell 7.0+ 和 Git for Windows；
- CPython 3.10+，推荐 3.12；
- `requirements-dev.txt` 中锁定的 `lupa`，用于运行纯 Lua 行为与语法测试；
- 上述游戏、REFramework 和 RiseQuestLoader，仅在实机验收时需要。

```powershell
git clone https://github.com/boyl/mhrise-monster-coach.git
Set-Location .\mhrise-monster-coach
git switch feature/tigrex-training-quest

py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\requirements-dev.txt
```

离线 AI/碰撞体研究还会用到可选的 .NET 8 SDK、RszTool 0.3.5、RETool 和对应游戏版本文件列表；它们不影响普通功能开发，也不随仓库分发。完整初始化、部署、证据边界和贡献规则见 [CONTRIBUTING.md](CONTRIBUTING.md)。

开发副本可使用 `tools/deploy_dev.ps1` 部署。它按白名单复制文件、逐项校验 SHA-256，并保留配置、校准、运行证据、日志和其他 Mod。游戏必须先退出；如果目标位于 `Program Files`，请从具有写权限的 PowerShell 7 执行。

## 证据与架构

项目将通用训练逻辑与逐怪数据包分离，运行时采用 Model / View / Controller 边界：

- Model 保存当前怪物、派生、训练轮次、玩家状态和时间轴；
- View 只负责呈现领域结果，不在 UI 中猜测武器或怪物语义；
- Controller 处理训练场景、快捷键、重开和安全门禁；
- 怪物数据包保存招式、派生、条件、阶段与精选起手，不在通用代码里写死轰龙 ID。

静态结构优先从成熟数据和游戏资源离线解析，运行时只读取必须实时变化的 Action、FSM、动画、距离和玩家状态。主要文档：

- [开发路线图](docs/ROADMAP.md)
- [架构与扩展契约](docs/ARCHITECTURE.md)
- [武器应对引擎](docs/RESPONSE_ENGINE.md)
- [训练时间轴与复盘](docs/TIMELINE_REVIEW.md)
- [实机验收矩阵](docs/REAL_GAME_ACCEPTANCE.md)
- [证据流水线](docs/EVIDENCE_PIPELINE.md)
- [猎人动作证据与自动校准](docs/PLAYER_ACTION_EVIDENCE.md)
- [第三方来源与说明](THIRD_PARTY_NOTICES.md)

研究与实现主要参考 [MHRice](https://github.com/wwylele/mhrice)、[REFramework](https://github.com/praydog/REFramework)、[REFramework 文档](https://reframework.praydog.com/)、[MonsterHunterRiseModding Wiki](https://github.com/mhvuze/MonsterHunterRiseModding/wiki) 和 [RE-BHVT-Editor](https://github.com/praydog/RE-BHVT-Editor)。第三方代码和数据只按其许可证与证据边界使用。

## 开发验证

仓库将纯领域测试、Lua 语法、Python 工具和部署白名单分别验证：

```powershell
.\.venv\Scripts\python.exe tests/run_lua_tests.py
.\.venv\Scripts\python.exe tests/check_lua_syntax.py
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_*.py' -v
pwsh -NoProfile -File tests/test_deploy_dev.ps1
```

自动测试通过不等于实机验收通过。源码候选会在集中部署后，按 `docs/REAL_GAME_ACCEPTANCE.md` 收集真实游戏证据再升级状态。

## 近期目标

1. 集中复验自动太刀校准任务的七步输入批次，不再让玩家逐招手工标注。
2. 将自动采集的动作节点与怪物判定窗关联，把结果从“动作/状态尝试”推进到有明确证据的防御、回避、见切、居合与反击。
3. 完成轰龙实用版 8–12 个高价值起手及主要固定、条件和随机派生。
4. 稳定轰龙闭环后，以第二只复杂怪物验证数据包扩展能力。

详细排期、每项安全门禁以及明确不开发的功能见[路线图](docs/ROADMAP.md)。

## 许可证

本项目代码和项目自有文档采用 [MIT License](LICENSE)。Capcom 游戏资源、第三方 Mod、解析器和外部数据不包含在该授权中，分别遵循其所有者的条款；详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
