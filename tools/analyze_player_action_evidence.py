"""把玩家 FSM 运行证据整理为可审核的动作目录与转换候选。"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SEMANTIC_TERMS: dict[str, tuple[str, ...]] = {
    "foresight_slash": ("foresight", "mikiri"),
    "special_sheathe_or_iai": ("iai", "specialsheathe", "special_sheath", "noto"),
    "sacred_sheathe": ("sacred", "kakugo"),
    "spirit_helmbreaker": ("helmbreaker", "helm_breaker", "kabutowari"),
    "sakura_slash": ("sakura",),
    "serene_pose": ("serene",),
}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def normalize_node_id(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value)
    return text if text else None


def action_catalog(document: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for row in document.get("node_catalog") or []:
        if not isinstance(row, dict):
            continue
        node_id = normalize_node_id(row.get("id"))
        name = row.get("name")
        if node_id is not None and isinstance(name, str) and name:
            result[node_id] = name
    return result


def catalog_candidates(catalog: dict[str, str]) -> dict[str, list[dict[str, str]]]:
    result: dict[str, list[dict[str, str]]] = {}
    for semantic, terms in SEMANTIC_TERMS.items():
        matches = []
        for node_id, name in catalog.items():
            lowered = name.lower()
            matched = next((term for term in terms if term in lowered), None)
            if matched:
                matches.append({"id": node_id, "name": name, "matched_term": matched})
        result[semantic] = sorted(matches, key=lambda row: (row["name"], row["id"]))
    return result


def analyze(document: dict[str, Any]) -> dict[str, Any]:
    catalog = action_catalog(document)
    events = [row for row in document.get("events") or [] if isinstance(row, dict)]
    nodes: dict[str, dict[str, Any]] = {}
    transitions: Counter[tuple[str, str]] = Counter()
    previous: str | None = None
    for row in events:
        node_id = normalize_node_id(row.get("node_id"))
        if node_id is None:
            continue
        entry = nodes.setdefault(node_id, {
            "id": node_id,
            "name": row.get("node_name") or catalog.get(node_id),
            "samples": 0,
            "first_sample": row.get("sample"),
            "last_sample": row.get("sample"),
            "active_tags": set(),
        })
        entry["samples"] += 1
        entry["last_sample"] = row.get("sample")
        for tag, active in (row.get("tags") or {}).items():
            if active is True:
                entry["active_tags"].add(str(tag))
        if previous is not None and previous != node_id:
            transitions[(previous, node_id)] += 1
        previous = node_id

    observed = []
    for entry in nodes.values():
        entry["active_tags"] = sorted(entry["active_tags"])
        entry["catalogued"] = entry["id"] in catalog
        observed.append(entry)
    observed.sort(key=lambda row: (-row["samples"], row["id"]))

    transition_rows = [{
        "from": source,
        "from_name": catalog.get(source) or nodes.get(source, {}).get("name"),
        "to": target,
        "to_name": catalog.get(target) or nodes.get(target, {}).get("name"),
        "count": count,
        "certainty": "observed_runtime_only",
    } for (source, target), count in transitions.most_common()]

    prefixes: defaultdict[str, int] = defaultdict(int)
    for name in catalog.values():
        prefix = re.split(r"[./:]", name, maxsplit=1)[0]
        prefixes[prefix] += 1

    return {
        "schema_version": 1,
        "policy": "catalog_and_observed_transitions_are_evidence_not_semantic_truth",
        "runtime": document.get("runtime"),
        "reader": document.get("reader"),
        "summary": {
            "catalogued_nodes": len(catalog),
            "observed_events": len(events),
            "observed_nodes": len(nodes),
            "observed_transitions": sum(transitions.values()),
            "dropped_events": document.get("dropped_events", 0),
        },
        "catalog_prefixes": dict(sorted(prefixes.items(), key=lambda item: (-item[1], item[0]))),
        "semantic_candidates": catalog_candidates(catalog),
        "observed_nodes": observed,
        "observed_transitions": transition_rows,
        "unmatched_observed_nodes": [row for row in observed if not row["catalogued"]],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report = analyze(load_json(args.evidence))
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
