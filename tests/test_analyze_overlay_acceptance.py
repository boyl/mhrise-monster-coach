import unittest

from tools.analyze_overlay_acceptance import analyze


def layout(text, *, detailed):
    return {
        "screen_width": 1920, "screen_height": 1080, "x": 510, "y": 70,
        "width": 900, "height": 100 if detailed else 36,
        "bottom": 170 if detailed else 106, "bottom_margin": 18,
        "content_width": 900, "line_height": 19, "line_count": len(text),
        "raw_line_count": len(text), "clipped_line_count": 0, "max_lines": 40,
        "detail_line_count": len(text) - 1 if detailed else 0,
        "text": text, "text_widths": [180 + i * 20 for i in range(len(text))],
        "horizontal_overflow": False, "vertical_overflow": False,
        "cue_visible": True, "simple_cue_enabled": True,
        "detailed_overlay_enabled": detailed, "framed": detailed,
        "font": {"ready": True, "path": "NotoSansSC-Regular.otf", "sample_width": 76},
    }


def valid_report():
    return {
        "kind": "training_scenario_acceptance", "status": "completed",
        "training_acceptance": {"scenario_id": "tigrex_roar_single", "overlay_modes": {
            "simple": layout(["咆哮"], detailed=False),
            "detailed": layout(["咆哮", "阶段：前摇", "训练 · 咆哮：1/3"], detailed=True),
        }},
    }


class AnalyzeOverlayAcceptanceTests(unittest.TestCase):
    def test_accepts_both_measured_modes(self):
        result = analyze(valid_report())
        self.assertTrue(result["contract_valid"])
        self.assertEqual(result["status"], "verified_dual_overlay_modes")
        self.assertTrue(result["simple_move_only"])
        self.assertTrue(result["detailed_hud_restored"])

    def test_rejects_detail_leaking_into_default_simple_mode(self):
        report = valid_report()
        simple = report["training_acceptance"]["overlay_modes"]["simple"]
        simple["text"].append("应对：离开正面")
        simple["text_widths"].append(220)
        simple["line_count"] = 2
        result = analyze(report)
        self.assertFalse(result["contract_valid"])
        self.assertIn("simple:not_single_move_line", result["violations"])
        self.assertIn("simple:detailed_text_leaked", result["violations"])

    def test_rejects_missing_detail_and_bad_simple_geometry(self):
        report = valid_report()
        report["training_acceptance"]["overlay_modes"]["simple"]["vertical_overflow"] = True
        report["training_acceptance"]["overlay_modes"]["detailed"] = None
        result = analyze(report)
        self.assertFalse(result["contract_valid"])
        self.assertIn("simple:vertical_overflow", result["violations"])
        self.assertIn("detailed:layout_missing", result["violations"])

    def test_contract_is_independent_from_training_outcome(self):
        report = valid_report()
        report["status"] = "failed"
        result = analyze(report)
        self.assertTrue(result["contract_valid"])


if __name__ == "__main__":
    unittest.main()
