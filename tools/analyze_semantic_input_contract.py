#!/usr/bin/env python3
"""自动审核 MHR 语义输入元数据探针，不把候选方法升级为可写入口。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


EXPECTED_TYPES = (
    "snow.StmInputManager",
    "snow.StmPlayerInput",
    "snow.player.PlayerInput",
    "snow.StmInputManager.InputUI",
)
QUERY_METHODS = {"getOn", "getTrg", "getRel", "getDelay", "isOn", "isTrg", "isRel", "isDelay"}
UPDATE_TERMS = ("update", "command", "input", "button", "trigger")


def _signature(method: dict) -> str:
    return f"{method.get('name')}({','.join(method.get('param_types') or [])})"


def _candidate_methods(type_entry: dict) -> list[dict]:
    result = []
    seen = set()
    for method in type_entry.get("methods") or []:
        name = str(method.get("name") or "")
        lower = name.lower()
        if name in QUERY_METHODS or name.startswith(("get", "is")):
            continue
        if not any(term in lower for term in UPDATE_TERMS):
            continue
        signature = _signature(method)
        if signature in seen:
            continue
        seen.add(signature)
        result.append({
            "type": type_entry.get("type"),
            "signature": signature,
            "instance_available": type_entry.get("instance_available") is True,
            "is_static": method.get("is_static") is True,
            "classification": "metadata_candidate_only",
        })
    return sorted(result, key=lambda item: (str(item["type"]), item["signature"]))


def analyze(payload: dict) -> dict:
    input_motion = payload.get("input_motion") or payload
    contract = input_motion.get("semantic_input_contract") or {}
    violations: list[str] = []
    if contract.get("policy") != "read_only_exact_semantic_input_metadata":
        violations.append("semantic_contract_policy_missing_or_changed")
    if contract.get("gameplay_method_calls") != 0:
        violations.append("gameplay_method_calls_not_zero")
    if contract.get("gameplay_writes") != 0:
        violations.append("gameplay_writes_not_zero")

    entries = {str(item.get("type")): item for item in contract.get("types") or []}
    missing_entries = [name for name in EXPECTED_TYPES if name not in entries]
    unavailable_types = [name for name in EXPECTED_TYPES
                         if name in entries and entries[name].get("available") is not True]
    owner_candidates = [name for name in EXPECTED_TYPES
                        if name in entries and entries[name].get("instance_available") is True]

    query_signatures = []
    update_candidates = []
    for name in EXPECTED_TYPES:
        entry = entries.get(name) or {}
        for method in entry.get("semantic_query_methods") or []:
            query_signatures.append({"type": name, "signature": _signature(method)})
        update_candidates.extend(_candidate_methods(entry))

    command_enum = contract.get("command_enum") or {}
    command_names = [str(item.get("name")) for item in command_enum.get("values") or []]
    if command_enum.get("available") is not True or not command_names:
        violations.append("command_enum_unavailable_or_empty")
    if missing_entries:
        violations.append("expected_type_entries_missing")

    viable_updates = [item for item in update_candidates
                      if item["instance_available"] or item["is_static"]]
    if violations:
        status = "invalid_read_only_contract"
    elif viable_updates:
        status = "candidate_owner_found"
    else:
        status = "no_callable_owner_candidate"

    return {
        "schema_version": 1,
        "status": status,
        "experiment_allowed": False,
        "violations": violations,
        "command_enum_count": len(command_names),
        "command_names": command_names,
        "missing_type_entries": missing_entries,
        "unavailable_types": unavailable_types,
        "instance_owner_candidates": owner_candidates,
        "semantic_query_signatures": sorted(
            query_signatures, key=lambda item: (item["type"], item["signature"])),
        "update_candidates": update_candidates,
        "viable_update_candidates": viable_updates,
        "next_gate": (
            "separate_guarded_press_release_experiment_required"
            if status == "candidate_owner_found"
            else "stop_semantic_write_route_or_collect_missing_metadata"
        ),
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
