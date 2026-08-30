# 参与开发

感谢参与《怪物猎人崛起：曙光》怪物陪练 Mod。项目仍处于开发预览阶段；提交代码前请先理解“源码通过、安装成功、运行时加载和实机行为验收”是四种不同证据。

## 支持环境

- Windows 10/11 64 位；
- Steam《怪物猎人崛起：曙光》`16.0.2.0`；
- REFramework `mhrise / TDB 71`；当前实机基线为 `v1.5.9+7-5bae4701`；
- RiseQuestLoader，用于加载 `reframework/quests/q200032001.json`；
- PowerShell 7.0 或更高版本；
- Git for Windows；
- CPython 3.10 或更高版本，推荐 3.12；
- `requirements-dev.txt` 中锁定的 Python 测试依赖。

只有离线 AI/碰撞体研究需要以下可选工具：

- .NET 8 SDK；
- RszTool 0.3.5，并显式向 `RszAiDump.csproj` 传入其项目路径；
- RETool 和与当前游戏版本匹配的 MHRise 文件列表；
- HitboxViewer 2.2.0 仅作为可选运行时交叉验证后端，不是 Mod 的必需依赖。

仓库不分发第三方 DLL、解析器、Capcom 游戏资源、完整 RSZ dump 或存档。具体来源见 `THIRD_PARTY_NOTICES.md`。

## 初始化

所有命令均在 PowerShell 7 中执行：

```powershell
git clone https://github.com/boyl/mhrise-monster-coach.git
Set-Location .\mhrise-monster-coach
git switch feature/tigrex-training-quest

py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -r .\requirements-dev.txt
```

如果 `py` 不可用，请把第一条 Python 命令替换为本机 CPython 3.10+ 的绝对路径。不要依赖 Microsoft Store 的占位 `python.exe`。

## 验证

```powershell
.\.venv\Scripts\python.exe .\tests\run_lua_tests.py
.\.venv\Scripts\python.exe .\tests\check_lua_syntax.py
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_*.py' -v
pwsh -NoProfile -File .\tests\test_deploy_dev.ps1
```

部署测试只使用临时假游戏目录，不会访问真实游戏安装。提交前四组检查必须全部通过。

## 开发部署

先正常退出游戏，再在有目标目录写权限的 PowerShell 7 中执行：

```powershell
pwsh -NoProfile -File .\tools\deploy_dev.ps1 `
  -GameRoot 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise' `
  -Relaunch
```

若 Steam 库不在默认位置，请替换 `-GameRoot`。部署器只复制固定白名单中的 Mod 文件，逐项比较 SHA-256，并保留 `config.json`、校准、运行证据、日志和其他 Mod。游戏安装在 `Program Files` 时通常需要提升的 PowerShell 窗口。

自动化实机探针会写入游戏内开发请求和本地 `artifacts/`，其参数及安全门禁见 `tools/run_probe_session.ps1`。不要把该脚本用于联机任务或正式存档研究。

## 架构与证据规则

- 实质功能开发与问题处理遵循仓库内 [`feature-development-and-problem-solving` Skill](codex-skills/feature-development-and-problem-solving/SKILL.md)：先全局建模与根因诊断，再比对成熟方案；无方案时仅做 2–4 次有界、尽量自动化的验证，最后回顾路线并沉淀证据。
- 保持 MVC 边界，详见 `docs/ARCHITECTURE.md`；
- 通用代码不得写死新的怪物 Action ID，逐怪知识放入独立数据包；
- 固定、条件、随机、仅观察和未解析派生必须保持区分；
- 社区名称或动作节点只提供候选语义，不能单独证明判定阶段、成功反击或固定派生；
- 新写操作必须有单人、版本、任务状态和功能开关四重门禁，并提供退出或异常恢复；
- 不允许通过坐标批量写回伪造完整世界快照；已知会崩溃的 F9 路径保持禁用；
- 不修改存档、奖励、玩家装备、替换技或联机数据。

## 提交建议

1. 先说明问题模型、正常玩家流程和可验证证据。
2. 为领域逻辑补纯 Lua/Python 测试，再连接 REFramework 运行时。
3. 报告源码、安装、运行时和实机验收分别到达哪一层。
4. 只提交可公开的结构化证据；排除日志、Dump、存档、原始游戏资源和本机路径。
5. 行为改变后同步更新 `VERSION`、`docs/ROADMAP.md` 和相关验收文档。

提交补丁即表示你有权贡献相关内容，并同意按仓库的 MIT License 发布该贡献。第三方材料仍遵循各自许可证。
