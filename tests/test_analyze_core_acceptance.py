import copy
import unittest

from tools.analyze_core_acceptance import analyze


def timeline_analysis(scenario_id: str, *, complete: bool = True, classified: bool = True):
    return {
        "status": (
            "verified_complete_training_timeline"
            if complete
            else "verified_partial_training_timeline"
        ),
        "contract_valid": True,
        "training": {
            "scenario_id": scenario_id,
            "completed_rounds": 1,
            "target_rounds": 1,
        },
        "timeline": {
            "hitbox_windows": [{"start_frame": 12.0, "end_frame": 18.0}],
            "completion_basis": "behavior_tree_attack_exit",
        },
        "outcome": {
            "value": "no_damage" if classified else "unclassified",
            "evidence_level": "observed_success" if classified else "unclassified",
        },
    }


def payload():
    scenarios = [
        {"id": "single", "category": "independent", "repeat_count": 1},
        {"id": "fixed", "category": "fixed_branch", "repeat_count": 1},
        {"id": "conditional", "category": "conditional_branch", "repeat_count": 1},
    ]
    return {
        "schema_version": 1,
        "kind": "mvp_core_acceptance_batch",
        "status": "completed",
        "plan": {
            "required_categories": [
                "independent", "fixed_branch", "conditional_branch"
            ],
            "coverage_gate": {
                "minimum_complete_timelines": 3,
                "minimum_explicit_results": 3,
            },
            "scenarios": scenarios,
        },
        "scenarios": [
            {
                "id": row["id"],
                "process_exit_code": 0,
                "probe_status": "completed",
                "analysis": timeline_analysis(row["id"]),
            }
            for row in scenarios
        ],
    }


class CoreAcceptanceAnalysisTests(unittest.TestCase):
    def test_complete_batch_is_ready_for_release_gate(self):
        result = analyze(payload())
        self.assertEqual(result["status"], "ready_for_release_gate")
        self.assertTrue(result["core_contract_valid"])
        self.assertTrue(result["phase_coverage_complete"])
        self.assertTrue(result["result_coverage_complete"])
        self.assertTrue(result["ready_for_release_gate"])
        self.assertEqual(result["violations"], [])
        self.assertEqual(result["coverage_gaps"], [])

    def test_partial_timeline_is_a_batch_gap_but_unclassified_is_explicit(self):
        data = payload()
        data["scenarios"][1]["analysis"] = timeline_analysis(
            "fixed", complete=False, classified=False
        )
        result = analyze(data)
        self.assertEqual(result["status"], "core_contract_valid_with_coverage_gaps")
        self.assertTrue(result["core_contract_valid"])
        self.assertFalse(result["ready_for_release_gate"])
        self.assertIn("batch:complete_timelines:2/3", result["coverage_gaps"])
        self.assertTrue(result["result_coverage_complete"])
        self.assertEqual(result["explicit_result_count"], 3)

    def test_stops_release_on_missing_or_reordered_scenario(self):
        data = payload()
        data["scenarios"] = [data["scenarios"][1], data["scenarios"][0]]
        result = analyze(data)
        self.assertEqual(result["status"], "invalid_core_acceptance_batch")
        self.assertIn("scenario_execution_order_mismatch", result["violations"])
        self.assertFalse(result["ready_for_release_gate"])

    def test_rejects_invalid_child_contract_and_round_count(self):
        data = payload()
        data["scenarios"][0]["analysis"]["contract_valid"] = False
        data["scenarios"][0]["analysis"]["training"]["completed_rounds"] = 0
        result = analyze(data)
        self.assertIn("single:timeline_contract_invalid", result["violations"])
        self.assertIn("single:round_count_mismatch", result["violations"])
        self.assertFalse(result["core_contract_valid"])

    def test_rejects_duplicate_plan_or_missing_required_category(self):
        data = payload()
        data["plan"]["scenarios"][1] = copy.deepcopy(data["plan"]["scenarios"][0])
        data["scenarios"][1]["id"] = "single"
        data["scenarios"][1]["analysis"]["training"]["scenario_id"] = "single"
        result = analyze(data)
        self.assertIn("duplicate_plan_scenario", result["violations"])
        self.assertIn("required_category_missing", result["violations"])
        self.assertIn("category:fixed_branch", result["coverage_gaps"])


if __name__ == "__main__":
    unittest.main()
