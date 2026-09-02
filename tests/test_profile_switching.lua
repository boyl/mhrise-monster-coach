package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

sdk = { get_managed_singleton = function() return nil end }
reframework = {
    is_key_down = function() return false end,
    is_drawing_ui = function() return false end,
}

local Model = require("MHRiseMonsterCoach.model")
local Runtime = require("MHRiseMonsterCoach.runtime")
local Controller = require("MHRiseMonsterCoach.controller")

local tigrex = {
    id = "tigrex_mr_normal", name = "Tigrex", enemy_ids = { [32] = true },
    training_quest = { id = 200032001, map_id = 14 }, moves = {}, scenarios = {},
}
local barioth = {
    id = "barioth_mr_normal", name = "Barioth", enemy_ids = { [42] = true },
    training_quest = { id = 200042001, map_id = 14 }, moves = {}, scenarios = {},
    research_only = true,
}
local config = { timeline_event_limit = 32 }
local model = Model.new(tigrex, { moves = {}, scenarios = {} }, config,
    { moves = {}, actions = {}, training_scenarios = {} }, { actions = {} })
model.current_action = 19
model.rounds = 4
assert(model:activate_profile(barioth, { moves = {}, scenarios = {} }, {
    monster = "em042", moves = {}, actions = {}, training_scenarios = {},
}) == true)
assert(model.profile.id == "barioth_mr_normal")
assert(model.current_action == nil and model.rounds == 0,
    "per-monster runtime evidence must reset during an in-place profile switch")

local runtime = setmetatable({
    profile = tigrex,
    config = {},
    quest_posting = { target_quest_id = tigrex.training_quest.id },
    time_scale_owned = false,
    enemy = { id = 32 },
    enemy_id = 32,
    enemy_anchor = {},
    player_anchor = {},
}, { __index = Runtime })
assert(runtime:activate_profile(barioth) == true)
assert(runtime.profile.id == "barioth_mr_normal")
assert(runtime.quest_posting.target_quest_id == 200042001)
assert(runtime.enemy == nil and runtime.enemy_anchor == nil and runtime.player_anchor == nil,
    "runtime target ownership must reset before polling the new monster")
assert(runtime.quest_restart.quest_id == 200042001)
assert(runtime:activate_profile(barioth) == false, "same-profile selection is idempotent")
runtime.last_context = {
    in_quest = true, is_online = false, build_supported = true,
    quest_no = 200042001, target_found = true,
}
local forced_ok, forced_reason = runtime:request_forced_action_probe(19)
assert(forced_ok == false and tostring(forced_reason):find("research%-only") ~= nil,
    "research-only profiles must fail closed before reaching native action writes")

local switch_model = Model.new(tigrex, { moves = {}, scenarios = {} }, config,
    { moves = {}, actions = {}, training_scenarios = {} }, { actions = {} })
local switch_runtime = {
    context = function()
        return {
            profile_id = barioth.id,
            in_quest = true,
            is_online = false,
            build_supported = true,
            quest_no = barioth.training_quest.id,
            target_found = true,
            player_found = true,
        }
    end,
    player_combat_state = function() return nil end,
}
local loaded_profile = nil
local config_module = {
    load_monster_data = function(profile)
        loaded_profile = profile.id
        return { moves = {}, scenarios = {} }, {
            monster = "em042", moves = {}, actions = {}, training_scenarios = {},
        }
    end,
}
local registry = {
    get = function(id) return id == barioth.id and barioth or nil end,
}
local controller = Controller.new(switch_model, switch_runtime, {}, config,
    config_module, nil, nil, registry)
controller:update_context()
assert(loaded_profile == barioth.id and switch_model.profile.id == barioth.id,
    "controller must load and activate the profile selected by runtime quest context")
assert(switch_model.context.profile_id == barioth.id,
    "the first context after a switch must belong to the newly active profile")

print("test_profile_switching.lua: PASS")
