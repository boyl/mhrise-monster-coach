import copy
import unittest

from tools.analyze_training_timeline_acceptance import analyze


def payload(outcome="observed_hit"):
    classification = {
        "outcome": outcome,
        "score": "unclassified",
        "label": "观察到受击",
        "tone": "failure",
        "reason": "damage_observed",
    }
    events = [
        {"sequence": 1, "kind": "action_start", "data": {
            "action": "19", "move_name": "咆哮", "state_key": "4:19"}},
        {"sequence": 2, "kind": "hitbox_open", "data": {
            "motion_frame": 38.25, "active_count": 2, "source": "monster_coach_native"}},
        {"sequence": 3, "kind": "player_status", "data": {"damage": True}},
        {"sequence": 4, "kind": "hitbox_close", "data": {
            "motion_frame": 45.25, "source": "monster_coach_native"}},
        {"sequence": 5, "kind": "result", "data": {
            "outcome": outcome,
            "outcome_tracking": False,
            "completion_basis": "behavior_tree_attack_exit",
            "classification": copy.deepcopy(classification),
        }},
    ]
    return {
        "kind": "training_scenario_acceptance",
        "status": "completed",
        "training_acceptance": {
            "state": "completed",
            "scenario_id": "tigrex_roar_single",
            "execution_mode": "forced_single",
            "completed_rounds": 5,
            "target_rounds": 5,
        },
        "training_timeline": {
            "schema_version": 3,
            "active": False,
            "dropped_events": 0,
            "last_round": {
                "schema_version": 3,
                "round_id": 5,
                "outcome": outcome,
                "classification": classification,
                "dropped_events": 0,
                "events": events,
            },
        },
    }


def response_evidence():
    return {
        "schema_version": 1,
        "session_id": None,
        "scenario_id": "tigrex_roar_single",
        "response_step": "dodge",
        "status": "sent",
        "policy": "external_allowlisted_player_input_with_runtime_binding",
        "binding": {
            "policy": "read_only_exact_dictionary_lookup",
            "source_name": "Space",
        },
        "expected_timeline_event": {"kind": "player_status", "flag": "escape"},
        "attempts": [{"round_id": 5, "status": "sent"}],
    }


class TrainingTimelineAcceptanceAnalysisTests(unittest.TestCase):
    def test_accepts_complete_observed_hit_without_scoring_success(self):
        result = analyze(payload())
        self.assertEqual(result["status"], "verified_complete_training_timeline")
        self.assertTrue(result["contract_valid"])
        self.assertTrue(result["ready_for_product_acceptance"])
        self.assertEqual(result["timeline"]["hitbox_windows"][0]["duration_frames"], 7.0)
        self.assertEqual(result["outcome"]["evidence_level"], "observed_failure")
        self.assertFalse(result["outcome"]["scoreable"])

    def test_accepts_verified_action_transition_completion(self):
        data = payload()
        data["training_timeline"]["last_round"]["events"][-1]["data"][
            "completion_basis"
        ] = "action_transition"
        result = analyze(data)
        self.assertEqual(result["status"], "verified_complete_training_timeline")
        self.assertEqual(result["timeline"]["completion_basis"], "action_transition")
        self.assertTrue(result["contract_valid"])

    def test_keeps_community_success_as_candidate(self):
        data = payload("response_success_candidate")
        classification = data["training_timeline"]["last_round"]["classification"]
        classification.update({
            "score": "unclassified", "label": "观察到见切斩成功候选节点",
            "tone": "muted", "reason": "unverified_success_node",
        })
        events = data["training_timeline"]["last_round"]["events"]
        events[2] = {"sequence": 3, "kind": "player_action", "data": {
            "semantic": "foresight_slash", "role": "success",
            "mapping_status": "community_candidate",
        }}
        events[-1]["data"]["classification"] = copy.deepcopy(classification)
        result = analyze(data)
        self.assertEqual(result["outcome"]["evidence_level"], "candidate_success")
        self.assertFalse(result["outcome"]["scoreable"])
        self.assertTrue(result["contract_valid"])

    def test_accepts_only_verified_mapping_as_counter_success(self):
        data = payload("counter_success")
        classification = data["training_timeline"]["last_round"]["classification"]
        classification.update({
            "score": "success", "label": "见切斩成功", "tone": "success",
            "reason": "verified_success_node",
        })
        events = data["training_timeline"]["last_round"]["events"]
        events[2] = {"sequence": 3, "kind": "player_action", "data": {
            "semantic": "foresight_slash", "role": "success",
            "mapping_status": "verified_runtime",
        }}
        events[-1]["data"]["classification"] = copy.deepcopy(classification)
        result = analyze(data)
        self.assertEqual(result["outcome"]["evidence_level"], "verified_success")
        self.assertTrue(result["outcome"]["scoreable"])
        self.assertEqual(result["violations"], [])

    def test_rejects_counter_success_from_unverified_mapping(self):
        data = payload("counter_success")
        classification = data["training_timeline"]["last_round"]["classification"]
        classification.update({"score": "success", "label": "见切斩成功"})
        events = data["training_timeline"]["last_round"]["events"]
        events[2] = {"sequence": 3, "kind": "player_action", "data": {
            "role": "success", "mapping_status": "community_candidate"}}
        events[-1]["data"]["classification"] = copy.deepcopy(classification)
        result = analyze(data)
        self.assertFalse(result["contract_valid"])
        self.assertIn("classification_evidence_mismatch", result["violations"])

    def test_partial_timeline_is_explicit_without_invalidating_classification(self):
        data = payload()
        events = data["training_timeline"]["last_round"]["events"]
        data["training_timeline"]["last_round"]["events"] = [events[0], events[2], events[4]]
        for sequence, event in enumerate(data["training_timeline"]["last_round"]["events"], 1):
            event["sequence"] = sequence
        result = analyze(data)
        self.assertEqual(result["status"], "verified_partial_training_timeline")
        self.assertIn("complete_hitbox_window_missing", result["coverage_gaps"])
        self.assertTrue(result["contract_valid"])

    def test_rejects_dropped_events_and_outcome_mismatch(self):
        data = payload()
        data["training_timeline"]["last_round"]["dropped_events"] = 2
        data["training_timeline"]["last_round"]["events"][-1]["data"]["outcome"] = "unclassified"
        result = analyze(data)
        self.assertEqual(result["status"], "invalid_training_timeline")
        self.assertIn("timeline_events_dropped", result["violations"])
        self.assertIn("result_outcome_mismatch", result["violations"])

    def test_rejects_incomplete_training_rounds(self):
        data = payload()
        data["training_acceptance"]["completed_rounds"] = 4
        result = analyze(data)
        self.assertIn("training_round_count_mismatch", result["violations"])

    def test_rejects_candidate_scored_as_success(self):
        data = payload("response_attempt")
        classification = data["training_timeline"]["last_round"]["classification"]
        classification.update({"score": "success", "label": "已尝试见切斩"})
        events = data["training_timeline"]["last_round"]["events"]
        events[2] = {"sequence": 3, "kind": "player_action", "data": {
            "role": "attempt", "mapping_status": "community_candidate"}}
        events[-1]["data"]["classification"] = copy.deepcopy(classification)
        result = analyze(data)
        self.assertIn("classification_score_mismatch", result["violations"])

    def test_correlates_external_dodge_with_timeline_escape(self):
        data = payload("evade_attempt")
        data["session_id"] = "response-session"
        classification = data["training_timeline"]["last_round"]["classification"]
        classification.update({
            "score": "unclassified", "label": "观察到回避动作，结果待确认",
            "tone": "muted", "reason": "escape_status_without_success_evidence",
        })
        events = data["training_timeline"]["last_round"]["events"]
        events[2] = {"sequence": 3, "kind": "player_status", "data": {
            "escape": True, "damage": False, "guard": False}}
        events[-1]["data"]["classification"] = copy.deepcopy(classification)
        response = response_evidence()
        response["session_id"] = "response-session"
        result = analyze(data, response)
        self.assertEqual(result["response"]["status"], "verified")
        self.assertTrue(result["response"]["timeline_event_observed"])
        self.assertEqual(result["violations"], [])

    def test_rejects_sent_response_without_runtime_escape_event(self):
        data = payload()
        data["session_id"] = "response-session"
        response = response_evidence()
        response["session_id"] = "response-session"
        result = analyze(data, response)
        self.assertEqual(result["response"]["status"], "invalid")
        self.assertIn("response_timeline_event_not_observed", result["violations"])


if __name__ == "__main__":
    unittest.main()
