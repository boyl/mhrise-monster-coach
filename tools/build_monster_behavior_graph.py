#!/usr/bin/env python3
"""Build a compact monster behavior graph from RszAiDump JSON files."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SCALAR_TYPES = (str, int, float, bool, type(None))


def fields_by_name(instance: dict[str, Any]) -> dict[str, Any]:
    return {field["name"]: field.get("value") for field in instance.get("fields", [])}


def primitive_fields(instance: dict[str, Any]) -> dict[str, Any]:
    return {
        field["name"]: field.get("value")
        for field in instance.get("fields", [])
        if isinstance(field.get("value"), SCALAR_TYPES)
    }


def reference_id(value: Any) -> int | None:
    if not isinstance(value, dict):
        return None
    ref = value.get("$ref")
    return ref if isinstance(ref, int) and ref > 0 else None


def dereference(
    value: Any,
    instances: dict[int, dict[str, Any]],
    diagnostics: list[dict[str, Any]],
    source: str,
    owner_id: int,
    field: str,
) -> dict[str, Any] | None:
    ref = reference_id(value)
    if ref is None:
        return None
    target = instances.get(ref)
    if target is None:
        diagnostics.append(
            {
                "code": "missing_reference",
                "source": source,
                "instance_id": owner_id,
                "field": field,
                "reference_id": ref,
            }
        )
    return target


def extract_action(
    value: Any,
    instances: dict[int, dict[str, Any]],
    diagnostics: list[dict[str, Any]],
    source: str,
    state_instance_id: int,
) -> dict[str, Any] | None:
    action = dereference(value, instances, diagnostics, source, state_instance_id, "_ActionList")
    if action is None:
        return None
    fields = fields_by_name(action)
    return {
        "instance_id": action["id"],
        "type": action.get("type"),
        "action_no": fields.get("_ActionNo"),
        "stable_id": fields.get("v1_ID"),
        "fields": primitive_fields(action),
    }


def extract_transition(
    value: Any,
    instances: dict[int, dict[str, Any]],
    diagnostics: list[dict[str, Any]],
    source: str,
    state_instance_id: int,
) -> dict[str, Any] | None:
    wrapper = dereference(value, instances, diagnostics, source, state_instance_id, "_ConditionList")
    if wrapper is None:
        return None
    wrapper_fields = fields_by_name(wrapper)
    condition = dereference(
        wrapper_fields.get("_Condition"),
        instances,
        diagnostics,
        source,
        wrapper["id"],
        "_Condition",
    )
    condition_reference = wrapper_fields.get("_Condition")
    return {
        "instance_id": wrapper["id"],
        "next_state_id": wrapper_fields.get("_NextStateID"),
        "is_action_end": wrapper_fields.get("_IsActionEnd"),
        "is_under_layer_end": wrapper_fields.get("_IsUnderLayerEnd"),
        "condition": {
            "instance_id": condition.get("id") if condition else reference_id(condition_reference),
            "type": condition.get("type") if condition else (
                condition_reference.get("$type") if isinstance(condition_reference, dict) else None
            ),
            "fields": primitive_fields(condition) if condition else {},
        },
    }


def extract_reference_userdata(value: Any, instances: dict[int, dict[str, Any]]) -> str | None:
    if isinstance(value, dict) and isinstance(value.get("$userdata"), str):
        return value["$userdata"]
    ref = reference_id(value)
    if ref is None:
        return None
    userdata = instances.get(ref, {}).get("userdata")
    return userdata if isinstance(userdata, str) else None


def is_attack_action(action: dict[str, Any], monster: str) -> bool:
    type_name = action.get("type") or ""
    return type_name.startswith(f"snow.enemy.aifsm.{monster.capitalize()}_") and type_name.endswith(
        "ActionSetAttack"
    )


def extract_fixed_action_edges(file_graph: dict[str, Any], monster: str) -> list[dict[str, Any]]:
    """Return only direct, unique ActionEnd edges between numbered attack states."""
    states_by_id = {state["state_id"]: state for state in file_graph["states"]}
    edges = []
    for state in file_graph["states"]:
        source_actions = [
            action
            for action in state["actions"]
            if isinstance(action.get("action_no"), int) and is_attack_action(action, monster)
        ]
        if len(source_actions) != 1 or len(state["transitions"]) != 1:
            continue
        transition = state["transitions"][0]
        if transition["condition"].get("type") != "snow.enemy.behaviortree.EnemyActionEnd":
            continue
        target = states_by_id.get(transition.get("next_state_id"))
        if target is None:
            continue
        target_actions = [
            action
            for action in target["actions"]
            if isinstance(action.get("action_no"), int) and is_attack_action(action, monster)
        ]
        if len(target_actions) != 1:
            continue
        edges.append(
            {
                "source": file_graph["source"],
                "from_state_id": state["state_id"],
                "from_action_no": source_actions[0]["action_no"],
                "to_state_id": target["state_id"],
                "to_action_no": target_actions[0]["action_no"],
                "evidence": "unique_enemy_action_end_edge",
            }
        )
    return edges


def build_file_graph(document: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    source = document.get("source", "<unknown>")
    diagnostics: list[dict[str, Any]] = []
    instances = {
        instance["id"]: instance
        for instance in document.get("instances", [])
        if isinstance(instance.get("id"), int)
    }
    states = []
    state_ids: set[Any] = set()

    for instance in document.get("instances", []):
        if instance.get("type") != "snow.enemy.ThinkState":
            continue
        fields = fields_by_name(instance)
        state_id = fields.get("_ID")
        if state_id in state_ids:
            diagnostics.append(
                {
                    "code": "duplicate_state_id",
                    "source": source,
                    "instance_id": instance["id"],
                    "state_id": state_id,
                }
            )
        state_ids.add(state_id)
        actions = [
            action
            for value in fields.get("_ActionList", []) or []
            if (action := extract_action(value, instances, diagnostics, source, instance["id"])) is not None
        ]
        transitions = [
            transition
            for value in fields.get("_ConditionList", []) or []
            if (
                transition := extract_transition(
                    value, instances, diagnostics, source, instance["id"]
                )
            )
            is not None
        ]
        states.append(
            {
                "instance_id": instance["id"],
                "state_id": state_id,
                "tree_node_id": fields.get("_TreeNodeID"),
                "reference_userdata": extract_reference_userdata(
                    fields.get("_ReferenceThinkData"), instances
                ),
                "actions": actions,
                "transitions": transitions,
            }
        )

    return {"source": source, "states": states}, diagnostics


def build_behavior_graph(input_root: Path, monster: str) -> dict[str, Any]:
    file_graphs = []
    diagnostics: list[dict[str, Any]] = []
    action_catalog: dict[int, list[dict[str, Any]]] = defaultdict(list)
    condition_types: Counter[str] = Counter()
    fixed_action_edges: list[dict[str, Any]] = []

    for path in sorted(input_root.rglob("*.rsz.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        file_graph, file_diagnostics = build_file_graph(document)
        diagnostics.extend(file_diagnostics)
        if not file_graph["states"]:
            continue
        file_graphs.append(file_graph)
        fixed_action_edges.extend(extract_fixed_action_edges(file_graph, monster))
        for state in file_graph["states"]:
            for action in state["actions"]:
                action_no = action.get("action_no")
                if isinstance(action_no, int):
                    action_catalog[action_no].append(
                        {
                            "source": file_graph["source"],
                            "state_id": state["state_id"],
                            "instance_id": action["instance_id"],
                            "type": action["type"],
                            "stable_id": action["stable_id"],
                        }
                    )
            for transition in state["transitions"]:
                condition_type = transition["condition"].get("type")
                if condition_type:
                    condition_types[condition_type] += 1

    state_count = sum(len(file["states"]) for file in file_graphs)
    action_count = sum(
        len(state["actions"]) for file in file_graphs for state in file["states"]
    )
    transition_count = sum(
        len(state["transitions"]) for file in file_graphs for state in file["states"]
    )
    return {
        "schema_version": 1,
        "monster": monster,
        "summary": {
            "files_with_states": len(file_graphs),
            "state_count": state_count,
            "action_instance_count": action_count,
            "action_number_count": len(action_catalog),
            "transition_count": transition_count,
            "fixed_action_edge_count": len(fixed_action_edges),
            "diagnostic_count": len(diagnostics),
        },
        "action_catalog": {str(key): value for key, value in sorted(action_catalog.items())},
        "condition_type_counts": dict(sorted(condition_types.items())),
        "fixed_action_edges": fixed_action_edges,
        "files": file_graphs,
        "diagnostics": diagnostics,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_root", type=Path, help="RszAiDump JSON directory")
    parser.add_argument("output", type=Path, help="behavior graph JSON path")
    parser.add_argument("--monster", required=True, help="monster identifier, for example em032")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    graph = build_behavior_graph(args.input_root.resolve(), args.monster)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(graph, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    summary = graph["summary"]
    print(
        f"{args.monster}: {summary['files_with_states']} graph files, "
        f"{summary['state_count']} states, {summary['transition_count']} transitions, "
        f"{summary['action_number_count']} action numbers, "
        f"{summary['fixed_action_edge_count']} fixed attack edges, "
        f"{summary['diagnostic_count']} diagnostics"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
