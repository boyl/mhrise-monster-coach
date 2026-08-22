"""审计怪物陪练数据包与实机校准证据的核心提示覆盖率。"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


STATUS_RANK = {"observed": 1, "repeated": 2, "confirmed": 3}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def action_from_state_key(value: Any) -> str | None:
    text = str(value or "").split("|", 1)[0]
    if ":" in text:
        text = text.rsplit(":", 1)[1]
    return text if text.isdigit() else None


def category_from_state_key(value: Any) -> int | None:
    text = str(value or "").split("|", 1)[0]
    if ":" not in text:
        return None
    category = text.split(":", 1)[0]
    return int(category) if category.isdigit() else None


def observed_actions(calibration: dict[str, Any], required_category: int | None) -> set[str]:
    actions: set[str] = set()
    for key in (calibration.get("observed_state_metadata") or {}):
        if required_category is not None and category_from_state_key(key) != required_category:
            continue
        action = action_from_state_key(key)
        if action is not None:
            actions.add(action)
    for key in (calibration.get("observed_hitbox_windows") or {}):
        if required_category is not None and category_from_state_key(key) != required_category:
            continue
        action = action_from_state_key(key)
        if action is not None:
            actions.add(action)
    return actions


def phase_status_by_action(
    calibration: dict[str, Any], required_category: int | None
) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, row in (calibration.get("observed_hitbox_windows") or {}).items():
        if not isinstance(row, dict):
            continue
        if required_category is not None and category_from_state_key(key) != required_category:
            continue
        action = action_from_state_key(key)
        status = str(row.get("status") or "")
        if action is None or status not in STATUS_RANK:
            continue
        if STATUS_RANK[status] > STATUS_RANK.get(result.get(action, ""), 0):
            result[action] = status
    return result


def audit(static_pack: dict[str, Any], calibration: dict[str, Any]) -> dict[str, Any]:
    moves = static_pack.get("moves") or {}
    threats = static_pack.get("threats") or {}
    predictions = static_pack.get("actions") or {}
    required_category = static_pack.get("required_action_category")
    required_category = int(required_category) if required_category is not None else None
    seen = observed_actions(calibration, required_category)
    phases = phase_status_by_action(calibration, required_category)

    named = {key for key, row in moves.items() if isinstance(row, dict) and row.get("short_name")}
    advised = {
        key
        for key, row in moves.items()
        if isinstance(row, dict) and row.get("advice")
    } | {
        key
        for key, row in threats.items()
        if isinstance(row, dict) and row.get("response")
    }
    fixed = {
        key for key, row in predictions.items()
        if isinstance(row, dict) and row.get("kind") == "fixed" and len(row.get("next") or []) == 1
    }
    conditional = {
        key for key, row in predictions.items()
        if isinstance(row, dict) and row.get("kind") != "fixed" and row.get("next")
    }
    reliable_phase = {key for key, status in phases.items() if STATUS_RANK[status] >= 2}
    status_counts = Counter(phases.values())

    return {
        "schema_version": 1,
        "monster": static_pack.get("monster"),
        "required_action_category": static_pack.get("required_action_category"),
        "summary": {
            "catalogued_moves": len(moves),
            "observed_attack_actions": len(seen),
            "observed_named": len(seen & named),
            "observed_with_response": len(seen & advised),
            "observed_with_reliable_phase": len(seen & reliable_phase),
            "fixed_prediction_actions": len(fixed),
            "conditional_prediction_actions": len(conditional),
            "phase_statuses": dict(sorted(status_counts.items())),
        },
        "gaps": {
            "observed_without_name": sorted(seen - named, key=int),
            "observed_without_response": sorted(seen - advised, key=int),
            "observed_without_reliable_phase": sorted(seen - reliable_phase, key=int),
            "observed_without_prediction": sorted(seen - set(predictions), key=int),
        },
        "coverage": {
            "observed_actions": sorted(seen, key=int),
            "reliable_phase_actions": sorted(reliable_phase, key=int),
            "fixed_prediction_actions": sorted(fixed, key=int),
            "conditional_prediction_actions": sorted(conditional, key=int),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("static_pack", type=Path)
    parser.add_argument("calibration", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = audit(load_json(args.static_pack), load_json(args.calibration))
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
