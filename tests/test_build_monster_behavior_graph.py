import tempfile
import unittest
from pathlib import Path

from tools.build_monster_behavior_graph import (
    build_behavior_graph,
    build_file_graph,
    extract_fixed_action_edges,
)


def instance(instance_id, type_name, **fields):
    return {
        "id": instance_id,
        "type": type_name,
        "userdata": None,
        "fields": [
            {"name": name, "type": "test", "value": value}
            for name, value in fields.items()
        ],
    }


class BuildMonsterBehaviorGraphTests(unittest.TestCase):
    def test_extracts_actions_conditions_and_reference_userdata(self):
        document = {
            "source": "combo.user.2",
            "instances": [
                {"id": 1, "type": "snow.enemy.EnemyThinkData", "userdata": "enemy/em032/next.user", "fields": []},
                instance(2, "snow.enemy.aifsm.Em032Action", _ActionNo=37, v1_ID=123),
                instance(3, "snow.enemy.behaviortree.EnemyBTCTargetRange", rangeType=1),
                instance(
                    4,
                    "snow.enemy.ThinkCondition",
                    _Condition={"$ref": 3, "$type": "snow.enemy.behaviortree.EnemyBTCTargetRange"},
                    _IsUnderLayerEnd=False,
                    _IsActionEnd=True,
                    _NextStateID=2,
                ),
                instance(
                    5,
                    "snow.enemy.ThinkState",
                    _ID=1,
                    _ActionList=[{"$ref": 2, "$type": "snow.enemy.aifsm.Em032Action"}],
                    _ConditionList=[{"$ref": 4, "$type": "snow.enemy.ThinkCondition"}],
                    _ReferenceThinkData={"$ref": 1, "$type": "snow.enemy.EnemyThinkData"},
                    _TreeNodeID=999,
                ),
            ],
        }
        graph, diagnostics = build_file_graph(document)
        state = graph["states"][0]
        self.assertEqual(state["actions"][0]["action_no"], 37)
        self.assertEqual(state["actions"][0]["stable_id"], 123)
        self.assertEqual(state["reference_userdata"], "enemy/em032/next.user")
        self.assertEqual(state["transitions"][0]["next_state_id"], 2)
        self.assertEqual(
            state["transitions"][0]["condition"]["type"],
            "snow.enemy.behaviortree.EnemyBTCTargetRange",
        )
        self.assertEqual(state["transitions"][0]["condition"]["fields"]["rangeType"], 1)
        self.assertEqual(diagnostics, [])

    def test_missing_reference_is_diagnostic(self):
        document = {
            "source": "broken.user.2",
            "instances": [
                instance(
                    1,
                    "snow.enemy.ThinkState",
                    _ID=0,
                    _ActionList=[{"$ref": 99, "$type": "Missing"}],
                    _ConditionList=[],
                )
            ],
        }
        graph, diagnostics = build_file_graph(document)
        self.assertEqual(graph["states"][0]["actions"], [])
        self.assertEqual(diagnostics[0]["code"], "missing_reference")

    def test_duplicate_state_id_is_diagnostic(self):
        document = {
            "source": "duplicate.user.2",
            "instances": [
                instance(1, "snow.enemy.ThinkState", _ID=4, _ActionList=[], _ConditionList=[]),
                instance(2, "snow.enemy.ThinkState", _ID=4, _ActionList=[], _ConditionList=[]),
            ],
        }
        _, diagnostics = build_file_graph(document)
        self.assertEqual(diagnostics[0]["code"], "duplicate_state_id")

    def test_action_without_action_number_is_retained(self):
        document = {
            "source": "table.user.2",
            "instances": [
                instance(1, "snow.enemy.behaviortree.EnemyBTAActionTableSet", v1_ID=7),
                instance(
                    2,
                    "snow.enemy.ThinkState",
                    _ID=0,
                    _ActionList=[{"$ref": 1, "$type": "snow.enemy.behaviortree.EnemyBTAActionTableSet"}],
                    _ConditionList=[],
                ),
            ],
        }
        graph, _ = build_file_graph(document)
        self.assertIsNone(graph["states"][0]["actions"][0]["action_no"])

    def test_fixed_edge_requires_unique_attack_action_end_transition(self):
        document = {
            "source": "combo.user.2",
            "instances": [
                instance(1, "snow.enemy.aifsm.Em032_00ActionSetAttack", _ActionNo=2),
                instance(2, "snow.enemy.behaviortree.EnemyActionEnd"),
                instance(
                    3,
                    "snow.enemy.ThinkCondition",
                    _Condition={"$ref": 2, "$type": "snow.enemy.behaviortree.EnemyActionEnd"},
                    _NextStateID=1,
                ),
                instance(
                    4,
                    "snow.enemy.ThinkState",
                    _ID=0,
                    _ActionList=[{"$ref": 1, "$type": "snow.enemy.aifsm.Em032_00ActionSetAttack"}],
                    _ConditionList=[{"$ref": 3, "$type": "snow.enemy.ThinkCondition"}],
                ),
                instance(5, "snow.enemy.aifsm.Em032_00ActionSetAttack", _ActionNo=10),
                instance(
                    6,
                    "snow.enemy.ThinkState",
                    _ID=1,
                    _ActionList=[{"$ref": 5, "$type": "snow.enemy.aifsm.Em032_00ActionSetAttack"}],
                    _ConditionList=[],
                ),
            ],
        }
        graph, _ = build_file_graph(document)
        edges = extract_fixed_action_edges(graph, "em032")
        self.assertEqual(edges[0]["from_action_no"], 2)
        self.assertEqual(edges[0]["to_action_no"], 10)

        graph["states"][0]["transitions"][0]["condition"]["type"] = "RangeCheck"
        self.assertEqual(extract_fixed_action_edges(graph, "em032"), [])

    def test_builds_cross_file_action_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            document = {
                "source": "action.user.2",
                "instances": [
                    instance(1, "Action", _ActionNo=8),
                    instance(
                        2,
                        "snow.enemy.ThinkState",
                        _ID=0,
                        _ActionList=[{"$ref": 1, "$type": "Action"}],
                        _ConditionList=[],
                    ),
                ],
            }
            (root / "action.rsz.json").write_text(__import__("json").dumps(document), encoding="utf-8")
            graph = build_behavior_graph(root, "em032")
        self.assertEqual(graph["summary"]["action_number_count"], 1)
        self.assertEqual(graph["action_catalog"]["8"][0]["state_id"], 0)


if __name__ == "__main__":
    unittest.main()
