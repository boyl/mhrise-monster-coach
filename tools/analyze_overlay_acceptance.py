#!/usr/bin/env python3
"""Validate both measured Monster Coach overlay modes from a real probe report."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

NUMERIC_FIELDS = (
    "screen_width", "screen_height", "x", "y", "width", "height", "bottom",
    "bottom_margin", "content_width", "line_height", "line_count", "raw_line_count",
    "clipped_line_count", "max_lines", "detail_line_count",
)


def _validate_layout(layout: dict[str, Any], mode: str, violations: list[str]) -> str:
    if not layout:
        violations.append(f"{mode}:layout_missing")
        return ""
    for field in NUMERIC_FIELDS:
        if not isinstance(layout.get(field), (int, float)):
            violations.append(f"{mode}:layout_field_missing:{field}")
    text = layout.get("text") if isinstance(layout.get("text"), list) else []
    widths = layout.get("text_widths") if isinstance(layout.get("text_widths"), list) else []
    if layout.get("horizontal_overflow") is not False:
        violations.append(f"{mode}:horizontal_overflow")
    if layout.get("vertical_overflow") is not False:
        violations.append(f"{mode}:vertical_overflow")
    if layout.get("line_count") != len(text):
        violations.append(f"{mode}:line_count_mismatch")
    if len(widths) != len(text):
        violations.append(f"{mode}:text_width_count_mismatch")
    content_width = layout.get("content_width")
    if isinstance(content_width, (int, float)):
        for index, width in enumerate(widths):
            if not isinstance(width, (int, float)) or width <= 0:
                violations.append(f"{mode}:text_width_invalid:{index}")
            elif width > content_width:
                violations.append(f"{mode}:text_width_exceeded:{index}")
    if all(isinstance(layout.get(field), (int, float)) for field in
           ("bottom", "screen_height", "bottom_margin")):
        if layout["bottom"] > layout["screen_height"] - layout["bottom_margin"]:
            violations.append(f"{mode}:content_exceeds_bottom")
    font = layout.get("font") if isinstance(layout.get("font"), dict) else {}
    if font.get("ready") is not True:
        violations.append(f"{mode}:cjk_font_not_ready")
    if not isinstance(font.get("sample_width"), (int, float)) or font.get("sample_width", 0) <= 0:
        violations.append(f"{mode}:cjk_sample_width_invalid")
    return "\n".join(str(line) for line in text)


def analyze(report: dict[str, Any]) -> dict[str, Any]:
    violations: list[str] = []
    training = report.get("training_acceptance") or {}
    modes = training.get("overlay_modes") if isinstance(training.get("overlay_modes"), dict) else {}
    simple = modes.get("simple") if isinstance(modes.get("simple"), dict) else {}
    detailed = modes.get("detailed") if isinstance(modes.get("detailed"), dict) else {}
    if report.get("kind") != "training_scenario_acceptance" or report.get("status") not in {"completed", "failed"}:
        violations.append("terminal_training_report_required")

    simple_text = _validate_layout(simple, "simple", violations)
    if simple:
        if simple.get("simple_cue_enabled") is not True or simple.get("cue_visible") is not True:
            violations.append("simple:cue_not_visible")
        if simple.get("detailed_overlay_enabled") is not False:
            violations.append("simple:detailed_mode_visible")
        if simple.get("framed") is not False or simple.get("detail_line_count") != 0:
            violations.append("simple:not_frameless_move_only")
        if len(simple.get("text") or []) != 1:
            violations.append("simple:not_single_move_line")
        if any(token in simple_text for token in ("阶段：", "应对：", "训练 ·", "固定派生：")):
            violations.append("simple:detailed_text_leaked")

    detailed_text = _validate_layout(detailed, "detailed", violations)
    if detailed:
        if detailed.get("detailed_overlay_enabled") is not True:
            violations.append("detailed:mode_not_enabled")
        if detailed.get("framed") is not True or detailed.get("detail_line_count", 0) < 1:
            violations.append("detailed:panel_not_restored")
        for token in ("阶段：", "训练 ·"):
            if token not in detailed_text:
                violations.append(f"detailed:required_text_missing:{token}")

    valid = not violations
    return {
        "schema_version": 2,
        "status": "verified_dual_overlay_modes" if valid else "invalid_dual_overlay_modes",
        "contract_valid": valid,
        "violations": violations,
        "scenario_id": training.get("scenario_id"),
        "training_report_status": report.get("status"),
        "simple_move_only": simple.get("framed") is False and simple.get("detail_line_count") == 0,
        "detailed_hud_restored": detailed.get("framed") is True,
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
