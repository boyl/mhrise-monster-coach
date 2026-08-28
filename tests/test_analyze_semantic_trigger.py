import unittest

from tools.analyze_semantic_trigger import analyze


def payload():
    return {
        "kind": "semantic_input_trigger",
        "status": "completed",
        "input_motion": {
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
            "before": {"node_id": 1, "node_name": "idle"},
            "observed": [{"node_id": 2, "node_name": "esc_front"}],
        },
    }


class SemanticTriggerAnalysisTests(unittest.TestCase):
    def test_accepts_one_write_natural_release_and_action_change(self):
        result = analyze(payload())
        self.assertEqual(result["status"], "verified_single_frame_trigger")
        self.assertTrue(result["experiment_succeeded"])
        self.assertTrue(result["semantic_action_observed"])
        self.assertEqual(result["violations"], [])

    def test_rejects_missing_release_or_extra_write(self):
        data = payload()
        trigger = data["input_motion"]["semantic_trigger"]
        trigger["status"] = "injected"
        trigger["write_count"] = 2
        result = analyze(data)
        self.assertEqual(result["status"], "invalid_trigger_experiment")
        self.assertIn("trigger_release_not_verified", result["violations"])
        self.assertIn("write_count_not_one", result["violations"])

    def test_no_action_change_keeps_write_scope_closed(self):
        data = payload()
        data["player_action"]["observed"] = [{"node_id": 1, "node_name": "idle"}]
        result = analyze(data)
        self.assertTrue(result["experiment_succeeded"])
        self.assertFalse(result["semantic_action_observed"])
        self.assertEqual(result["next_gate"],
                         "adjust_trigger_timing_without_expanding_write_scope")


if __name__ == "__main__":
    unittest.main()
