#!/usr/bin/env python3
"""将自然行为调查转换为保守的攻击候选图，并与已审核怪物数据交叉验证。"""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def is_attack_onset(event: dict[str, Any], required_category: int) -> bool:
    action = event.get("action") or {}
    node = event.get("node") or {}
    name = str(node.get("name") or "")
    if int(action.get("category", -1)) != required_category or not name.startswith("Attack."):
        return False
    return ".Phase01" not in name and not name.endswith(".End")


def attack_onsets(report: dict[str, Any], required_category: int) -> list[dict[str, Any]]:
    survey = report.get("behavior_survey")
    if not isinstance(survey, dict):
        raise ValueError("Report does not contain behavior_survey")
    result: list[dict[str, Any]] = []
    for event in survey.get("events") or []:
        if not isinstance(event, dict) or not is_attack_onset(event, required_category):
            continue
        action = event.get("action") or {}
        action_no = action.get("action")
        if action_no is None:
            continue
        row = {
            "frame": int(event.get("frame", 0)),
            "action": str(action_no),
            "node": str((event.get("node") or {}).get("name") or ""),
            "motion": action.get("motion_name"),
            "horizontal_distance": (event.get("geometry") or {}).get("horizontal_distance"),
        }
        if result and result[-1]["action"] == row["action"]:
            continue
        result.append(row)
    return result


def approved_edges(static_pack: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for source, action_row in (static_pack.get("actions") or {}).items():
        if not isinstance(action_row, dict):
            continue
        for edge in action_row.get("next") or []:
            if isinstance(edge, dict) and edge.get("action") is not None:
                result[(str(source), str(edge["action"]))] = {
                    "kind": str(action_row.get("kind") or "candidate"),
                    "condition": edge.get("condition"),
                    "static_evidence_count": int(edge.get("evidence_count") or 0),
                }
    return result


def analyze(report: dict[str, Any], static_pack: dict[str, Any]) -> dict[str, Any]:
    required_category = int(static_pack.get("required_action_category", 4))
    onsets = attack_onsets(report, required_category)
    roots = Counter(row["action"] for row in onsets)
    edge_counts: Counter[tuple[str, str]] = Counter()
    edge_examples: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for source, target in zip(onsets, onsets[1:]):
        key = (source["action"], target["action"])
        edge_counts[key] += 1
        if len(edge_examples[key]) < 3:
            edge_examples[key].append({
                "source_frame": source["frame"],
                "target_frame": target["frame"],
                "source_node": source["node"],
                "target_node": target["node"],
            })
    approved = approved_edges(static_pack)
    edges = []
    for key, count in sorted(edge_counts.items(), key=lambda item: (-item[1], item[0])):
        review = approved.get(key)
        edges.append({
            "source": key[0],
            "target": key[1],
            "runtime_observations": count,
            "classification": review["kind"] if review else "observed_next_attack_candidate",
            "condition": review["condition"] if review else None,
            "static_evidence_count": review["static_evidence_count"] if review else 0,
            "approved_by_monster_pack": review is not None,
            "examples": edge_examples[key],
        })
    return {
        "schema_version": 1,
        "source_session": report.get("session_id"),
        "survey_status": report.get("status"),
        "survey_samples": (report.get("behavior_survey") or {}).get("samples"),
        "policy": "runtime_frequency_never_auto_promotes_branch_semantics",
        "attack_onsets": [
            {"action": action, "observations": count}
            for action, count in sorted(roots.items(), key=lambda item: (-item[1], item[0]))
        ],
        "edges": edges,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("static_pack", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = analyze(load_json(args.report), load_json(args.static_pack))
    rendered = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
    else:
        print(rendered)


if __name__ == "__main__":
    main()
