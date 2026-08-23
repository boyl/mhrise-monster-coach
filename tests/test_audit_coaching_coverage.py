import unittest

from tools.audit_coaching_coverage import (
    action_from_state_key,
    audit,
    category_from_state_key,
    refresh_prediction_coverage,
)


class CoachingCoverageTests(unittest.TestCase):
    def test_extracts_action_from_category_and_motion_key(self):
        self.assertEqual(action_from_state_key("4:5004|em032_00_08070"), "5004")
        self.assertEqual(action_from_state_key("4:21"), "21")
        self.assertIsNone(action_from_state_key("unknown"))
        self.assertEqual(category_from_state_key("4:21|motion"), 4)

    def test_reports_only_observed_core_gaps(self):
        static_pack = {
            "monster": "em032",
            "required_action_category": 4,
            "moves": {
                "2": {"short_name": "冲锋", "advice": "侧移"},
                "6": {"short_name": "回旋"},
            },
            "threats": {"6": {"response": "离开尾部"}},
            "actions": {
                "2": {"kind": "fixed", "next": [{"action": "6"}]},
            },
        }
        calibration = {
            "observed_state_metadata": {"4:2": {}, "4:6": {}, "0:90": {}},
            "observed_hitbox_windows": {
                "4:2|rush": {"status": "confirmed"},
                "4:6|spin": {"status": "observed"},
            },
        }
        report = audit(static_pack, calibration)
        self.assertEqual(report["summary"]["observed_attack_actions"], 2)
        self.assertEqual(report["gaps"]["observed_without_name"], [])
        self.assertEqual(report["gaps"]["observed_without_response"], [])
        self.assertEqual(report["gaps"]["observed_without_reliable_phase"], ["6"])
        self.assertEqual(report["coverage"]["fixed_prediction_actions"], ["2"])

    def test_keeps_prediction_certainty_classes_separate(self):
        static_pack = {
            "monster": "em032",
            "schema_version": 1,
            "actions": {
                "2": {"kind": "conditional", "next": [{"action": "10"}, {"action": "15"}]},
                "15": {"kind": "fixed", "next": [{"action": "2"}]},
                "20": {"kind": "random", "next": [{"action": "21"}, {"action": "24"}]},
                "21": {"kind": "observed", "next": [{"action": "6"}]},
                "22": {"kind": "fixed", "next": [{"action": "6"}, {"action": "7"}]},
            },
        }
        existing = {
            "summary": {},
            "coverage": {"observed_actions": ["2", "15", "99"]},
            "gaps": {},
        }
        report = refresh_prediction_coverage(existing, static_pack)
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["coverage"]["conditional_prediction_actions"], ["2"])
        self.assertEqual(report["coverage"]["fixed_prediction_actions"], ["15"])
        self.assertEqual(report["coverage"]["random_prediction_actions"], ["20"])
        self.assertEqual(report["coverage"]["observed_prediction_actions"], ["21"])
        self.assertEqual(report["coverage"]["unresolved_prediction_actions"], ["22"])
        self.assertEqual(report["gaps"]["observed_without_prediction"], ["99"])


if __name__ == "__main__":
    unittest.main()
