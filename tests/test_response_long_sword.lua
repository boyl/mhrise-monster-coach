package.path = package.path .. ";./reframework/autorun/?.lua;./reframework/autorun/?/init.lua"

local Response = require("MHRiseMonsterCoach.response_long_sword")

local function find(results, action)
    for _, item in ipairs(results) do
        if item.action == action then return item end
    end
end

local base = {
    weapon_type = "long_sword",
    active_scroll = "red",
    switch_skills = { red = { "special_sheathe_combo", "soaring_kick" }, blue = {} },
    resources = { spirit_gauge = 20, spirit_level = 2, usable_wirebugs = 1 },
    action_state = { cancelable = true },
}

local results, err = Response.evaluate({ phase = "startup" }, base)
assert(err == nil)
assert(find(results, "foresight_slash").availability == "available")
assert(find(results, "iai_spirit_slash").availability == "available")
assert(find(results, "spirit_helmbreaker") == nil, "helmbreaker is not defensive startup advice")
assert(find(results, "evade").availability == "available")

results = Response.evaluate({ phase = "startup" }, {
    weapon_type = "long_sword",
    active_scroll = "red",
    switch_skills = { red = { "sacred_sheathe_combo" }, blue = {} },
    resources = { spirit_gauge = 0, usable_wirebugs = 0 },
    action_state = { cancelable = false },
})
assert(find(results, "foresight_slash").availability == "wait")
assert(find(results, "iai_spirit_slash").availability == "unavailable")
assert(find(results, "sacred_sheathe").availability == "available")

results = Response.evaluate({ phase = "recovery" }, base)
assert(find(results, "spirit_helmbreaker").availability == "available")

results = Response.evaluate({ phase = "startup" }, {
    weapon_type = "long_sword",
    active_scroll = "unknown",
    resources = {},
    action_state = {},
})
assert(find(results, "iai_spirit_slash").availability == "unknown")

local unsupported, unsupported_error = Response.evaluate({}, { weapon_type = "great_sword" })
assert(#unsupported == 0 and unsupported_error == "unsupported_weapon")

print("test_response_long_sword.lua: PASS")
