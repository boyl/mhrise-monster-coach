-- Stable semantic data only. Runtime Action IDs belong in the calibration JSON.
return {
    id = "tigrex_mr_normal",
    name = "Tigrex / 轰龙",
    enemy_ids = { [32] = true, [5000] = true, ["em032_00"] = true },
    training_quest = {
        id = 200032001,
        player_calibration_id = 200032002,
        name = "[Coach] Tigrex - Forlorn Arena",
        name_zh = "[陪练] 轰龙·塔之秘境",
        map_id = 14,
        map_name = "Forlorn Arena / 塔之秘境",
        menu_path = "Gathering Hub > Master Rank > 4-star",
        requires = "RiseQuestLoader",
    },
    moves = {},
    scenarios = {},
    catalog = {
        "charge",
        "spin",
        "bite",
        "rock_throw",
        "roar",
    },
}
