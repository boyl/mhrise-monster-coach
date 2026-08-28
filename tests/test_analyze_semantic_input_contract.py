import unittest

from tools.analyze_semantic_input_contract import EXPECTED_TYPES, analyze


def method(name, *param_types, is_static=False):
    return {"name": name, "param_types": list(param_types), "is_static": is_static}


def complete_payload():
    types = []
    for name in EXPECTED_TYPES:
        entry = {
            "type": name,
            "available": True,
            "instance_available": name in {"snow.StmInputManager", "snow.StmPlayerInput"},
            "methods": [],
            "semantic_query_methods": [],
        }
        types.append(entry)
    types[0]["semantic_query_methods"] = [
        method("isOn", "snow.player.PlayerInput.CommandButton2"),
        method("getTrg"),
    ]
    types[1]["methods"] = [
        method("updateCommand", "snow.player.PlayerInput.CommandButton2"),
        method("getInput"),
    ]
    return {"input_motion": {"semantic_input_contract": {
        "policy": "read_only_exact_semantic_input_metadata",
        "gameplay_method_calls": 0,
        "gameplay_writes": 0,
        "command_enum": {"available": True, "values": [
            {"name": "Atk_X", "value": 0},
            {"name": "Atk_R_A", "value": 41},
        ]},
        "types": types,
    }, "semantic_bitset_contract": {
        "policy": "bounded_read_only_semantic_bitset_getters",
        "max_calls": 4,
        "call_count": 4,
        "call_failures": 0,
        "gameplay_writes": 0,
        "getters": [{
            "name": name,
            "status": "resolved",
            "object_type": "snow.BitSetFlag`1<snow.player.PlayerInput.CommandButton2>",
            "object_contract": {"methods": [
                method("getFlag", "snow.player.PlayerInput.CommandButton2"),
                method("setFlag", "snow.player.PlayerInput.CommandButton2", "System.Boolean"),
            ]},
        } for name in ("getOn", "getTrg", "getRel", "getDelay")],
    }}}


class SemanticInputContractAnalysisTests(unittest.TestCase):
    def test_finds_instance_owned_update_candidate_without_allowing_experiment(self):
        result = analyze(complete_payload())

        self.assertEqual(result["status"], "bitset_mutator_candidate_found")
        self.assertFalse(result["experiment_allowed"])
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["command_enum_count"], 2)
        self.assertEqual(result["instance_owner_candidates"], [
            "snow.StmInputManager", "snow.StmPlayerInput",
        ])
        self.assertEqual(len(result["viable_update_candidates"]), 1)
        self.assertIn("updateCommand", result["viable_update_candidates"][0]["signature"])
        self.assertEqual(result["semantic_bitset_call_count"], 4)
        self.assertEqual(result["semantic_bitset_object_types"], [
            "snow.BitSetFlag`1<snow.player.PlayerInput.CommandButton2>",
        ])
        self.assertEqual(len(result["bitset_mutator_candidates"]), 4)
        self.assertTrue(all(not item["signature"].startswith("getFlag")
                            for item in result["bitset_mutator_candidates"]))

    def test_write_or_call_count_violation_fails_closed(self):
        payload = complete_payload()
        contract = payload["input_motion"]["semantic_input_contract"]
        contract["gameplay_method_calls"] = 1
        contract["gameplay_writes"] = 2

        result = analyze(payload)

        self.assertEqual(result["status"], "invalid_read_only_contract")
        self.assertFalse(result["experiment_allowed"])
        self.assertIn("gameplay_method_calls_not_zero", result["violations"])
        self.assertIn("gameplay_writes_not_zero", result["violations"])

    def test_missing_contract_is_not_treated_as_an_empty_success(self):
        result = analyze({})

        self.assertEqual(result["status"], "invalid_read_only_contract")
        self.assertEqual(result["missing_type_entries"], list(EXPECTED_TYPES))
        self.assertFalse(result["experiment_allowed"])

    def test_bitset_getter_failure_blocks_mutator_candidate(self):
        payload = complete_payload()
        payload["input_motion"]["semantic_bitset_contract"]["call_failures"] = 1

        result = analyze(payload)

        self.assertEqual(result["status"], "invalid_read_only_contract")
        self.assertIn("semantic_bitset_getter_call_failed", result["violations"])
        self.assertFalse(result["experiment_allowed"])


if __name__ == "__main__":
    unittest.main()
