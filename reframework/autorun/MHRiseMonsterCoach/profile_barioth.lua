-- Stable semantic metadata only. This profile remains research-only until a
-- dedicated quest and runtime Action mapping have passed product acceptance.
return {
    id = "barioth_mr_normal",
    name = "Barioth / 冰牙龙",
    enemy_ids = { [42] = true, ["em042_00"] = true },
    calibration_file = "barioth_calibration.json",
    static_ai_file = "barioth_static_ai.json",
    research_only = true,
    moves = {},
    scenarios = {},
    catalog = {},
}
