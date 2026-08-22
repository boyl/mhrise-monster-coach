import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class TigrexActionCatalogTests(unittest.TestCase):
    def test_community_attack_catalog_is_complete_for_documented_tigrex_ids(self):
        payload = json.loads(
            (ROOT / "reframework/data/MHRiseMonsterCoach/tigrex_static_ai.json").read_text(encoding="utf-8")
        )
        expected = {
            "2": "StraightRush", "6": "AfterRushRotateAttack", "7": "AfterRushBite",
            "9": "AfterRushBackStep", "10": "AfterRushStop", "12": "AfterRushJumpAttack",
            "13": "AfterRushJumpAttackWall", "14": "AfterRushRoar", "15": "AfterRushDriftForAttack",
            "16": "RerushDrift", "17": "TiredRerushDrift", "18": "AngryRerushDrift",
            "19": "Roar", "20": "BiteMin", "21": "BiteMax", "22": "RockLauncherL",
            "23": "RockLauncherR", "24": "JumpAttack", "25": "JumpAttackWall",
            "26": "RotateAttackR", "27": "BackTailAttackL", "28": "BackTailAttackR",
            "29": "CheckBite", "51": "RushFangSting",
            "5000": "BiteHookHalfTurnStartShortRange", "5001": "BiteHookHalfTurnAttackNormal",
            "5002": "BiteHookHalfTurnStartLongRange", "5003": "BiteHookHalfTurnAttackAnger",
            "5004": "MRRockLauncherL", "5005": "MRRockLauncherR",
        }

        self.assertEqual(payload["required_action_category"], 4)
        self.assertIn("Monster-Action-IDs", payload["move_name_source"]["url"])
        self.assertEqual(
            {key: payload["moves"][key]["enum_name"] for key in expected},
            expected,
        )
        for key in expected:
            self.assertTrue(payload["moves"][key]["name"])
            self.assertTrue(payload["moves"][key]["advice"])

    def test_condition_guided_training_contract_is_data_driven(self):
        payload = json.loads(
            (ROOT / "reframework/data/MHRiseMonsterCoach/tigrex_static_ai.json").read_text(encoding="utf-8")
        )
        scenarios = {row["id"]: row for row in payload["training_scenarios"]}
        scenario = scenarios["tigrex_half_turn_bite_short"]

        self.assertEqual(scenario["execution_mode"], "natural_condition")
        self.assertEqual(scenario["actions"], [5000])
        self.assertEqual(scenario["expected_successor"], 5001)
        self.assertEqual(scenario["max_verified_repeats"], 1)
        self.assertEqual(scenario["positioning"], {
            "metric": "horizontal_distance", "target": 7.0, "tolerance": 2.0,
        })
        edge = payload["actions"]["5000"]
        self.assertEqual(edge["kind"], "fixed")
        self.assertEqual([row["action"] for row in edge["next"]], ["5001"])


if __name__ == "__main__":
    unittest.main()
