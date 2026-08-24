from __future__ import annotations

import json
import pathlib
import unittest


class LongSwordKnowledgeTests(unittest.TestCase):
    def test_runtime_node_patterns_are_closed_and_attributed(self) -> None:
        repository = pathlib.Path(__file__).resolve().parents[1]
        path = repository / "reframework/data/MHRiseMonsterCoach/long_sword_knowledge.json"
        knowledge = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(knowledge["schema_version"], 2)
        actions = knowledge["actions"]
        sources = {row.get("id"): row for row in knowledge["sources"] if row.get("id")}
        patterns = knowledge["runtime_node_patterns"]
        self.assertTrue(patterns)

        seen_exact: set[str] = set()
        for row in patterns:
            self.assertIn(row["semantic"], actions)
            self.assertTrue(row["role"])
            self.assertIn(row["evidence_status"], {"community_candidate", "runtime_verified"})
            self.assertIn(row["source_id"], sources)
            self.assertTrue(row.get("exact") or row.get("prefixes"))
            self.assertEqual(row["runtime_scope"], {"game_name": "mhrise", "tdb_version": 71})
            for node_name in row.get("exact", []):
                self.assertNotIn(node_name, seen_exact, f"duplicate exact node: {node_name}")
                seen_exact.add(node_name)


if __name__ == "__main__":
    unittest.main()
