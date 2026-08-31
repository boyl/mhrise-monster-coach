#!/usr/bin/env python3
"""自动审核训练场景的结果分类与单轮判定时间轴证据。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


VERIFIED_MAPPINGS = {"verified", "verified_runtime", "product_verified"}
KNOWN_OUTCOMES = {
    "hit",
    "observed_hit",
    "counter_success",
    "no_damage",
    "response_success_candidate",
    "response_attempt",
    "guard_attempt",
    "evade_attempt",
    "unclassified",
    "interrupted",
}


def _events_of_kind(events: list[dict[str, Any]], kind: str) -> list[dict[str, Any]]:
    return [event for event in events if event.get("kind") == kind]


def _has_damage(events: list[dict[str, Any]]) -> bool:
    for event in events:
        data = event.get("data") or {}
        if event.get("kind") == "damage":
            return True
        if event.get("kind") == "player_status" and data.get("damage") is True:
            return True
    return False


def _classification_evidence(
        outcome: str, events: list[dict[str, Any]], result_data: dict[str, Any]) -> tuple[bool, str, bool]:
    player_actions = [event.get("data") or {} for event in _events_of_kind(events, "player_action")]
    player_status = [event.get("data") or {} for event in _events_of_kind(events, "player_status")]
    damage = _has_damage(events)
    verified_success = any(
        item.get("role") == "success" and item.get("mapping_status") in VERIFIED_MAPPINGS
        for item in player_actions
    )
    candidate_success = any(
        item.get("role") == "success" and item.get("mapping_status") not in VERIFIED_MAPPINGS
        for item in player_actions
    )

    if outcome == "hit":
        return damage and result_data.get("outcome_tracking") is True, "verified_failure", True
    if outcome == "observed_hit":
        return damage, "observed_failure", False
    if outcome == "counter_success":
        return verified_success and not damage, "verified_success", True
    if outcome == "no_damage":
        health_comparisons = result_data.get("health_comparisons")
        return (
            result_data.get("outcome_tracking") is True
            and isinstance(health_comparisons, (int, float))
            and health_comparisons >= 1
            and not damage
        ), "health_tracked_no_damage", True
    if outcome == "response_success_candidate":
        return candidate_success and not damage, "candidate_success", False
    if outcome == "response_attempt":
        return any(item.get("role") == "attempt" for item in player_actions), "response_attempt", False
    if outcome == "guard_attempt":
        return any(item.get("guard") is True for item in player_status), "guard_attempt", False
    if outcome == "evade_attempt":
        return any(item.get("escape") is True for item in player_status), "evade_attempt", False
    if outcome == "interrupted":
        return True, "interrupted", False
    return outcome == "unclassified", "unclassified", False


def _hitbox_windows(events: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    windows: list[dict[str, Any]] = []
    gaps: list[str] = []
    open_event: dict[str, Any] | None = None
    for event in events:
        if event.get("kind") == "hitbox_open":
            if open_event is not None:
                gaps.append("overlapping_hitbox_open")
            open_event = event
        elif event.get("kind") == "hitbox_close":
            if open_event is None:
                gaps.append("hitbox_close_without_open")
                continue
            start = (open_event.get("data") or {}).get("motion_frame")
            end = (event.get("data") or {}).get("motion_frame")
            if not isinstance(start, (int, float)) or not isinstance(end, (int, float)) or end < start:
                gaps.append("invalid_hitbox_motion_frames")
            else:
                windows.append({
                    "open_sequence": open_event.get("sequence"),
                    "close_sequence": event.get("sequence"),
                    "start_motion_frame": start,
                    "end_motion_frame": end,
                    "duration_frames": end - start,
                    "active_count": (open_event.get("data") or {}).get("active_count"),
                    "source": (open_event.get("data") or {}).get("source"),
                })
            open_event = None
    if open_event is not None:
        gaps.append("hitbox_open_without_close")
    if not windows:
        gaps.append("complete_hitbox_window_missing")
    return windows, list(dict.fromkeys(gaps))


def _analyze_response(
        payload: dict[str, Any], last_round: dict[str, Any], events: list[dict[str, Any]],
        response_evidence: dict[str, Any] | None) -> tuple[dict[str, Any] | None, list[str]]:
    if response_evidence is None:
        return None, []
    violations: list[str] = []
    if response_evidence.get("schema_version") != 1:
        violations.append("response_schema_invalid")
    if response_evidence.get("session_id") != payload.get("session_id"):
        violations.append("response_session_mismatch")
    if response_evidence.get("scenario_id") \
            != (payload.get("training_acceptance") or {}).get("scenario_id"):
        violations.append("response_scenario_mismatch")
    if response_evidence.get("policy") \
            != "external_allowlisted_player_input_with_runtime_binding":
        violations.append("response_policy_invalid")
    if response_evidence.get("response_step") != "dodge":
        violations.append("response_step_not_allowlisted")
    if response_evidence.get("status") != "sent":
        violations.append("response_not_sent")
    attempts = response_evidence.get("attempts")
    attempts = attempts if isinstance(attempts, list) else []
    sent_attempts = [item for item in attempts if item.get("status") == "sent"]
    if len(attempts) != 1 or len(sent_attempts) != 1:
        violations.append("response_attempt_count_invalid")
    elif str(sent_attempts[0].get("round_id")) != str(last_round.get("round_id")):
        violations.append("response_round_mismatch")
    binding = response_evidence.get("binding") or {}
    if binding.get("policy") != "read_only_exact_dictionary_lookup" \
            or not binding.get("source_name"):
        violations.append("response_binding_unverified")
    expected = response_evidence.get("expected_timeline_event") or {}
    if expected != {"kind": "player_status", "flag": "escape"}:
        violations.append("response_expected_event_contract_invalid")
    observed = any(
        event.get("kind") == "player_status"
        and (event.get("data") or {}).get("escape") is True
        for event in events
    )
    if not observed:
        violations.append("response_timeline_event_not_observed")
    return {
        "status": "verified" if not violations else "invalid",
        "step": response_evidence.get("response_step"),
        "binding_source": binding.get("source_name"),
        "attempt_count": len(attempts),
        "timeline_event_observed": observed,
    }, violations


def analyze(
        payload: dict[str, Any], response_evidence: dict[str, Any] | None = None) -> dict[str, Any]:
    violations: list[str] = []
    coverage_gaps: list[str] = []

    if payload.get("kind") != "training_scenario_acceptance":
        violations.append("unexpected_probe_kind")
    if payload.get("status") != "completed":
        violations.append("probe_not_completed")

    acceptance = payload.get("training_acceptance") or {}
    completed_rounds = acceptance.get("completed_rounds")
    target_rounds = acceptance.get("target_rounds")
    if acceptance.get("state") != "completed":
        violations.append("training_not_completed")
    if not isinstance(target_rounds, int) or target_rounds < 1 \
            or completed_rounds != target_rounds:
        violations.append("training_round_count_mismatch")

    timeline = payload.get("training_timeline") or {}
    last_round = timeline.get("last_round") or {}
    if timeline.get("schema_version") != 3 or last_round.get("schema_version") != 3:
        violations.append("unsupported_timeline_schema")
    timeline_active = timeline.get("active")
    if timeline_active not in {True, False}:
        violations.append("timeline_active_flag_invalid")
    dropped_events = last_round.get("dropped_events", timeline.get("dropped_events", 0))
    if dropped_events != 0:
        violations.append("timeline_events_dropped")

    events = last_round.get("events")
    if not isinstance(events, list) or not events:
        events = []
        violations.append("timeline_events_missing")
    else:
        sequences = [event.get("sequence") for event in events]
        if any(not isinstance(value, int) for value in sequences) \
                or sequences != list(range(sequences[0], sequences[0] + len(sequences))):
            violations.append("event_sequence_not_contiguous")
        if events[0].get("kind") != "action_start":
            violations.append("action_start_not_first")
        if events[-1].get("kind") != "result" or len(_events_of_kind(events, "result")) != 1:
            violations.append("terminal_result_invalid")

    result_data = (events[-1].get("data") or {}) if events and events[-1].get("kind") == "result" else {}
    post_round_observation_active = False
    if timeline_active is True:
        active_events = timeline.get("events")
        active_events = active_events if isinstance(active_events, list) else []
        active_start = active_events[0] if active_events else {}
        active_data = active_start.get("data") or {}
        completed_state_key = result_data.get("state_key")
        active_state_key = active_data.get("state_key")
        if active_start.get("kind") == "action_start" \
                and isinstance(completed_state_key, str) \
                and isinstance(active_state_key, str) \
                and active_state_key != completed_state_key:
            post_round_observation_active = True
        else:
            violations.append("target_timeline_still_active")
    outcome = last_round.get("outcome")
    classification = last_round.get("classification") or result_data.get("classification") or {}
    expected_root_action = acceptance.get("root_action")
    if expected_root_action is not None \
            and str(result_data.get("action")) != str(expected_root_action):
        violations.append("target_round_action_mismatch")
    if outcome not in KNOWN_OUTCOMES:
        violations.append("unknown_outcome")
    if result_data.get("outcome") != outcome:
        violations.append("result_outcome_mismatch")
    if classification.get("outcome") != outcome:
        violations.append("classification_outcome_mismatch")
    if result_data.get("classification") != classification:
        violations.append("result_classification_mismatch")
    expected_score = (
        "failure" if outcome == "hit"
        else "success" if outcome in {"counter_success", "no_damage"}
        else "unclassified"
    )
    if classification.get("score") != expected_score:
        violations.append("classification_score_mismatch")

    evidence_consistent, evidence_level, scoreable = _classification_evidence(
        outcome, events, result_data)
    if not evidence_consistent:
        violations.append("classification_evidence_mismatch")

    windows, hitbox_gaps = _hitbox_windows(events)
    coverage_gaps.extend(hitbox_gaps)
    completion_basis = result_data.get("completion_basis")
    if completion_basis not in {"behavior_tree_attack_exit", "action_transition"}:
        coverage_gaps.append(
            "completion_basis_missing" if completion_basis is None
            else "completion_basis_not_verified"
        )

    response, response_violations = _analyze_response(
        payload, last_round, events, response_evidence)
    violations.extend(response_violations)

    violations = list(dict.fromkeys(violations))
    coverage_gaps = list(dict.fromkeys(coverage_gaps))
    contract_valid = not violations
    complete_timeline = contract_valid and not coverage_gaps
    return {
        "schema_version": 1,
        "status": (
            "verified_complete_training_timeline" if complete_timeline
            else "verified_partial_training_timeline" if contract_valid
            else "invalid_training_timeline"
        ),
        "contract_valid": contract_valid,
        "ready_for_product_acceptance": complete_timeline and evidence_level != "unclassified",
        "violations": violations,
        "coverage_gaps": coverage_gaps,
        "training": {
            "scenario_id": acceptance.get("scenario_id"),
            "execution_mode": acceptance.get("execution_mode"),
            "completed_rounds": completed_rounds,
            "target_rounds": target_rounds,
        },
        "timeline": {
            "schema_version": timeline.get("schema_version"),
            "round_id": last_round.get("round_id"),
            "event_count": len(events),
            "event_kinds": [event.get("kind") for event in events],
            "dropped_events": dropped_events,
            "completion_basis": completion_basis,
            "hitbox_windows": windows,
            "player_action_events": len(_events_of_kind(events, "player_action")),
            "player_status_events": len(_events_of_kind(events, "player_status")),
            "post_round_observation_active": post_round_observation_active,
        },
        "outcome": {
            "value": outcome,
            "label": classification.get("label"),
            "score": classification.get("score"),
            "tone": classification.get("tone"),
            "reason": classification.get("reason"),
            "evidence_level": evidence_level,
            "evidence_consistent": evidence_consistent,
            "scoreable": scoreable,
        },
        "response": response,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--response-evidence", type=Path)
    args = parser.parse_args()
    payload = json.loads(args.evidence.read_text(encoding="utf-8-sig"))
    response_evidence = json.loads(args.response_evidence.read_text(encoding="utf-8-sig")) \
        if args.response_evidence else None
    result = analyze(payload, response_evidence)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)


if __name__ == "__main__":
    main()
