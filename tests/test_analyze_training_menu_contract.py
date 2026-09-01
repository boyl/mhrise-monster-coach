import copy
import unittest

from tools.analyze_training_menu_contract import analyze


def scenario(scenario_id: str, *, selected: bool = False, effective: int = 5):
    return {
        "scenario_id": scenario_id,
        "name": "咆哮" if scenario_id == "roar" else "短距半回转钩咬",
        "requested_repeats": 5,
        "effective_repeats": effective,
        "start_label": f"开始：{scenario_id} × {effective}",
        "repeat_gate_message": "稳定性门禁" if effective < 5 else None,
        "selected": selected,
        "branch_tree": {"action": "19", "candidates": []},
    }


def report():
    return {
        "kind": "ui_contract_snapshot",
        "status": "completed",
        "ui_contract": {
            "schema_version": 1,
            "state": "disabled",
            "state_label": "未启用",
            "status": "启用后才能开始",
            "instruction": "先查看派生树",
            "enabled": False,
            "scope_ready": False,
            "scope_status": "请先进入单人轰龙陪练任务",
            "requested_repeats": 5,
            "groups": [
                {"id": "independent", "name": "独立关键招式", "scenarios": [scenario("roar")]},
                {"id": "fixed", "name": "固定派生起手", "scenarios": [scenario("bite", effective=1)]},
            ],
            "scenario_count": 2,
            "selected": None,
            "can_select": True,
            "can_start": False,
            "can_stop": False,
            "primary_label": None,
        },
    }


class TrainingMenuContractAnalysisTests(unittest.TestCase):
    def test_accepts_disabled_catalog_snapshot_before_save_load(self):
        result = analyze(report())
        self.assertTrue(result["contract_valid"])
        self.assertEqual(result["status"], "verified_training_menu_contract")
        self.assertEqual(result["scenario_count"], 2)

    def test_accepts_previewed_selection_with_consistent_start_gate(self):
        payload = report()
        contract = payload["ui_contract"]
        selected = contract["groups"][0]["scenarios"][0]
        selected["selected"] = True
        contract.update({
            "state": "previewed",
            "state_label": "可开始",
            "enabled": True,
            "scope_ready": True,
            "scope_status": "单人陪练任务已就绪",
            "selected": copy.deepcopy(selected),
            "can_start": True,
            "primary_label": "开始当前起手 × 5",
        })
        result = analyze(payload)
        self.assertTrue(result["contract_valid"])
        self.assertEqual(result["selected_scenario_id"], "roar")

    def test_accepts_active_state_only_with_stop_ownership(self):
        payload = report()
        contract = payload["ui_contract"]
        selected = contract["groups"][0]["scenarios"][0]
        selected["selected"] = True
        contract.update({
            "state": "active",
            "state_label": "训练中",
            "enabled": True,
            "scope_ready": True,
            "scope_status": "单人陪练任务已就绪",
            "selected": copy.deepcopy(selected),
            "can_select": False,
            "can_start": False,
            "can_stop": True,
        })
        self.assertTrue(analyze(payload)["contract_valid"])
        contract["can_start"] = True
        result = analyze(payload)
        self.assertFalse(result["contract_valid"])
        self.assertIn("active_action_ownership_inconsistent", result["violations"])

    def test_accepts_explicit_retry_after_unavailable_scope_recovers(self):
        payload = report()
        contract = payload["ui_contract"]
        selected = contract["groups"][0]["scenarios"][0]
        selected["selected"] = True
        contract.update({
            "state": "unavailable",
            "state_label": "当前不可用",
            "enabled": True,
            "scope_ready": True,
            "scope_status": "单人陪练任务已就绪",
            "selected": copy.deepcopy(selected),
            "can_start": True,
            "primary_label": "重新尝试 × 5",
        })
        self.assertTrue(analyze(payload)["contract_valid"])

    def test_rejects_duplicate_or_incomplete_catalog_rows(self):
        payload = report()
        contract = payload["ui_contract"]
        contract["groups"][1]["scenarios"][0]["scenario_id"] = "roar"
        contract["groups"][1]["scenarios"][0]["branch_tree"] = None
        result = analyze(payload)
        self.assertFalse(result["contract_valid"])
        self.assertIn("duplicate_scenario_id", result["violations"])
        self.assertIn("roar:branch_tree_missing", result["violations"])

    def test_rejects_repeat_or_selection_drift(self):
        payload = report()
        contract = payload["ui_contract"]
        row = contract["groups"][1]["scenarios"][0]
        row["repeat_gate_message"] = None
        row["selected"] = True
        result = analyze(payload)
        self.assertFalse(result["contract_valid"])
        self.assertIn("bite:repeat_gate_message_missing", result["violations"])
        self.assertIn("selected_object_missing", result["violations"])


if __name__ == "__main__":
    unittest.main()
