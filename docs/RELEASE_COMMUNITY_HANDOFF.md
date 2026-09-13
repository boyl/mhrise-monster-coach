# v0.54.1：社区共建交接（源码开发预览）

维护者暂时没有精力继续集中开发，现将已有成果和接手路径公开整理，欢迎社区接力，不承诺响应时限。

**希望你带着自己的 AI 一起共创。** 本项目由人主导目标、思路、流程和产品取舍，由 AI 参与代码、测试、工具与文档开发。贡献者对改动及验证负责；无需指定 AI 产品，人工贡献同样欢迎。

## 从这里开始

- [AI 接手入口与可复制提示词](https://github.com/boyl/mhrise-monster-coach/blob/v0.54.1-community-handoff/docs/AI_START_HERE.md)
- [当前进度、安全边界与证据](https://github.com/boyl/mhrise-monster-coach/blob/v0.54.1-community-handoff/docs/HANDOFF.md)
- [可认领任务与完成条件](https://github.com/boyl/mhrise-monster-coach/blob/v0.54.1-community-handoff/docs/COMMUNITY_TASKS.md)
- [贡献指南](https://github.com/boyl/mhrise-monster-coach/blob/v0.54.1-community-handoff/CONTRIBUTING.md)

## 成果与未完成项

轰龙 8/8 精选起手、原生派生、受击/无伤结果和训练时间轴已有实机证据。相较历史 v0.49.54，加入默认简洁提示与默认关闭的完整 HUD，以及冰牙龙研究数据包、自动选包和独立任务。

冰牙龙仍是 `research_only`，指定出招未开放；F9 局内复位继续硬禁用。F6 核心切换已实测，但退出/菜单/重载恢复仍需补验；手柄映射和新版本干净环境安装验收也未完成。

## 本次验证与分发范围

本次收尾未改游戏运行代码，运行基线为 `01b9e19` / `0.54.1-automated-overlay-acceptance`。重新通过 Lua 行为 40/40、Lua 语法 78/78、Python 104 项，以及临时假游戏目录中的部署、安装、卸载和回滚测试。历史实机报告摘要已整理入仓库，本次没有重新启动游戏验收。

这是 **Pre-release 源码交接**，不附新的可安装 Mod 包。GitHub 自动生成的 Source code ZIP/TAR 是源码，不能当作安装包。旧 v0.49.54 安装附件继续保留，但不包含此次新功能；新玩家安装版应由后续贡献者通过实机发布门禁后提供。

单人 Steam PC 曙光与对应 REFramework/RiseQuestLoader 为已研究范围。不要上传存档、原始游戏资源、完整 Dump、账号或本机配置。请通过 Issue 与小范围 PR 参与，模板已提供。
