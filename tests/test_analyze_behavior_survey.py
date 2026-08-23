import unittest

from tools.analyze_behavior_survey import analyze, attack_onsets


class AnalyzeBehaviorSurveyTests(unittest.TestCase):
    def setUp(self):
        self.report = {
            "session_id": "survey-1",
            "status": "completed",
            "behavior_survey": {
                "samples": 300,
                "events": [
                    {"frame": 10, "action": {"category": 4, "action": 2},
                     "node": {"name": "Attack.StraightRush.Phase00"}, "geometry": {}},
                    {"frame": 20, "action": {"category": 4, "action": 2},
                     "node": {"name": "Attack.StraightRush.Phase01"}, "geometry": {}},
                    {"frame": 30, "action": {"category": 4, "action": 2},
                     "node": {"name": "Normal.Search.Phase00"}, "geometry": {}},
                    {"frame": 31, "action": {"category": 4, "action": 10},
                     "node": {"name": "Attack.AfterRushStop.突進後"}, "geometry": {}},
                    {"frame": 60, "action": {"category": 1, "action": 8},
                     "node": {"name": "Move.Dash.Phase00"}, "geometry": {}},
                    {"frame": 90, "action": {"category": 4, "action": 29},
                     "node": {"name": "Attack.CheckBite.Phase00"}, "geometry": {}},
                ],
            },
        }
        self.static = {
            "required_action_category": 4,
            "actions": {"2": {"kind": "conditional", "next": [
                {"action": "10", "condition": "approved", "evidence_count": 5}
            ]}},
        }

    def test_only_real_attack_onsets_are_retained(self):
        self.assertEqual([row["action"] for row in attack_onsets(self.report, 4)],
                         ["2", "10", "29"])

    def test_pack_approved_and_unreviewed_edges_remain_distinct(self):
        result = analyze(self.report, self.static)
        by_edge = {(row["source"], row["target"]): row for row in result["edges"]}
        approved = by_edge[("2", "10")]
        candidate = by_edge[("10", "29")]
        self.assertEqual((approved["source"], approved["target"], approved["classification"]),
                         ("2", "10", "conditional"))
        self.assertTrue(approved["approved_by_monster_pack"])
        self.assertEqual(candidate["classification"], "observed_next_attack_candidate")
        self.assertFalse(candidate["approved_by_monster_pack"])

    def test_missing_survey_fails_at_input_boundary(self):
        with self.assertRaisesRegex(ValueError, "behavior_survey"):
            analyze({"status": "completed"}, self.static)


if __name__ == "__main__":
    unittest.main()
