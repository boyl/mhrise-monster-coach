import unittest

from tools.analyze_overlay_acceptance import analyze


def valid_report():
    text = [
        "MONSTER COACH | Tigrex / 轰龙",
        "Diagnostic mode",
        "Target: Tigrex detected | Enemy ID 32",
        "Move: 右回旋攻击",
        "Next (condition): 急停 / 漂移转向并再次冲锋",
        "Phase / 阶段: 判定中",
        "Training 右回旋攻击: 怪物正在执行 0/1",
        "F6: slow | F7: quest restart",
    ]
    return {
        "kind": "training_scenario_acceptance",
        "status": "completed",
        "training_acceptance": {
            "scenario_id": "tigrex_rotate_attack_right_single",
            "overlay_layout": {
                "screen_width": 1920,
                "screen_height": 1080,
                "x": 600,
                "y": 27,
                "width": 720,
                "height": 176,
                "bottom": 203,
                "bottom_margin": 18,
                "content_width": 696,
                "line_height": 19,
                "line_count": len(text),
                "raw_line_count": len(text),
                "clipped_line_count": 0,
                "max_lines": 53,
                "text": text,
                "text_widths": [300, 120, 330, 160, 500, 190, 360, 250],
                "horizontal_overflow": False,
                "vertical_overflow": False,
                "font": {
                    "ready": True,
                    "path": "NotoSansSC-Regular.otf",
                    "sample_width": 76,
                },
            },
        },
    }


class AnalyzeOverlayAcceptanceTests(unittest.TestCase):
    def test_accepts_measured_core_overlay_without_optional_response(self):
        result = analyze(valid_report())
        self.assertTrue(result["contract_valid"])
        self.assertEqual(result["status"], "verified_measured_overlay")
        self.assertTrue(result["required_text_complete"])
        self.assertTrue(result["optional_weapon_response_hidden"])

    def test_rejects_overflow_missing_font_and_false_certainty_surface(self):
        report = valid_report()
        layout = report["training_acceptance"]["overlay_layout"]
        layout["vertical_overflow"] = True
        layout["font"]["ready"] = False
        layout["font"]["sample_width"] = 0
        layout["text"] = [line for line in layout["text"] if not line.startswith("Next (")]
        layout["line_count"] = len(layout["text"])
        layout["text_widths"] = layout["text_widths"][: len(layout["text"])]
        result = analyze(report)
        self.assertFalse(result["contract_valid"])
        self.assertIn("vertical_overflow", result["violations"])
        self.assertIn("cjk_font_not_ready", result["violations"])
        self.assertIn("required_text_missing:Next (|Next:", result["violations"])

    def test_rejects_optional_weapon_response_in_core_surface(self):
        report = valid_report()
        layout = report["training_acceptance"]["overlay_layout"]
        layout["text"].insert(-1, "Weapon response: Foresight Slash")
        layout["text_widths"].insert(-1, 280)
        layout["line_count"] += 1
        layout["raw_line_count"] += 1
        result = analyze(report)
        self.assertFalse(result["contract_valid"])
        self.assertIn("optional_weapon_response_visible", result["violations"])


if __name__ == "__main__":
    unittest.main()
