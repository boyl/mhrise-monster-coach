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
    return {"input_motion": {"schema_version": 9, "semantic_input_contract": {
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
    }, "player_input_owner_contract": {
        "policy": "read_only_current_player_input_fields",
        "gameplay_method_calls": 0,
        "gameplay_writes": 0,
        "player_available": True,
        "player_type": "snow.player.LongSword",
        "hierarchy": {"levels": [{
            "type": "snow.player.PlayerBase",
            "fields": [{
                "name": "_stmPlayerInput",
                "type": "snow.StmPlayerInput",
                "object_available": True,
                "object_type": "snow.StmPlayerInput",
            }],
        }]},
    }}}


class SemanticInputContractAnalysisTests(unittest.TestCase):
    def test_finds_instance_owned_update_candidate_without_allowing_experiment(self):
        result = analyze(complete_payload())

        self.assertEqual(result["status"], "player_input_instance_candidate_found")
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
        self.assertEqual(len(result["resolved_player_input_owners"]), 1)
        self.assertEqual(result["resolved_player_input_owners"][0]["field"],
                         "_stmPlayerInput")
        self.assertEqual(result["next_gate"],
                         "verify_stm_player_input_instance_read_contract")

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

    def test_manager_update_method_does_not_unlock_write_without_bitset_mutator(self):
        payload = complete_payload()
        for getter in payload["input_motion"]["semantic_bitset_contract"]["getters"]:
            getter["object_contract"]["methods"] = [
                method("getFlag", "snow.player.PlayerInput.CommandButton2"),
            ]
        payload["input_motion"]["player_input_owner_contract"]["hierarchy"]["levels"][0]["fields"] = []

        result = analyze(payload)

        self.assertEqual(result["status"], "read_only_owner_without_mutator")
        self.assertEqual(result["next_gate"], "locate_stm_player_input_instance")
        self.assertEqual(result["bitset_mutator_candidates"], [])
        self.assertFalse(result["experiment_allowed"])

    def test_inherited_bitset_mutator_is_discovered_without_being_called(self):
        payload = complete_payload()
        payload["input_motion"]["player_input_owner_contract"]["hierarchy"]["levels"][0]["fields"] = []
        for getter in payload["input_motion"]["semantic_bitset_contract"]["getters"]:
            getter["object_contract"]["methods"] = [method("getFlag")]
            getter["object_hierarchy"] = {"levels": [{
                "type": "snow.BitSetFlagBase",
                "methods": [method("clearFlag", "System.Int32")],
            }]}

        result = analyze(payload)

        self.assertEqual(result["status"], "bitset_mutator_candidate_found")
        self.assertEqual(len(result["bitset_mutator_candidates"]), 4)
        self.assertTrue(all(item["declaring_type"] == "snow.BitSetFlagBase"
                            for item in result["bitset_mutator_candidates"]))
        self.assertFalse(result["experiment_allowed"])

    def test_schema_nine_requires_read_only_player_owner_contract(self):
        payload = complete_payload()
        del payload["input_motion"]["player_input_owner_contract"]

        result = analyze(payload)

        self.assertEqual(result["status"], "invalid_read_only_contract")
        self.assertIn("player_input_owner_contract_missing_or_changed", result["violations"])
        self.assertFalse(result["experiment_allowed"])

    def test_both_supported_player_owner_types_require_a_real_object(self):
        for owner_type in ("snow.StmPlayerInput", "snow.player.PlayerInput"):
            with self.subTest(owner_type=owner_type):
                payload = complete_payload()
                field = payload["input_motion"]["player_input_owner_contract"][
                    "hierarchy"]["levels"][0]["fields"][0]
                field["type"] = owner_type
                field["object_type"] = owner_type

                result = analyze(payload)

                self.assertEqual(result["status"],
                                 "player_input_instance_candidate_found")
                self.assertEqual(result["resolved_player_input_owners"][0][
                    "object_type"], owner_type)
                self.assertFalse(result["experiment_allowed"])

        payload = complete_payload()
        field = payload["input_motion"]["player_input_owner_contract"][
            "hierarchy"]["levels"][0]["fields"][0]
        field["object_available"] = False
        field["object_type"] = None
        for getter in payload["input_motion"]["semantic_bitset_contract"]["getters"]:
            getter["object_contract"]["methods"] = [method("getFlag")]

        result = analyze(payload)

        self.assertEqual(result["resolved_player_input_owners"], [])
        self.assertEqual(result["player_input_owner_fields"][0]["classification"],
                         "declared_owner_metadata_only")
        self.assertFalse(result["experiment_allowed"])

    def test_legacy_schema_eight_does_not_require_new_owner_contract(self):
        payload = complete_payload()
        payload["input_motion"]["schema_version"] = 8
        del payload["input_motion"]["player_input_owner_contract"]

        result = analyze(payload)

        self.assertNotIn("player_input_owner_contract_missing_or_changed", result["violations"])


if __name__ == "__main__":
    unittest.main()
