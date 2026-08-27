"""把自动键鼠采集报告归并为可审核的太刀动作关联候选。"""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


EXPECTED_STEPS = (
    "basic_overhead",
    "thrust",
    "dodge",
    "foresight_attempt",
    "special_sheathe",
    "iai_slash_attempt",
    "iai_spirit_attempt",
)

NEUTRAL_EXACT = {
    "wait.main",
    "wait.wait_pre_mot_end",
    "wp_on",
    "atk.atk_wait.atk_wait_main.atk_wait_main",
}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def node_key(event: dict[str, Any]) -> tuple[str, str] | None:
    node_id = event.get("node_id")
    node_name = event.get("node_name")
    if node_id is None or not isinstance(node_name, str) or not node_name:
        return None
    return str(node_id), node_name


def is_neutral(name: str) -> bool:
    return name in NEUTRAL_EXACT or name.startswith(("fast_travel.", "damage."))


def summarize_step(row: dict[str, Any]) -> dict[str, Any]:
    events = [event for event in row.get("events") or [] if isinstance(event, dict)]
    seen: dict[tuple[str, str], dict[str, Any]] = {}
    order: list[tuple[str, str]] = []
    for event in events:
        key = node_key(event)
        if key is None:
            continue
        if key not in seen:
            seen[key] = {
                "node_id": key[0],
                "node_name": key[1],
                "samples": 0,
                "first_sample": event.get("sample"),
                "last_sample": event.get("sample"),
                "active_tags": set(),
                "neutral": is_neutral(key[1]),
            }
            order.append(key)
        entry = seen[key]
        entry["samples"] += 1
        entry["last_sample"] = event.get("sample")
        for tag, active in (event.get("tags") or {}).items():
            if active is True:
                entry["active_tags"].add(str(tag))

    nodes = []
    for key in order:
        entry = seen[key]
        entry["active_tags"] = sorted(entry["active_tags"])
        nodes.append(entry)
    correlated = [entry for entry in nodes if not entry["neutral"]]
    expected_prefixes = [
        str(value) for value in row.get("expected_node_prefixes") or [] if value
    ]
    semantic_matches = [
        entry for entry in correlated
        if any(entry["node_name"].startswith(prefix) for prefix in expected_prefixes)
    ]
    semantic_status = (
        "unavailable" if not expected_prefixes
        else "observed" if semantic_matches
        else "not_observed"
    )
    return {
        "id": row.get("id"),
        "label": row.get("label"),
        "capture_status": row.get("status"),
        "expected_tags": list(row.get("expected_tags") or []),
        "expected_node_prefixes": expected_prefixes,
        "observed_tags": list(row.get("observed_tags") or []),
        "baseline_sample": row.get("baseline_sample"),
        "baseline_revision": row.get("baseline_revision"),
        "observed_revision": row.get("observed_revision"),
        "correlated_nodes": correlated,
        "neutral_nodes": [entry for entry in nodes if entry["neutral"]],
        "terminal_correlated_node": correlated[-1] if correlated else None,
        "semantic_matches": semantic_matches,
        "semantic_status": semantic_status,
        "input_error_kind": row.get("input_error_kind"),
        "reason": row.get("reason"),
    }


def analyze(document: dict[str, Any]) -> dict[str, Any]:
    rows = [row for row in document.get("results") or [] if isinstance(row, dict)]
    declared_steps = document.get("expected_step_ids")
    expected_steps = (
        tuple(str(value) for value in declared_steps if value)
        if isinstance(declared_steps, list)
        else EXPECTED_STEPS
    )
    steps = [summarize_step(row) for row in rows]
    by_id = {row.get("id"): row for row in steps if isinstance(row.get("id"), str)}
    node_steps: defaultdict[tuple[str, str], set[str]] = defaultdict(set)
    node_counts: Counter[tuple[str, str]] = Counter()
    for step in steps:
        step_id = step.get("id")
        if not isinstance(step_id, str):
            continue
        for node in step["correlated_nodes"]:
            key = (node["node_id"], node["node_name"])
            node_steps[key].add(step_id)
            node_counts[key] += int(node["samples"])

    for step in steps:
        for node in step["correlated_nodes"]:
            key = (node["node_id"], node["node_name"])
            node["observed_in_steps"] = sorted(node_steps[key])
            node["exclusive_to_step"] = len(node_steps[key]) == 1

    missing = [step_id for step_id in expected_steps if step_id not in by_id]
    incomplete = [
        step_id for step_id in expected_steps
        if step_id in by_id and by_id[step_id]["capture_status"] != "observed"
    ]
    empty_observed = [
        step_id for step_id in expected_steps
        if step_id in by_id
        and by_id[step_id]["capture_status"] == "observed"
        and not by_id[step_id]["correlated_nodes"]
    ]
    semantic_mismatches = [
        step_id for step_id in expected_steps
        if step_id in by_id and by_id[step_id]["semantic_status"] == "not_observed"
    ]
    semantic_unavailable = [
        step_id for step_id in expected_steps
        if step_id in by_id and by_id[step_id]["semantic_status"] == "unavailable"
    ]
    complete = (
        not missing and not incomplete and not empty_observed
        and not semantic_mismatches and not semantic_unavailable
    )

    node_index = [{
        "node_id": key[0],
        "node_name": key[1],
        "observed_in_steps": sorted(node_steps[key]),
        "samples": node_counts[key],
        "exclusive_to_one_step": len(node_steps[key]) == 1,
    } for key in sorted(node_steps, key=lambda value: (value[1], value[0]))]

    return {
        "schema_version": 1,
        "policy": "input_correlated_candidates_are_not_success_semantics",
        "source": {
            "session_id": document.get("session_id"),
            "source_version": document.get("source_version"),
            "captured_at": document.get("captured_at"),
            "official_default_control_source": document.get("official_default_control_source"),
            "weapon_type": document.get("weapon_type"),
            "player_type": document.get("player_type"),
            "active_scroll": document.get("active_scroll"),
            "switch_skills": document.get("switch_skills"),
            "plan": document.get("plan"),
            "equipment_writes": document.get("equipment_writes"),
            "save_writes": document.get("save_writes"),
        },
        "gate": {
            "status": "complete" if complete else "partial",
            "expected_steps": list(expected_steps),
            "missing_steps": missing,
            "incomplete_steps": incomplete,
            "observed_steps_without_correlated_nodes": empty_observed,
            "semantic_mismatch_steps": semantic_mismatches,
            "semantic_unavailable_steps": semantic_unavailable,
            "transport_status": (
                "complete" if not missing and not incomplete and not empty_observed else "partial"
            ),
            "may_update_verified_semantics": False,
        },
        "steps": steps,
        "node_index": node_index,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = analyze(load_json(args.report))
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
