package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local game_object = {}
local enemy = { call = function(_, name) assert(name == "get_GameObject") return game_object end }
local modules = {
    ["HitboxViewer.config.version"] = { version = "2.2.0" },
    ["HitboxViewer.config.init"] = { current = { mod = { enabled_hitboxes = true } } },
    ["HitboxViewer.character.char_cache"] = { by_gameobject = {} },
}
modules["HitboxViewer.character.char_cache"].by_gameobject[game_object] = { hitboxes = {
    a = { is_enabled = true, resource_idx = 3, set_idx = 7, collidable_idx = 1,
        log_entry = { resource_path = "enemy/em032.rcol", attack_id = "attack-a" } },
    b = { is_enabled = false },
} }
local unavailable_sdk = { find_type_definition = function() return nil end }
local Provider = require("MHRiseMonsterCoach.hitbox_provider")
local provider = Provider.new({ loader = function(name) return assert(modules[name], name) end,
    sdk = unavailable_sdk })
local sample = assert(provider:poll(enemy))
assert(sample.active and sample.active_count == 1 and sample.known_count == 2)
assert(sample.entries[1].set_idx == 7 and sample.entries[1].attack_id == "attack-a")

local unsupported = Provider.new({ sdk = unavailable_sdk, loader = function(name)
    if name == "HitboxViewer.config.version" then return { version = "9.0.0" } end
end })
assert(unsupported:description().available == false)
assert(unsupported:poll(enemy) == nil)

local hook_attempted = false
local gated = Provider.new({ enabled = false, sdk = {
    find_type_definition = function() hook_attempted = true end,
}, loader = function() error("not installed") end })
assert(hook_attempted == false, "unsupported runtimes must not inspect or hook AttackWork")
assert(gated:description().primary.available == false)

print("test_hitbox_provider.lua: PASS")
