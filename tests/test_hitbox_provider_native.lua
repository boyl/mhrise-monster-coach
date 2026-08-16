package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local hook_pre
local method = {}
local type_def = { get_method = function(_, name)
    assert(name:match("^initialize%(") ~= nil) return method
end }
local api = {
    find_type_definition = function(name) assert(name == "snow.hit.AttackWork") return type_def end,
    hook = function(value, pre) assert(value == method) hook_pre = pre end,
    to_managed_object = function(value) return value end,
    to_int = function(value) return value end,
}
local game_object = { get_address = function() return 100 end }
local collidable = {
    get_address = function() return 200 end,
    get_reference_count = function() return 2 end,
    read_byte = function(_, offset) assert(offset == 0x10) return 1 end,
}
local resource = { call = function(_, name) assert(name == "get_ResourcePath") return "em032.rcol" end }
local group = { call = function(_, name) assert(name == "get_Resource") return resource end }
local rsc_data = { call = function(_, name, index)
    assert(name == "getRequestSetGroups(System.UInt32)" and index == 3) return group
end }
local rsc = { call = function(_, name, a, b, c)
    if name == "get_GameObject" then return game_object end
    if name == "getNumCollidables(System.UInt32, System.UInt32)" then
        assert(a == 3 and b == 7) return 0
    end
    if name == "getCollidable(System.UInt32, System.UInt32, System.UInt32)" then
        assert(a == 3 and b == 7 and c == 0) return collidable
    end
    if name == "get_RSC" then return rsc_data end
    error(name)
end }
local attack_work = { call = function(_, name) assert(name == "get_RSCCtrl") return rsc end }
local enemy = { call = function(_, name) assert(name == "get_GameObject") return game_object end }

local Native = require("MHRiseMonsterCoach.hitbox_provider_native")
local provider = Native.new(api)
assert(provider:install() == true and type(hook_pre) == "function")
hook_pre({ [2] = attack_work, [5] = 3, [6] = 7 })
local sample = assert(provider:poll(enemy))
assert(sample.source == "monster_coach_native")
assert(sample.active == true and sample.active_count == 1 and sample.known_count == 1)
assert(sample.entries[1].resource_path == "em032.rcol" and sample.entries[1].set_idx == 7)
local stats = provider:description()
assert(stats.hook_requests_seen == 1 and stats.target_requests_seen == 1 and stats.collidables_seen == 1)
assert(stats.active_edges == 1 and stats.active_frames == 1)

collidable.read_byte = function() return 0 end
sample = assert(provider:poll(enemy))
assert(sample.active == false and sample.known_count == 1)
assert(provider:description().active_edges == 1)

print("test_hitbox_provider_native.lua: PASS")
