package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

reframework = {
    is_key_down = function() return false end,
    is_drawing_ui = function() return false end,
}

local Model = require("MHRiseMonsterCoach.model")
local Controller = require("MHRiseMonsterCoach.controller")

local profile = {
    id = "barioth_mr_normal", name = "Barioth / 冰牙龙", research_only = true,
    training_quest = { id = 200042001 }, moves = {}, scenarios = {}, catalog = {},
}
local static_ai = {
    monster = "em042",
    moves = {
        ["33"] = { name = "墙面回旋攻击（破坏态）", short_name = "墙面回旋（破坏态）" },
        ["34"] = { name = "墙面回旋循环/结束", short_name = "墙面回旋结束" },
        ["35"] = { name = "全力尾击转身起手", short_name = "全力尾击起手" },
        ["5005"] = { name = "全力尾击跳跃起手", short_name = "全力尾击跳跃" },
        ["5002"] = { name = "全力尾击第一段", short_name = "全力尾击第一段" },
    },
    actions = {
        ["33"] = { kind = "fixed", next = { { action = "34", evidence_count = 2 } } },
        ["35"] = { kind = "fixed", next = { { action = "5005", evidence_count = 2 } } },
        ["5005"] = { kind = "fixed", next = { { action = "5002", evidence_count = 2 } } },
    },
    training_scenarios = {},
}
local config = { timeline_event_limit = 32, forced_action_training_enabled = true,
    training_repeat_count = 5 }
local model = Model.new(profile, { moves = {}, scenarios = {} }, config, static_ai,
    { actions = {} })
model.context = { in_quest = true, quest_no = 200042001, is_online = false,
    build_supported = true, target_found = true }

local catalog = model:training_catalog()
assert(#catalog == 1 and catalog[1].id == "observed_branch"
    and #catalog[1].scenarios == 2,
    "research packs expose each static branch root once without inventing executable scenarios")
local first = catalog[1].scenarios[1]
assert(first.id == "observe_barioth_mr_normal_33"
    and first.verification.status == "observation_only",
    "observation entries have stable profile-scoped IDs and explicit verification state")

local controller = Controller.new(model, {}, {}, config, {}, nil, nil)
local menu = controller:training_menu_view_model(5, true)
assert(menu.state == "observe_only" and menu.state_label == "仅观察"
    and menu.scenario_count == 0 and menu.observation_count == 2
    and menu.show_repeat_controls == false and menu.can_start == false,
    "research menu exposes branch browsing while removing repeat and execution controls")
assert(controller:preview_training_scenario(first))
menu = controller:training_menu_view_model(5, true)
assert(menu.selected ~= nil and menu.selected.executable == false
    and menu.selected.branch_tree.candidates[1].node.action == "34"
    and menu.can_start == false,
    "an observation root can be selected and expanded but never started")

print("test_observation_catalog.lua: PASS")
