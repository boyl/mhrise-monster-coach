-- Stable semantic data only. Runtime Action IDs belong in the calibration JSON.
return {
    id = "tigrex_mr_normal",
    name = "Tigrex / 轰龙",
    enemy_ids = { [32] = true, [5000] = true, ["em032_00"] = true },
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
