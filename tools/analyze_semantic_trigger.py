#!/usr/bin/env python3
"""自动审核受限语义触发实验及其释放，不把一次成功升级为产品输入。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def analyze(payload: dict) -> dict:
    violations: list[str] = []
    if payload.get("kind") != "semantic_input_trigger":
        violations.append("unexpected_probe_kind")
    if payload.get("status") != "completed":
        violations.append("probe_not_completed")
    motion = payload.get("input_motion") or {}
    trigger = motion.get("semantic_trigger") or {}
    policy = trigger.get("policy")
    supported_policies = {
        "single_frame_trigger_only",
        "paired_stm_player_input_set_clear",
    }
    if policy not in supported_policies:
        violations.append("trigger_policy_missing_or_changed")
    if trigger.get("command") != "Escape":
        violations.append("command_not_allowlisted")
    if trigger.get("status") != "released":
        violations.append("trigger_release_not_verified")
    expected_writes = 2 if policy == "paired_stm_player_input_set_clear" else 1
    if trigger.get("write_count") != expected_writes:
        violations.append("write_count_out_of_policy")
    if policy == "paired_stm_player_input_set_clear" and (
            trigger.get("set_count") != 1 or trigger.get("clear_count") != 1):
        violations.append("paired_set_clear_count_invalid")
    if not isinstance(trigger.get("released_after_hid_cycles"), int) \
            or not 2 <= trigger["released_after_hid_cycles"] <= 3:
        violations.append("release_cycle_out_of_bounds")
    preflight = motion.get("preflight") or {}
    if policy == "paired_stm_player_input_set_clear":
        capture = preflight.get("stm_player_input_capture_contract") or {}
        if capture.get("policy") \
                != "bounded_read_only_stm_player_input_hook_capture" \
                or capture.get("hook_installed") is not True \
                or capture.get("instance_type") != "snow.StmPlayerInput" \
                or capture.get("refinput_matches_current") is not True \
                or capture.get("call_failures") != 0:
            violations.append("stm_player_input_capture_preflight_invalid")
    else:
        instance = preflight.get("player_input_instance_contract") or {}
        if instance.get("policy") != "bounded_read_only_player_input_queries" \
                or instance.get("call_failures") != 0:
            violations.append("player_input_preflight_invalid")
    if preflight.get("write_count") != 0:
        violations.append("preflight_adapter_writes_not_zero")
    neutral_gate = motion.get("neutral_gate")
    if neutral_gate is not None:
        if neutral_gate.get("policy") != "verified_neutral_node_stability" \
                or neutral_gate.get("status") != "ready" \
                or neutral_gate.get("node_name") not in {
                    "wait.main",
                    "wait.wait_pre_mot_end",
                    "atk.atk_wait.atk_wait_main.atk_wait_main",
                } \
                or not isinstance(neutral_gate.get("stable_frames"), int) \
                or neutral_gate["stable_frames"] < 15:
            violations.append("neutral_player_action_gate_invalid")
    action = payload.get("player_action") or {}
    before = action.get("before") or {}
    observed = action.get("observed") or []
    semantic_action_observed = any(
        item.get("node_id") != before.get("node_id")
        or item.get("node_name") != before.get("node_name")
        for item in observed
    )
    expected_escape_observed = any(
        isinstance(item.get("node_name"), str)
        and item["node_name"].startswith("atk.esc_")
        for item in observed
    )
    return {
        "schema_version": 2,
        "status": (
            "verified_paired_stm_player_trigger"
            if not violations and policy == "paired_stm_player_input_set_clear"
            else "verified_single_frame_trigger"
            if not violations
            else "invalid_trigger_experiment"
        ),
        "violations": violations,
        "experiment_succeeded": not violations,
        "command": trigger.get("command"),
        "write_count": trigger.get("write_count"),
        "release_read_count": trigger.get("read_count"),
        "set_count": trigger.get("set_count"),
        "clear_count": trigger.get("clear_count"),
        "released_after_hid_cycles": trigger.get("released_after_hid_cycles"),
        "semantic_action_observed": semantic_action_observed,
        "expected_escape_observed": expected_escape_observed,
        "neutral_gate": neutral_gate,
        "observed_nodes": observed,
        "next_gate": (
            "correlate_allowlisted_weapon_command_in_player_calibration"
            if not violations and expected_escape_observed
            else "adjust_trigger_timing_without_expanding_write_scope"
            if not violations
            else "stop_and_review_trigger_failure"
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
