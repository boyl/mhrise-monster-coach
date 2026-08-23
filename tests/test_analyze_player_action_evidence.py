import unittest

from tools.analyze_player_action_evidence import analyze


class PlayerActionEvidenceTests(unittest.TestCase):
    def test_catalogs_candidates_and_keeps_observed_edges_non_deterministic(self):
        report = analyze({
            "runtime": {"game_name": "mhrise", "tdb_version": 71},
            "reader": {"player_type": "snow.player.LongSword"},
            "dropped_events": 2,
            "node_catalog": [
                {"id": "10", "name": "LongSword.Foresight.Start"},
                {"id": "11", "name": "LongSword.Foresight.Success"},
                {"id": "20", "name": "LongSword.Sacred.Release"},
            ],
            "events": [
                {"sample": 1, "node_id": 10, "tags": {"attack": True}},
                {"sample": 2, "node_id": 11, "tags": {"escape": True}},
                {"sample": 3, "node_id": 10, "tags": {"attack": True}},
                {"sample": 4, "node_id": 99, "node_name": "Unknown", "tags": {}},
            ],
        })
        self.assertEqual(report["summary"]["catalogued_nodes"], 3)
        self.assertEqual(report["summary"]["observed_nodes"], 3)
        self.assertEqual(report["summary"]["dropped_events"], 2)
        self.assertEqual(len(report["semantic_candidates"]["foresight_slash"]), 2)
        self.assertEqual(len(report["semantic_candidates"]["sacred_sheathe"]), 1)
        self.assertEqual(report["observed_transitions"][0]["certainty"], "observed_runtime_only")
        self.assertEqual(report["unmatched_observed_nodes"][0]["id"], "99")
        first = next(row for row in report["observed_nodes"] if row["id"] == "10")
        self.assertEqual(first["samples"], 2)
        self.assertEqual(first["active_tags"], ["attack"])


if __name__ == "__main__":
    unittest.main()
