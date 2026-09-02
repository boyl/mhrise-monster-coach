package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Registry = require("MHRiseMonsterCoach.profile_registry")
local profiles = Registry.all()

assert(#profiles == 2, "the second real monster profile must be registered")
assert(type(profiles[3]) == "nil", "require loader data must not leak into the registry")
assert(Registry.default().id == "tigrex_mr_normal", "existing users must keep Tigrex as default")
assert(Registry.get("barioth_mr_normal").name == "Barioth / 冰牙龙")
assert(Registry.get("barioth_mr_normal").research_only == true)
assert(Registry.get("missing") == nil)

local ids = {}
for _, profile in ipairs(profiles) do
    assert(ids[profile.id] == nil, "profile ids must be unique")
    ids[profile.id] = true
    assert(type(profile.calibration_file) == "string")
    assert(type(profile.static_ai_file) == "string")
end

print("test_profile_registry.lua: PASS")
