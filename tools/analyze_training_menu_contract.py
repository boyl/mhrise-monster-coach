#!/usr/bin/env python3
"""验证实机 ui_contract_snapshot 是否满足指定起手菜单状态合同。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ALLOWED_STATES = {
    "disabled",
    "unavailable",
    "empty",
    "ready",
    "previewed",
    "active",
    "completed",
    "failed",
    "cancelled",
}


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def analyze(report: dict[str, Any]) -> dict[str, Any]:
    violations: list[str] = []
    contract = report.get("ui_contract")
    contract = contract if isinstance(contract, dict) else {}

    if report.get("kind") != "ui_contract_snapshot" or report.get("status") != "completed":
        violations.append("completed_ui_contract_report_required")
    if not contract:
        violations.append("ui_contract_missing")
    if contract.get("schema_version") != 1:
        violations.append("unsupported_ui_contract_schema")

    state = contract.get("state")
    if state not in ALLOWED_STATES:
        violations.append("unknown_menu_state")
    for field in ("state_label", "status", "instruction", "scope_status"):
        if not _nonempty(contract.get(field)):
            violations.append(f"menu_text_missing:{field}")
    for field in ("enabled", "scope_ready", "can_select", "can_start", "can_stop"):
        if not isinstance(contract.get(field), bool):
            violations.append(f"menu_boolean_missing:{field}")

    requested = contract.get("requested_repeats")
    if not isinstance(requested, int) or isinstance(requested, bool) or not 1 <= requested <= 20:
        violations.append("requested_repeats_out_of_range")

    groups = contract.get("groups")
    groups = groups if isinstance(groups, list) else []
    if not isinstance(contract.get("groups"), list):
        violations.append("groups_missing")

    scenario_ids: list[str] = []
    selected_ids: list[str] = []
    group_ids: list[str] = []
    for group_index, group in enumerate(groups):
        if not isinstance(group, dict):
            violations.append(f"group_invalid:{group_index}")
            continue
        group_id = group.get("id")
        if not _nonempty(group_id) or not _nonempty(group.get("name")):
            violations.append(f"group_identity_missing:{group_index}")
        else:
            group_ids.append(group_id)
        scenarios = group.get("scenarios")
        if not isinstance(scenarios, list) or not scenarios:
            violations.append(f"group_scenarios_empty:{group_id or group_index}")
            continue
        for row_index, row in enumerate(scenarios):
            prefix = f"scenario:{group_id or group_index}:{row_index}"
            if not isinstance(row, dict):
                violations.append(f"{prefix}:invalid")
                continue
            scenario_id = row.get("scenario_id")
            if not _nonempty(scenario_id) or not _nonempty(row.get("name")):
                violations.append(f"{prefix}:identity_missing")
                continue
            scenario_ids.append(scenario_id)
            if row.get("selected") is True:
                selected_ids.append(scenario_id)
            elif row.get("selected") is not False:
                violations.append(f"{scenario_id}:selected_not_boolean")
            if not _nonempty(row.get("start_label")):
                violations.append(f"{scenario_id}:start_label_missing")
            if row.get("requested_repeats") != requested:
                violations.append(f"{scenario_id}:requested_repeats_mismatch")
            effective = row.get("effective_repeats")
            if (
                not isinstance(effective, int)
                or isinstance(effective, bool)
                or not isinstance(requested, int)
                or not 1 <= effective <= requested
            ):
                violations.append(f"{scenario_id}:effective_repeats_invalid")
            elif effective < requested and not _nonempty(row.get("repeat_gate_message")):
                violations.append(f"{scenario_id}:repeat_gate_message_missing")
            if not isinstance(row.get("branch_tree"), dict):
                violations.append(f"{scenario_id}:branch_tree_missing")

    if len(group_ids) != len(set(group_ids)):
        violations.append("duplicate_group_id")
    if len(scenario_ids) != len(set(scenario_ids)):
        violations.append("duplicate_scenario_id")
    if contract.get("scenario_count") != len(scenario_ids):
        violations.append("scenario_count_mismatch")
    if len(selected_ids) > 1:
        violations.append("multiple_selected_scenarios")

    selected = contract.get("selected")
    if selected is None:
        if selected_ids:
            violations.append("selected_object_missing")
    elif not isinstance(selected, dict) or selected.get("scenario_id") not in selected_ids:
        violations.append("selected_object_mismatch")

    can_start = contract.get("can_start") is True
    can_stop = contract.get("can_stop") is True
    if can_start and not (
        contract.get("enabled") is True
        and contract.get("scope_ready") is True
        and isinstance(selected, dict)
        and state != "active"
    ):
        violations.append("start_gate_inconsistent")
    if state == "active":
        if not can_stop or contract.get("can_start") is not False or contract.get("can_select") is not False:
            violations.append("active_action_ownership_inconsistent")
    elif can_stop:
        violations.append("stop_exposed_outside_active_state")
    if state == "disabled" and (contract.get("enabled") is not False or can_start):
        violations.append("disabled_state_inconsistent")
    if state == "empty" and (scenario_ids or can_start):
        violations.append("empty_state_inconsistent")
    if state == "ready" and (selected is not None or can_start):
        violations.append("ready_state_inconsistent")
    if state in {"previewed", "completed", "failed", "cancelled"} and selected is None:
        violations.append(f"{state}_state_missing_selection")

    violations = list(dict.fromkeys(violations))
    valid = not violations
    return {
        "schema_version": 1,
        "status": "verified_training_menu_contract" if valid else "invalid_training_menu_contract",
        "contract_valid": valid,
        "ready_for_runtime_ui_review": valid,
        "violations": violations,
        "menu_state": state,
        "scenario_count": len(scenario_ids),
        "group_count": len(groups),
        "selected_scenario_id": selected.get("scenario_id") if isinstance(selected, dict) else None,
        "action_gates": {
            "can_select": contract.get("can_select"),
            "can_start": contract.get("can_start"),
            "can_stop": contract.get("can_stop"),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = analyze(json.loads(args.report.read_text(encoding="utf-8-sig")))
    payload = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if result["contract_valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
