import unittest

from tools.analyze_player_action_input_probe import EXPECTED_STEPS, analyze


def result(step_id, node_id, node_name, *, status="observed", tags=None):
    return {
        "id": step_id,
        "label": step_id,
        "status": status,
        "events": [] if node_id is None else [{
            "sample": 10,
            "node_id": node_id,
            "node_name": node_name,
            "tags": tags or {},
        }],
    }


class PlayerActionInputProbeAnalysisTests(unittest.TestCase):
    def test_complete_batch_keeps_input_correlation_below_semantic_truth(self):
        rows = [
            result(step_id, index + 100, f"atk.{step_id}", tags={"attack": True})
            for index, step_id in enumerate(EXPECTED_STEPS)
        ]
        report = analyze({
            "session_id": "session",
            "weapon_type": "long_sword",
            "player_type": "snow.player.LongSword",
            "equipment_writes": False,
            "save_writes": False,
            "results": rows,
        })
        self.assertEqual(report["gate"]["status"], "complete")
        self.assertFalse(report["gate"]["may_update_verified_semantics"])
        self.assertEqual(len(report["steps"]), 7)
        self.assertTrue(all(
            step["correlated_nodes"][0]["exclusive_to_step"]
            for step in report["steps"]
        ))

    def test_partial_batch_reports_missing_failed_and_neutral_only_steps(self):
        rows = [
            result("basic_overhead", 1, "wait.main"),
            result("thrust", None, None, status="not_observed"),
        ]
        report = analyze({"results": rows})
        self.assertEqual(report["gate"]["status"], "partial")
        self.assertIn("dodge", report["gate"]["missing_steps"])
        self.assertEqual(report["gate"]["incomplete_steps"], ["thrust"])
        self.assertEqual(
            report["gate"]["observed_steps_without_correlated_nodes"],
            ["basic_overhead"],
        )

    def test_shared_prerequisite_node_is_not_claimed_as_exclusive(self):
        report = analyze({"results": [
            result("basic_overhead", 10, "atk.shared"),
            result("foresight_attempt", 10, "atk.shared"),
        ]})
        nodes = [step["correlated_nodes"][0] for step in report["steps"]]
        self.assertTrue(all(not node["exclusive_to_step"] for node in nodes))
        self.assertEqual(nodes[0]["observed_in_steps"], ["basic_overhead", "foresight_attempt"])


if __name__ == "__main__":
    unittest.main()
