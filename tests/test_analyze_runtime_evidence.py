import unittest

from tools.analyze_runtime_evidence import analyze


class AnalyzeRuntimeEvidenceTests(unittest.TestCase):
    def test_filters_category_and_counts_immediate_attack_edges(self):
        payload = {"history": [
            {"action": "15", "metadata": {"action_category": 4, "motion_name": "Drift_L"}},
            {"action": "2", "metadata": {"action_category": 4, "motion_name": "Rush"}},
            {"action": "8", "metadata": {"action_category": 1, "motion_name": "Idle"}},
            {"action": "18", "metadata": {"action_category": 4, "motion_name": "Turn"}},
        ]}

        result = analyze(payload)

        self.assertEqual(result["captured_transition_count"], 4)
        self.assertEqual(result["attack_transition_count"], 3)
        self.assertEqual(result["immediate_attack_edges"], [{"edge": "15->2", "count": 1}])
        self.assertEqual(result["actions"][0]["action"], "15")


if __name__ == "__main__":
    unittest.main()
