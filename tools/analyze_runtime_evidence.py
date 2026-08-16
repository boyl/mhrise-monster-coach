#!/usr/bin/env python3
"""Summarize automatically captured Monster Coach runtime evidence."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


def analyze(payload: dict, required_category: int = 4) -> dict:
    history = payload.get("history") or []
    attacks = [item for item in history if item.get("metadata", {}).get("action_category") == required_category]
    action_counts: Counter[str] = Counter()
    motions: dict[str, set[str]] = defaultdict(set)
    immediate_edges: Counter[str] = Counter()

    for item in attacks:
        action = str(item.get("action"))
        action_counts[action] += 1
        motion = item.get("metadata", {}).get("motion_name")
        if motion:
            motions[action].add(str(motion))

    for previous, current in zip(history, history[1:]):
        if (previous.get("metadata", {}).get("action_category") == required_category
                and current.get("metadata", {}).get("action_category") == required_category):
            immediate_edges[f"{previous.get('action')}->{current.get('action')}"] += 1

    return {
        "captured_transition_count": len(history),
        "attack_transition_count": len(attacks),
        "required_action_category": required_category,
        "actions": [
            {"action": action, "count": count, "motions": sorted(motions[action])}
            for action, count in sorted(action_counts.items(), key=lambda item: (-item[1], item[0]))
        ],
        "immediate_attack_edges": [
            {"edge": edge, "count": count}
            for edge, count in sorted(immediate_edges.items(), key=lambda item: (-item[1], item[0]))
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--category", type=int, default=4)
    args = parser.parse_args()
    payload = json.loads(args.evidence.read_text(encoding="utf-8"))
    print(json.dumps(analyze(payload, args.category), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
