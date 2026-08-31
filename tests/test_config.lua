package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local loaded_config = {}
json = {
    load_file = function(path)
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
        return nil
    end,
    dump_file = function() end,
}
log = { error = function() end }

local Config = require("MHRiseMonsterCoach.config")

local defaults = Config.load()
assert(defaults.weapon_response_extension_enabled == false,
    "weapon response extension is disabled for new and existing configs by default")

loaded_config = { weapon_response_extension_enabled = true }
local opted_in = Config.load()
assert(opted_in.weapon_response_extension_enabled == true,
    "an explicit user opt-in enables the retained weapon response extension")

print("test_config.lua: PASS")
