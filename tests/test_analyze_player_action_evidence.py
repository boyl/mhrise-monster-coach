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

    def test_applies_runtime_scoped_data_pack_without_upgrading_semantic_truth(self):
        report = analyze({
            "runtime": {"game_name": "mhrise", "tdb_version": 71},
            "node_catalog": [
                {"id": "10", "name": "atk.atk_147.atk_147"},
                {"id": "11", "name": "atk.atk_147.atk_147_end"},
                {"id": "12", "name": "wait.main"},
            ],
            "events": [
                {"sample": 1, "node_id": 10, "node_name": "atk.atk_147.atk_147"},
                {"sample": 2, "node_id": 11, "node_name": "atk.atk_147.atk_147_end"},
            ],
        }, {
            "sources": [{"id": "community", "url": "https://example.invalid/source"}],
            "actions": {"foresight_slash": {"name": "见切斩"}},
            "runtime_node_patterns": [
                {
                    "semantic": "foresight_slash", "role": "attempt",
                    "exact": ["atk.atk_147.atk_147"],
                    "prefixes": ["atk.atk_147.atk_147."],
                    "evidence_status": "community_candidate", "source_id": "community",
                    "runtime_scope": {"game_name": "mhrise", "tdb_version": 71},
                },
                {
                    "semantic": "foresight_slash", "role": "success",
                    "exact": ["atk.atk_147.atk_147_end"],
                    "evidence_status": "community_candidate", "source_id": "community",
                    "runtime_scope": {"game_name": "mhrise", "tdb_version": 71},
                },
            ],
        })
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["summary"]["semantic_mapped_nodes"], 2)
        self.assertEqual(report["summary"]["observed_semantic_nodes"], 2)
        roles = {row["id"]: row["role"] for row in report["semantic_mappings"]}
        self.assertEqual(roles, {"10": "attempt", "11": "success"})
        self.assertTrue(all(row["runtime_observed"] for row in report["semantic_mappings"]))
        self.assertTrue(all(row["mapping_status"] == "community_candidate"
                            for row in report["semantic_mappings"]))
        self.assertEqual([row["id"] for row in report["unmapped_semantic_observed_nodes"]], [])

    def test_runtime_scope_fails_closed(self):
        report = analyze({
            "runtime": {"game_name": "mhrise", "tdb_version": 72},
            "node_catalog": [{"id": "10", "name": "atk.atk_147.atk_147"}],
            "events": [{"sample": 1, "node_id": 10}],
        }, {
            "actions": {"foresight_slash": {"name": "见切斩"}},
            "runtime_node_patterns": [{
                "semantic": "foresight_slash", "role": "attempt",
                "exact": ["atk.atk_147.atk_147"],
                "runtime_scope": {"game_name": "mhrise", "tdb_version": 71},
            }],
        })
        self.assertEqual(report["semantic_mappings"], [])


if __name__ == "__main__":
    unittest.main()
