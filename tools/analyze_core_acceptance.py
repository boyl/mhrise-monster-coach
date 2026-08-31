#!/usr/bin/env python3
"""审核单次游戏进程内连续执行的轰龙 MVP 核心验收批次。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def analyze(payload: dict[str, Any]) -> dict[str, Any]:
    violations: list[str] = []
    coverage_gaps: list[str] = []

    if payload.get("schema_version") != 1:
        violations.append("unsupported_batch_schema")
    if payload.get("kind") != "mvp_core_acceptance_batch":
        violations.append("unexpected_batch_kind")
    if payload.get("status") != "completed":
        violations.append("batch_not_completed")

    plan = payload.get("plan") or {}
    expected = plan.get("scenarios")
    expected = expected if isinstance(expected, list) else []
    results = payload.get("scenarios")
    results = results if isinstance(results, list) else []

    expected_ids = [str(item.get("id")) for item in expected if isinstance(item, dict)]
    result_ids = [str(item.get("id")) for item in results if isinstance(item, dict)]
    if not expected_ids:
        violations.append("empty_acceptance_plan")
    if len(expected_ids) != len(set(expected_ids)):
        violations.append("duplicate_plan_scenario")
    if result_ids != expected_ids:
        violations.append("scenario_execution_order_mismatch")

    required_categories = set(plan.get("required_categories") or [])
    planned_categories = {
        str(item.get("category")) for item in expected if isinstance(item, dict)
    }
    missing_categories = sorted(required_categories - planned_categories)
    if missing_categories:
        violations.append("required_category_missing")
        coverage_gaps.extend(f"category:{item}" for item in missing_categories)

    scenario_summaries: list[dict[str, Any]] = []
    phase_coverage_complete = True
    result_coverage_complete = True
    for index, expected_row in enumerate(expected):
        if index >= len(results) or not isinstance(results[index], dict):
            break
        row = results[index]
        scenario_id = str(expected_row.get("id"))
        analysis = row.get("analysis") or {}
        training = analysis.get("training") or {}
        timeline = analysis.get("timeline") or {}
        outcome = analysis.get("outcome") or {}
        row_violations: list[str] = []

        if row.get("process_exit_code") != 0:
            row_violations.append("probe_process_failed")
        if row.get("probe_status") != "completed":
            row_violations.append("probe_not_completed")
        if analysis.get("contract_valid") is not True:
            row_violations.append("timeline_contract_invalid")
        if str(training.get("scenario_id")) != scenario_id:
            row_violations.append("scenario_identity_mismatch")
        if training.get("completed_rounds") != training.get("target_rounds"):
            row_violations.append("round_count_mismatch")

        complete_timeline = analysis.get("status") == "verified_complete_training_timeline"
        classified_result = outcome.get("evidence_level") not in {None, "unclassified", "interrupted"}
        if not complete_timeline:
            phase_coverage_complete = False
            coverage_gaps.append(f"{scenario_id}:complete_timeline")
        if not classified_result:
            result_coverage_complete = False
            coverage_gaps.append(f"{scenario_id}:classified_result")
        if row_violations:
            violations.extend(f"{scenario_id}:{item}" for item in row_violations)

        scenario_summaries.append({
            "id": scenario_id,
            "category": expected_row.get("category"),
            "contract_valid": analysis.get("contract_valid") is True,
            "timeline_status": analysis.get("status"),
            "hitbox_window_count": len(timeline.get("hitbox_windows") or []),
            "completion_basis": timeline.get("completion_basis"),
            "outcome": outcome.get("value"),
            "evidence_level": outcome.get("evidence_level"),
            "violations": row_violations,
        })

    violations = list(dict.fromkeys(violations))
    coverage_gaps = list(dict.fromkeys(coverage_gaps))
    core_contract_valid = not violations
    return {
        "schema_version": 1,
        "status": (
            "ready_for_release_gate"
            if core_contract_valid and phase_coverage_complete and result_coverage_complete
            else "core_contract_valid_with_coverage_gaps"
            if core_contract_valid
            else "invalid_core_acceptance_batch"
        ),
        "core_contract_valid": core_contract_valid,
        "phase_coverage_complete": phase_coverage_complete,
        "result_coverage_complete": result_coverage_complete,
        "ready_for_release_gate": (
            core_contract_valid and phase_coverage_complete and result_coverage_complete
        ),
        "violations": violations,
        "coverage_gaps": coverage_gaps,
        "scenario_count": len(results),
        "required_categories": sorted(required_categories),
        "scenarios": scenario_summaries,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    payload = json.loads(args.evidence.read_text(encoding="utf-8-sig"))
    result = analyze(payload)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)


if __name__ == "__main__":
    main()
