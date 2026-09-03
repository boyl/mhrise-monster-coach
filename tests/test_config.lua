package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local loaded_config = {}
local loaded_paths = {}
json = {
    load_file = function(path)
        loaded_paths[#loaded_paths + 1] = path
        if path == "MHRiseMonsterCoach/config.json" then return loaded_config end
        if path == "MHRiseMonsterCoach/tigrex_static_ai.json" then
            return {
                monster = "test_monster",
                required_action_category = 4,
                moves = {},
                actions = {},
                training_scenarios = {},
            }
        end
        if path == "MHRiseMonsterCoach/barioth_static_ai.json" then
            return {
                monster = "em042",
                required_action_category = 4,
                moves = { ["33"] = {}, ["34"] = {} },
                actions = { ["33"] = { kind = "fixed", next = { { action = "34" } } } },
                training_scenarios = {},
            }
        end
        return nil
    end,
    dump_file = function() end,
}
log = { error = function() end }

local Config = require("MHRiseMonsterCoach.config")

local defaults = Config.load()
assert(defaults.weapon_response_extension_enabled == false,
    "weapon response extension is disabled for new and existing configs by default")
assert(defaults.overlay_positioning_enabled == false
    and defaults.overlay_position.x == 0.5 and defaults.overlay_position.y == 0.065,
    "move HUD defaults to a non-interactive normalized screen position")
assert(defaults.simple_move_cue_enabled == true and defaults.detailed_overlay_enabled == false,
    "new and existing users get the simple cue without losing the opt-in detailed HUD")

loaded_config = { weapon_response_extension_enabled = true,
    overlay_position = { x = 4, y = -2 } }
local opted_in = Config.load()
assert(opted_in.weapon_response_extension_enabled == true,
    "an explicit user opt-in enables the retained weapon response extension")
assert(opted_in.overlay_position.x == 1 and opted_in.overlay_position.y == 0,
    "persisted move HUD position is clamped to the visible normalized screen")

loaded_paths = {}
local _, _, barioth_static = Config.load({
    calibration_file = "barioth_calibration.json",
    static_ai_file = "barioth_static_ai.json",
})
local observed = table.concat(loaded_paths, "|")
assert(string.find(observed, "MHRiseMonsterCoach/barioth_calibration.json", 1, true),
    "profile calibration path must be selected at the data boundary")
assert(string.find(observed, "MHRiseMonsterCoach/barioth_static_ai.json", 1, true),
    "profile static AI path must be selected at the data boundary")
assert(barioth_static.monster == "em042" and barioth_static.validation.ok == true,
    "the selected profile pack must pass the shared validator")

print("test_config.lua: PASS")
