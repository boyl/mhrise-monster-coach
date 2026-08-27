import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PlayerCalibrationQuestTests(unittest.TestCase):
    def setUp(self):
        self.normal_path = ROOT / "reframework" / "quests" / "q200032001.json"
        self.calibration_path = (
            ROOT / "tools" / "fixtures" / "q200032002.player-calibration.json"
        )
        self.normal = json.loads(self.normal_path.read_text(encoding="utf-8"))
        self.calibration = json.loads(self.calibration_path.read_text(encoding="utf-8"))

    def test_calibration_uses_a_separate_developer_quest_id(self):
        self.assertEqual(self.normal["QuestID"], 200032001)
        self.assertEqual(self.calibration["QuestID"], 200032002)
        self.assertNotEqual(self.normal["QuestID"], self.calibration["QuestID"])

    def test_calibration_has_inert_target_no_spawn_and_no_reward(self):
        quest = self.calibration["QuestData"]
        self.assertEqual(quest["QuestType"], 1)
        self.assertEqual(quest["Map"], 14)
        self.assertEqual(quest["TargetTypes"], [2, 0])
        self.assertEqual(quest["TargetMonsters"], [32, 0])
        self.assertEqual(quest["TargetAmounts"], [1, 0])
        self.assertTrue(all(item["Id"] == 0 for item in quest["Monsters"]))
        self.assertTrue(
            all(item["PathId"] == 0 for item in self.calibration["EnemyData"]["Monsters"])
        )
        self.assertEqual(quest["Reward"], {"Zenny": 0, "Points": 0, "HRP": 0})

    def test_normal_training_quest_remains_tigrex_hunting(self):
        quest = self.normal["QuestData"]
        self.assertEqual(quest["TargetTypes"], [2, 0])
        self.assertEqual(quest["TargetMonsters"], [32, 0])
        self.assertEqual(quest["Monsters"][0]["Id"], 32)

    def test_calibration_fixture_is_not_part_of_normal_deployment(self):
        deploy = (ROOT / "tools" / "deploy_dev.ps1").read_text(encoding="utf-8")
        self.assertNotIn("q200032002", deploy)
        self.assertFalse((ROOT / "reframework" / "quests" / "q200032002.json").exists())


if __name__ == "__main__":
    unittest.main()
