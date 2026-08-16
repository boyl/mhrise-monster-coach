package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local manager = { enemies = {} }
sdk = {
    get_managed_singleton = function(name)
        if name == "snow.enemy.EnemyManager" then return manager end
        return nil
    end,
}

local Runtime = require("MHRiseMonsterCoach.runtime")

local runtime = setmetatable({
    profile = {
        training_quest = { id = 200032001 },
        enemy_ids = { [32] = true, ["em032_00"] = true },
    },
    methods = {
        boss_enemy_count = { call = function(_, value) return #value.enemies end },
        boss_enemy = { call = function(_, value, index) return value.enemies[index + 1] end },
        enemy_type = { call = function(_, enemy) return enemy.id end },
    },
    fields = {},
    enemy = { id = 32 },
    enemy_id = 32,
    enemy_anchor = {},
}, { __index = Runtime })

local found, reason = runtime:poll_target_enemy(123, false)
assert(found == false and reason ~= nil, "other quests are rejected")
assert(runtime.enemy == nil and runtime.enemy_anchor == nil, "other quests clear stale enemy state")

manager.enemies = { { id = 1 }, { id = 32 } }
found, reason = runtime:poll_target_enemy(200032001, false)
assert(found == true and reason == nil, "supported quest finds Tigrex")
assert(runtime.enemy == manager.enemies[2] and runtime.enemy_id == 32, "polling selects the matching boss")

found, reason = runtime:poll_target_enemy(200032001, true)
assert(found == false and reason ~= nil, "online quest is rejected")
assert(runtime.enemy == nil, "online transition clears enemy state")

runtime.methods.boss_enemy_count = { call = function() return 99 end }
found, reason = runtime:poll_target_enemy(200032001, false)
assert(found == false and reason == "Invalid boss enemy count", "invalid counts fail explicitly")

print("test_runtime_enemy_polling.lua: PASS")
