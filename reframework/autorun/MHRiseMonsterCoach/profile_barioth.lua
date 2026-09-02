-- Stable semantic metadata plus a dedicated observation quest. This profile
-- remains research-only until its runtime Action mapping passes acceptance.
return {
    id = "barioth_mr_normal",
    name = "Barioth / 冰牙龙",
    enemy_ids = { [42] = true, ["em042_00"] = true },
    calibration_file = "barioth_calibration.json",
    static_ai_file = "barioth_static_ai.json",
    research_only = true,
    training_quest = {
        id = 200042001,
        name = "[Coach] Barioth - Forlorn Arena",
        name_zh = "[陪练] 冰牙龙·塔之秘境",
        map_id = 14,
        map_name = "Forlorn Arena / 塔之秘境",
        menu_path = "Gathering Hub > Master Rank > 4-star",
        requires = "RiseQuestLoader",
    },
    moves = {},
    scenarios = {},
    catalog = {},
}
