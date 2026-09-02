import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BariothPackTests(unittest.TestCase):
    def setUp(self):
        self.pack = json.loads(
            (ROOT / "reframework/data/MHRiseMonsterCoach/barioth_static_ai.json")
            .read_text(encoding="utf-8")
        )

    def test_pack_is_research_only_and_exposes_no_training_scenario(self):
        self.assertEqual(self.pack["monster"], "em042")
        self.assertEqual(self.pack["verification_status"], "research_only")
        self.assertEqual(self.pack["training_scenarios"], [])

    def test_offline_fixed_edges_keep_sources_and_known_successors(self):
        expected = {"33": "34", "35": "5005", "5005": "5002"}
        self.assertEqual(set(self.pack["actions"]), set(expected))
        for source, target in expected.items():
            row = self.pack["actions"][source]
            self.assertEqual(row["kind"], "fixed")
            self.assertEqual([edge["action"] for edge in row["next"]], [target])
            self.assertGreaterEqual(row["evidence_count"], 2)
            self.assertTrue(row["next"][0]["sources"])
            self.assertIn(target, self.pack["moves"])

    def test_community_names_do_not_upgrade_runtime_verification(self):
        self.assertEqual(self.pack["move_name_source"]["section"], "Barioth / EmAttackNo")
        self.assertEqual(
            self.pack["moves"]["35"]["enum_name"], "FullPowerTailAttackStartTurn"
        )
        self.assertEqual(self.pack["moves"]["35"]["certainty"], "community_action_enum")
        self.assertEqual(self.pack["verification_status"], "research_only")
        self.assertEqual(self.pack["training_scenarios"], [])


if __name__ == "__main__":
    unittest.main()
