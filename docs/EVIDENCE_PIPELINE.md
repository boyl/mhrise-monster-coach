# 怪物行为证据流水线

## 目标

开发探针只负责采集运行时事实；离线分析器只负责生成候选；怪物数据包负责审核后的产品语义。三层不得相互替代。

## 数据流

1. `run_probe_session.ps1` 完成或失败时，先把原始报告复制到 `artifacts/probe_reports/<session>.<kind>.<status>.json`。
2. `analyze_behavior_survey.py` 从自然调查提取攻击起手和下一攻击候选，并与怪物数据包已有边交叉验证。
3. 未被怪物包审核的边始终输出为 `observed_next_attack_candidate`，无论出现多少次。
4. 只有静态 Think/FSM 结构与自然运行时证据共同支持后，才允许在怪物包中声明 `fixed` 或 `conditional`。
5. 强制 Action 探针仅验证起手能否安全进入和退出，不用于证明后继关系。

## 离线分析

```powershell
python tools/analyze_behavior_survey.py `
  artifacts/probe_reports/<report>.json `
  reframework/data/MHRiseMonsterCoach/tigrex_static_ai.json `
  --output artifacts/probe_reports/<report>.analysis.json
```

`artifacts/` 被 Git 忽略。值得长期保留的结论需提炼为 `docs/evidence/` 下的小型证据文件，不提交包含易变内存地址的整份运行时报告。

## 不变量

- UI 探针不得覆盖尚未归档的自然调查证据。
- 频率不是概率，单一高频后继也不是固定派生证明。
- 跨 `Normal.Search` 的下一攻击默认只是候选，除非上层 Think/FSM 明确证明属于同一连段。
- 未解析条件必须显示“条件尚未完全解析”，不得猜测距离、怒气或边界阈值。
