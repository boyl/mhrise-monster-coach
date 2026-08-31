#!/usr/bin/env python3
"""Validate a measured Monster Coach overlay snapshot from a real probe report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REQUIRED_PREFIX_GROUPS = (
    ("MONSTER COACH",),
    ("Target:",),
    ("Move:",),
    ("Next (", "Next:"),
    ("Phase / 阶段:",),
    ("Training ",),
)


def analyze(report: dict[str, Any]) -> dict[str, Any]:
    violations: list[str] = []
    training = report.get("training_acceptance") or {}
    layout = training.get("overlay_layout") or {}
    text = layout.get("text") if isinstance(layout.get("text"), list) else []
    widths = layout.get("text_widths") if isinstance(layout.get("text_widths"), list) else []

    if report.get("kind") != "training_scenario_acceptance" or report.get("status") not in {
        "completed",
        "failed",
    }:
        violations.append("terminal_training_report_required")
    if not layout:
        violations.append("overlay_layout_missing")

    numeric_fields = (
        "screen_width", "screen_height", "x", "y", "width", "height", "bottom",
        "bottom_margin", "content_width", "line_height", "line_count", "raw_line_count",
        "clipped_line_count", "max_lines",
    )
    for field in numeric_fields:
        if not isinstance(layout.get(field), (int, float)):
            violations.append(f"layout_field_missing:{field}")

    if layout:
        if layout.get("horizontal_overflow") is not False:
            violations.append("horizontal_overflow")
        if layout.get("vertical_overflow") is not False:
            violations.append("vertical_overflow")
        if isinstance(layout.get("bottom"), (int, float)) and isinstance(
            layout.get("screen_height"), (int, float)
        ) and isinstance(layout.get("bottom_margin"), (int, float)):
            if layout["bottom"] > layout["screen_height"] - layout["bottom_margin"]:
                violations.append("panel_exceeds_bottom_content_edge")
        if layout.get("line_count") != len(text):
            violations.append("line_count_mismatch")
        if isinstance(layout.get("line_count"), (int, float)) and isinstance(
            layout.get("max_lines"), (int, float)
        ) and layout["line_count"] > layout["max_lines"]:
            violations.append("line_budget_exceeded")
        if len(widths) != len(text):
            violations.append("text_width_count_mismatch")
        content_width = layout.get("content_width")
        if isinstance(content_width, (int, float)):
            for index, width in enumerate(widths):
                if not isinstance(width, (int, float)) or width <= 0:
                    violations.append(f"text_width_invalid:{index}")
                elif width > content_width:
                    violations.append(f"text_width_exceeded:{index}")

    font = layout.get("font") if isinstance(layout.get("font"), dict) else {}
    if font.get("ready") is not True:
        violations.append("cjk_font_not_ready")
    if not isinstance(font.get("sample_width"), (int, float)) or font.get("sample_width", 0) <= 0:
        violations.append("cjk_sample_width_invalid")

    visible = "\n".join(str(line) for line in text)
    for prefixes in REQUIRED_PREFIX_GROUPS:
        if not any(prefix in visible for prefix in prefixes):
            violations.append("required_text_missing:" + "|".join(prefixes))
    if "Weapon response:" in visible or "Long Sword loadout:" in visible:
        violations.append("optional_weapon_response_visible")

    controls_present = any(
        token in visible
        for token in ("F6:", "Press F6", "Hold LB+RB", "Release shoulder buttons")
    )
    if not controls_present:
        violations.append("active_device_controls_missing")

    valid = not violations
    return {
        "schema_version": 1,
        "status": "verified_measured_overlay" if valid else "invalid_measured_overlay",
        "contract_valid": valid,
        "violations": violations,
        "scenario_id": training.get("scenario_id"),
        "training_report_status": report.get("status"),
        "screen": {
            "width": layout.get("screen_width"),
            "height": layout.get("screen_height"),
        },
        "panel": {
            "x": layout.get("x"),
            "y": layout.get("y"),
            "width": layout.get("width"),
            "height": layout.get("height"),
            "line_count": layout.get("line_count"),
            "raw_line_count": layout.get("raw_line_count"),
            "clipped_line_count": layout.get("clipped_line_count"),
        },
        "font": font,
        "required_text_complete": not any(
            item.startswith("required_text_missing:") for item in violations
        ),
        "optional_weapon_response_hidden": "optional_weapon_response_visible" not in violations,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = analyze(json.loads(args.report.read_text(encoding="utf-8-sig")))
    payload = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0 if result["contract_valid"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
