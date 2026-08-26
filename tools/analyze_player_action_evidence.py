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


def runtime_matches(scope: Any, runtime: Any) -> bool:
    if not isinstance(scope, dict):
        return True
    if not isinstance(runtime, dict):
        return False
    return all(runtime.get(key) == value for key, value in scope.items())


def knowledge_matches_reader(knowledge: dict[str, Any] | None, player_type: str | None) -> bool:
    """Fail closed when a weapon-specific pack does not match the active player class."""
    if not isinstance(knowledge, dict):
        return False
    weapon = knowledge.get("weapon")
    if weapon is None:
        return True
    normalized_type = (player_type or "").lower()
    if weapon == "long_sword":
        return "longsword" in normalized_type
    return False


def pattern_match(node_name: str, row: dict[str, Any]) -> tuple[int, str, str] | None:
    matches: list[tuple[int, str, str]] = []
    for value in row.get("exact") or []:
        if node_name == value:
            matches.append((20_000 + len(value), "exact", value))
    for value in row.get("prefixes") or []:
        if node_name.startswith(value):
            matches.append((10_000 + len(value), "prefix", value))
    return max(matches, default=None)


def semantic_mappings(
    catalog: dict[str, str],
    document: dict[str, Any],
    knowledge: dict[str, Any] | None,
    observed_samples: Counter[str],
) -> list[dict[str, Any]]:
    if not isinstance(knowledge, dict):
        return []
    actions = knowledge.get("actions") or {}
    sources = {
        row.get("id"): row for row in knowledge.get("sources") or []
        if isinstance(row, dict) and row.get("id")
    }
    result = []
    for node_id, node_name in catalog.items():
        winner: dict[str, Any] | None = None
        winner_match: tuple[int, str, str] | None = None
        for row in knowledge.get("runtime_node_patterns") or []:
            if not isinstance(row, dict) or not runtime_matches(row.get("runtime_scope"), document.get("runtime")):
                continue
            matched = pattern_match(node_name, row)
            if matched is not None and (winner_match is None or matched[0] > winner_match[0]):
                winner, winner_match = row, matched
        if winner is None or winner_match is None:
            continue
        source = sources.get(winner.get("source_id")) or {}
        action = actions.get(winner.get("semantic")) or {}
        result.append({
            "id": node_id,
            "name": node_name,
            "semantic": winner.get("semantic"),
            "action_name": action.get("name") or winner.get("semantic"),
            "role": winner.get("role") or "action",
            "match_type": winner_match[1],
            "matched_pattern": winner_match[2],
            "mapping_status": winner.get("evidence_status") or "community_candidate",
            "source_id": winner.get("source_id"),
            "source_url": source.get("url"),
            "runtime_observed": observed_samples[node_id] > 0,
            "observed_samples": observed_samples[node_id],
        })
    return sorted(result, key=lambda row: (row["semantic"], row["role"], row["name"], row["id"]))


def analyze(document: dict[str, Any], knowledge: dict[str, Any] | None = None) -> dict[str, Any]:
    catalog = action_catalog(document)
    events = [row for row in document.get("events") or [] if isinstance(row, dict)]
    reader = document.get("reader") if isinstance(document.get("reader"), dict) else {}
    current_player_type = reader.get("player_type") if isinstance(reader.get("player_type"), str) else None
    explicit_player_types = {
        row.get("player_type") for row in events
        if isinstance(row.get("player_type"), str) and row.get("player_type")
    }
    attribution = "per_event" if explicit_player_types else "legacy_top_level_fallback"
    nodes: dict[tuple[str | None, str], dict[str, Any]] = {}
    transitions: Counter[tuple[tuple[str | None, str], tuple[str | None, str]]] = Counter()
    previous: tuple[str | None, str] | None = None
    for row in events:
        node_id = normalize_node_id(row.get("node_id"))
        if node_id is None:
            continue
        player_type = row.get("player_type") if isinstance(row.get("player_type"), str) else current_player_type
        node_key = (player_type, node_id)
        entry = nodes.setdefault(node_key, {
            "id": node_id,
            "player_type": player_type,
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
        if previous is not None and previous != node_key and previous[0] == player_type:
            transitions[(previous, node_key)] += 1
        previous = node_key

    observed = []
    for entry in nodes.values():
        entry["active_tags"] = sorted(entry["active_tags"])
        entry["catalogued"] = entry["player_type"] == current_player_type and entry["id"] in catalog
        observed.append(entry)
    observed.sort(key=lambda row: (-row["samples"], row["id"]))

    transition_rows = [{
        "from": source[1],
        "from_player_type": source[0],
        "from_name": (catalog.get(source[1]) if source[0] == current_player_type else None)
            or nodes.get(source, {}).get("name"),
        "to": target[1],
        "to_player_type": target[0],
        "to_name": (catalog.get(target[1]) if target[0] == current_player_type else None)
            or nodes.get(target, {}).get("name"),
        "count": count,
        "certainty": "observed_runtime_only",
    } for (source, target), count in transitions.most_common()]

    prefixes: defaultdict[str, int] = defaultdict(int)
    for name in catalog.values():
        prefix = re.split(r"[./:]", name, maxsplit=1)[0]
        prefixes[prefix] += 1

    observed_samples: Counter[str] = Counter({
        row["id"]: row["samples"] for row in observed
        if row["player_type"] == current_player_type
    })
    knowledge_applicable = knowledge_matches_reader(knowledge, current_player_type)
    mappings = semantic_mappings(catalog, document, knowledge, observed_samples) if knowledge_applicable else []
    mapped_ids = {row["id"] for row in mappings}

    return {
        "schema_version": 2,
        "policy": "runtime_observation_confirms_node_presence_not_community_semantic_truth",
        "runtime": document.get("runtime"),
        "reader": document.get("reader"),
        "weapon_context": {
            "current_player_type": current_player_type,
            "observed_player_types": sorted(value for value in explicit_player_types if value),
            "event_attribution": attribution,
            "knowledge_weapon": knowledge.get("weapon") if isinstance(knowledge, dict) else None,
            "knowledge_applicable": knowledge_applicable,
        },
        "summary": {
            "catalogued_nodes": len(catalog),
            "observed_events": len(events),
            "observed_nodes": len(nodes),
            "observed_transitions": sum(transitions.values()),
            "dropped_events": document.get("dropped_events", 0),
            "semantic_mapped_nodes": len(mappings),
            "observed_semantic_nodes": sum(row["runtime_observed"] for row in mappings),
        },
        "catalog_prefixes": dict(sorted(prefixes.items(), key=lambda item: (-item[1], item[0]))),
        "semantic_candidates": catalog_candidates(catalog),
        "semantic_mappings": mappings,
        "observed_nodes": observed,
        "observed_transitions": transition_rows,
        "unmatched_observed_nodes": [row for row in observed if not row["catalogued"]],
        "unmapped_semantic_observed_nodes": [row for row in observed if row["id"] not in mapped_ids],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--knowledge", type=Path, help="武器语义数据包；默认使用仓库太刀数据")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    knowledge_path = args.knowledge or (
        Path(__file__).resolve().parents[1]
        / "reframework/data/MHRiseMonsterCoach/long_sword_knowledge.json"
    )
    report = analyze(load_json(args.evidence), load_json(knowledge_path))
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
