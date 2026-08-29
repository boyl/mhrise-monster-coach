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
MUTATION_TERMS = ("set", "clear", "reset", "add", "remove", "toggle")
PLAYER_INPUT_OWNER_TYPES = {"snow.StmPlayerInput", "snow.player.PlayerInput"}


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


def _contract_methods_with_level(contract: dict, hierarchy: dict | None = None):
    for method in contract.get("methods") or []:
        yield contract.get("type"), method
    for level in (hierarchy or {}).get("levels") or []:
        for method in level.get("methods") or []:
            yield level.get("type"), method


def _player_owner_fields(contract: dict) -> list[dict]:
    result = []
    for level in (contract.get("hierarchy") or {}).get("levels") or []:
        for field in level.get("fields") or []:
            declared_type = field.get("type")
            object_type = field.get("object_type")
            if declared_type not in PLAYER_INPUT_OWNER_TYPES \
                    and object_type not in PLAYER_INPUT_OWNER_TYPES:
                continue
            result.append({
                "level_type": level.get("type"),
                "field": field.get("name"),
                "declared_type": declared_type,
                "object_available": field.get("object_available") is True,
                "object_type": object_type,
                "classification": (
                    "resolved_current_player_owner"
                    if field.get("object_available") is True
                    and object_type in PLAYER_INPUT_OWNER_TYPES
                    else "declared_owner_metadata_only"
                ),
            })
    return sorted(result, key=lambda item: (
        str(item["level_type"]), str(item["field"]), str(item["object_type"])))


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
    bitset_contract = input_motion.get("semantic_bitset_contract") or {}
    bitset_mutator_candidates = []
    bitset_object_types = []
    if bitset_contract.get("policy") != "bounded_read_only_semantic_bitset_getters":
        violations.append("semantic_bitset_contract_missing_or_changed")
    if bitset_contract.get("gameplay_writes") != 0:
        violations.append("semantic_bitset_gameplay_writes_not_zero")
    if bitset_contract.get("call_failures") != 0:
        violations.append("semantic_bitset_getter_call_failed")
    call_count = bitset_contract.get("call_count")
    max_calls = bitset_contract.get("max_calls")
    if not isinstance(call_count, int) or not isinstance(max_calls, int) or call_count > max_calls:
        violations.append("semantic_bitset_call_budget_invalid")
    for getter in bitset_contract.get("getters") or []:
        object_type = getter.get("object_type")
        if object_type and object_type not in bitset_object_types:
            bitset_object_types.append(object_type)
        object_contract = getter.get("object_contract") or {}
        for declaring_type, method in _contract_methods_with_level(
                object_contract, getter.get("object_hierarchy") or {}):
            name = str(method.get("name") or "")
            if not any(term in name.lower() for term in MUTATION_TERMS):
                continue
            candidate = {
                "source_getter": getter.get("name"),
                "object_type": object_type,
                "declaring_type": declaring_type,
                "signature": _signature(method),
                "is_static": method.get("is_static") is True,
                "classification": "metadata_candidate_only",
            }
            if candidate not in bitset_mutator_candidates:
                bitset_mutator_candidates.append(candidate)
    bitset_mutator_candidates.sort(
        key=lambda item: (str(item["object_type"]), str(item["declaring_type"]),
                          item["signature"], str(item["source_getter"])))

    owner_contract = input_motion.get("player_input_owner_contract") or {}
    input_schema = input_motion.get("schema_version")
    if isinstance(input_schema, int) and input_schema >= 9:
        if owner_contract.get("policy") != "read_only_current_player_input_fields":
            violations.append("player_input_owner_contract_missing_or_changed")
        if owner_contract.get("gameplay_method_calls") != 0:
            violations.append("player_input_owner_method_calls_not_zero")
        if owner_contract.get("gameplay_writes") != 0:
            violations.append("player_input_owner_writes_not_zero")
    player_owner_fields = _player_owner_fields(owner_contract)
    resolved_player_owners = [item for item in player_owner_fields
                              if item["classification"] == "resolved_current_player_owner"]
    instance_contract = input_motion.get("player_input_instance_contract") or {}
    if isinstance(input_schema, int) and input_schema >= 10:
        if instance_contract.get("policy") != "bounded_read_only_player_input_queries":
            violations.append("player_input_instance_contract_missing_or_changed")
        if instance_contract.get("gameplay_writes") != 0:
            violations.append("player_input_instance_writes_not_zero")
        if instance_contract.get("call_failures") != 0:
            violations.append("player_input_instance_query_failed")
    instance_call_count = instance_contract.get("call_count")
    instance_max_calls = instance_contract.get("max_calls")
    if isinstance(input_schema, int) and input_schema >= 10 and (
            not isinstance(instance_call_count, int)
            or not isinstance(instance_max_calls, int)
            or instance_call_count > instance_max_calls):
        violations.append("player_input_instance_call_budget_invalid")
    resolved_queries = [item for item in instance_contract.get("queries") or []
                        if item.get("status") == "resolved"]
    instance_read_verified = bool(
        resolved_player_owners
        and instance_contract.get("instance_available") is True
        and instance_contract.get("instance_type") in PLAYER_INPUT_OWNER_TYPES
        and isinstance(instance_call_count, int)
        and isinstance(instance_max_calls, int)
        and instance_call_count == instance_max_calls
        and instance_call_count > 0
        and instance_contract.get("call_failures") == 0
        and len(resolved_queries) == instance_call_count
    )
    component_contract = input_motion.get("stm_player_input_component_contract") or {}
    component_read_verified = False
    if isinstance(input_schema, int) and input_schema >= 12:
        expected_policy = (
            "bounded_read_only_stm_manager_sibling_component"
            if input_schema >= 13
            else "bounded_read_only_stm_player_input_component"
        )
        if component_contract.get("policy") != expected_policy:
            violations.append("stm_player_input_component_contract_missing_or_changed")
        if input_schema >= 13 and (
                component_contract.get("lookup_source")
                != "snow.StmInputManager.GameObject"
                or component_contract.get("input_manager_available") is not True):
            violations.append("stm_player_input_manager_sibling_lookup_not_verified")
        if component_contract.get("gameplay_writes") != 0:
            violations.append("stm_player_input_component_writes_not_zero")
        if component_contract.get("call_failures") != 0:
            violations.append("stm_player_input_component_query_failed")
        methods = component_contract.get("methods") or {}
        component_read_verified = bool(
            component_contract.get("component_available") is True
            and component_contract.get("component_type") == "snow.StmPlayerInput"
            and component_contract.get("refinput_available") is True
            and component_contract.get("refinput_type") == "snow.player.PlayerInput"
            and component_contract.get("refinput_matches_current") is True
            and component_contract.get("call_count") == 1
            and component_contract.get("max_calls") == 1
            and component_contract.get("call_failures") == 0
            and (component_contract.get("query") or {}).get("status") == "resolved"
            and all((methods.get(name) or {}).get("available") is True
                    for name in ("set_button", "clear_button", "is_delay"))
        )
        if not component_read_verified:
            violations.append("stm_player_input_component_not_verified")

    if violations:
        status = "invalid_read_only_contract"
    elif component_read_verified:
        status = "stm_player_input_component_read_contract_verified"
    elif instance_read_verified:
        status = "player_input_read_contract_verified"
    elif resolved_player_owners:
        status = "player_input_instance_candidate_found"
    elif bitset_mutator_candidates:
        status = "bitset_mutator_candidate_found"
    elif viable_updates:
        status = "read_only_owner_without_mutator"
    else:
        status = "no_callable_owner_candidate"

    return {
        "schema_version": 2,
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
        "semantic_bitset_call_count": call_count,
        "semantic_bitset_max_calls": max_calls,
        "semantic_bitset_object_types": sorted(bitset_object_types),
        "bitset_mutator_candidates": bitset_mutator_candidates,
        "player_available": owner_contract.get("player_available") is True,
        "player_type": owner_contract.get("player_type"),
        "player_input_owner_fields": player_owner_fields,
        "resolved_player_input_owners": resolved_player_owners,
        "player_input_instance_type": instance_contract.get("instance_type"),
        "player_input_query_call_count": instance_call_count,
        "player_input_query_max_calls": instance_max_calls,
        "player_input_queries": instance_contract.get("queries") or [],
        "stm_player_input_component": component_contract,
        "next_gate": (
            "design_component_scoped_press_release_experiment"
            if status == "stm_player_input_component_read_contract_verified"
            else "design_separate_guarded_semantic_press_release_experiment"
            if status == "player_input_read_contract_verified"
            else
            "verify_player_input_instance_read_contract"
            if status == "player_input_instance_candidate_found"
            else
            "separate_guarded_press_release_experiment_required"
            if status == "bitset_mutator_candidate_found"
            else "locate_stm_player_input_instance"
            if status == "read_only_owner_without_mutator"
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
