import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class TigrexActionCatalogTests(unittest.TestCase):
    @staticmethod
    def load_payload():
        return json.loads(
            (ROOT / "reframework/data/MHRiseMonsterCoach/tigrex_static_ai.json").read_text(encoding="utf-8")
        )

    def test_community_attack_catalog_is_complete_for_documented_tigrex_ids(self):
        payload = self.load_payload()
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
        payload = self.load_payload()
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

    def test_check_bite_preserves_its_repeated_product_acceptance(self):
        payload = self.load_payload()
        scenarios = {row["id"]: row for row in payload["training_scenarios"]}
        scenario = scenarios["tigrex_check_bite_single"]
        self.assertEqual(scenario["actions"], [29])
        self.assertEqual(scenario["execution_mode"], "forced_single")
        self.assertEqual(scenario["max_verified_repeats"], 5)
        self.assertEqual(scenario["verification"]["completed_repeats"], 6)
        self.assertIn("TIGREX_CHECK_BITE_ACCEPTANCE", scenario["verification"]["evidence"])
        forced_actions = {
            row["actions"][0] for row in payload["training_scenarios"]
            if row["execution_mode"] == "forced_single"
        }
        self.assertNotIn(20, forced_actions)

    def test_high_value_starters_are_staged_behind_single_repeat_gate(self):
        payload = self.load_payload()
        scenarios = {row["id"]: row for row in payload["training_scenarios"]}
        expected = {
            "tigrex_max_bite_single": 21,
            "tigrex_rotate_attack_right_single": 26,
        }
        for scenario_id, action in expected.items():
            scenario = scenarios[scenario_id]
            self.assertEqual(scenario["actions"], [action])
            self.assertEqual(scenario["execution_mode"], "forced_single")
            self.assertEqual(scenario["max_verified_repeats"], 1)
            self.assertIn("TIGREX_KEY_STARTER_CANDIDATES", scenario["verification"]["evidence"])

    def test_branch_graph_and_training_scenarios_obey_pack_contract(self):
        payload = self.load_payload()
        moves = payload["moves"]
        branches = payload["actions"]
        allowed_kinds = {"fixed", "conditional", "random", "observed", "unresolved"}
        allowed_categories = {
            "independent", "fixed_branch", "conditional_branch", "random_branch", "observed_branch"
        }
        allowed_modes = {"forced_single", "natural_condition", "native_branch", "native_combo", "single_move"}

        self.assertTrue(payload["monster"])
        self.assertIsInstance(payload["required_action_category"], int)
        for source, branch in branches.items():
            self.assertTrue(source.isdigit())
            self.assertIn(branch["kind"], allowed_kinds)
            self.assertGreater(len(branch["next"]), 0)
            if branch["kind"] == "fixed":
                self.assertEqual(len(branch["next"]), 1)
            for edge in branch["next"]:
                target = str(edge["action"])
                self.assertIn(target, moves)
                if branch["kind"] == "conditional":
                    self.assertTrue(edge.get("condition"))

        ids = set()
        for scenario in payload["training_scenarios"]:
            self.assertNotIn(scenario["id"], ids)
            ids.add(scenario["id"])
            self.assertIn(scenario["training_category"], allowed_categories)
            self.assertIn(scenario["execution_mode"], allowed_modes)
            self.assertIn(str(scenario["actions"][0]), moves)
            self.assertGreaterEqual(scenario["max_verified_repeats"], 1)
            self.assertEqual(scenario["verification"]["status"], "verified")
            if scenario["execution_mode"] == "natural_condition":
                self.assertIn("target", scenario["positioning"])
                self.assertIn("tolerance", scenario["positioning"])
                declared = {str(edge["action"]) for edge in branches[str(scenario["actions"][0])]["next"]}
                if "expected_successor" in scenario:
                    self.assertIn(str(scenario["expected_successor"]), declared)
                for expected in scenario.get("expected_branches", []):
                    self.assertIn(str(expected["action"]), declared)


if __name__ == "__main__":
    unittest.main()
