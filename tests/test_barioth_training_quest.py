import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BariothTrainingQuestTests(unittest.TestCase):
    def setUp(self):
        self.quest = json.loads(
            (ROOT / "reframework/quests/q200042001.json").read_text(encoding="utf-8")
        )

    def test_research_quest_is_isolated_and_rewardless(self):
        self.assertEqual(self.quest["QuestID"], 200042001)
        data = self.quest["QuestData"]
        self.assertEqual(data["Map"], 14)
        self.assertEqual(data["TargetMonsters"], [42, 0])
        self.assertEqual(data["Monsters"][0]["Id"], 42)
        self.assertEqual(data["Reward"], {"Zenny": 0, "Points": 0, "HRP": 0})
        self.assertGreaterEqual(data["Carts"], 9)

    def test_copy_identifies_read_only_research_boundary(self):
        rows = {row["Language"]: row for row in self.quest["QuestText"]["QuestInfo"]}
        self.assertIn("研究阶段", rows["ZHS"]["Description"])
        self.assertIn("read-only research mode", rows["ENG"]["Description"])


if __name__ == "__main__":
    unittest.main()
