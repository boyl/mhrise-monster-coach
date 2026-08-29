import unittest

from tools.analyze_semantic_trigger import analyze


def payload():
    return {
        "kind": "semantic_input_trigger",
        "status": "completed",
        "input_motion": {
            "neutral_gate": {
                "policy": "verified_neutral_node_stability",
                "status": "ready",
                "node_id": 1,
                "node_name": "wait.main",
                "required_frames": 15,
                "stable_frames": 15,
            },
            "preflight": {
                "write_count": 0,
                "player_input_instance_contract": {
                    "policy": "bounded_read_only_player_input_queries",
                    "call_failures": 0,
                },
            },
            "semantic_trigger": {
                "policy": "single_frame_trigger_only",
                "command": "Escape",
                "status": "released",
                "write_count": 1,
                "read_count": 1,
                "released_after_hid_cycles": 2,
            },
        },
        "player_action": {
            "before": {"node_id": 1, "node_name": "wait.main"},
            "observed": [{"node_id": 2, "node_name": "atk.esc_front"}],
        },
    }


class SemanticTriggerAnalysisTests(unittest.TestCase):
    def test_accepts_paired_captured_stm_player_trigger(self):
        data = payload()
        trigger = data["input_motion"]["semantic_trigger"]
        trigger.update({
            "policy": "paired_stm_player_input_set_clear",
            "write_count": 2,
            "set_count": 1,
            "clear_count": 1,
        })
        data["input_motion"]["preflight"]["stm_player_input_capture_contract"] = {
            "policy": "bounded_read_only_stm_player_input_hook_capture",
            "hook_installed": True,
            "instance_type": "snow.StmPlayerInput",
            "refinput_matches_current": True,
            "call_failures": 0,
        }

        result = analyze(data)

        self.assertEqual(result["status"], "verified_paired_stm_player_trigger")
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["set_count"], 1)
        self.assertEqual(result["clear_count"], 1)

    def test_rejects_unpaired_captured_stm_player_trigger(self):
        data = payload()
        trigger = data["input_motion"]["semantic_trigger"]
        trigger.update({
            "policy": "paired_stm_player_input_set_clear",
            "write_count": 1,
            "set_count": 1,
            "clear_count": 0,
        })
        data["input_motion"]["preflight"]["stm_player_input_capture_contract"] = {
            "policy": "bounded_read_only_stm_player_input_hook_capture",
            "hook_installed": True,
            "instance_type": "snow.StmPlayerInput",
            "refinput_matches_current": True,
            "call_failures": 0,
        }

        result = analyze(data)

        self.assertEqual(result["status"], "invalid_trigger_experiment")
        self.assertIn("write_count_out_of_policy", result["violations"])
        self.assertIn("paired_set_clear_count_invalid", result["violations"])

    def test_accepts_one_write_natural_release_and_action_change(self):
        result = analyze(payload())
        self.assertEqual(result["status"], "verified_single_frame_trigger")
        self.assertTrue(result["experiment_succeeded"])
        self.assertTrue(result["semantic_action_observed"])
        self.assertTrue(result["expected_escape_observed"])
        self.assertEqual(result["violations"], [])

    def test_rejects_missing_release_or_extra_write(self):
        data = payload()
        trigger = data["input_motion"]["semantic_trigger"]
        trigger["status"] = "injected"
        trigger["write_count"] = 2
        result = analyze(data)
        self.assertEqual(result["status"], "invalid_trigger_experiment")
        self.assertIn("trigger_release_not_verified", result["violations"])
        self.assertIn("write_count_out_of_policy", result["violations"])

    def test_no_action_change_keeps_write_scope_closed(self):
        data = payload()
        data["player_action"]["observed"] = [{"node_id": 1, "node_name": "wait.main"}]
        result = analyze(data)
        self.assertTrue(result["experiment_succeeded"])
        self.assertFalse(result["semantic_action_observed"])
        self.assertEqual(result["next_gate"],
                         "adjust_trigger_timing_without_expanding_write_scope")

    def test_rejects_trigger_without_verified_neutral_gate(self):
        data = payload()
        data["input_motion"]["neutral_gate"]["node_name"] = "fast_travel.arrive"
        result = analyze(data)
        self.assertFalse(result["experiment_succeeded"])
        self.assertIn("neutral_player_action_gate_invalid", result["violations"])


if __name__ == "__main__":
    unittest.main()
