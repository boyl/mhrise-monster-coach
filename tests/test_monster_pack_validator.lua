package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Validator = require("MHRiseMonsterCoach.monster_pack_validator")

local valid = {
    monster = "em032", required_action_category = 4,
    moves = { ["2"] = {}, ["10"] = {}, ["15"] = {} },
    actions = {
        ["2"] = { kind = "conditional", next = {
            { action = "10", condition = "distance" },
            { action = "15", condition = "boundary" },
        } },
        ["15"] = { kind = "fixed", next = { { action = "2" } } },
    },
    training_scenarios = {
        { id = "rush", training_category = "conditional_branch",
            execution_mode = "natural_condition", actions = { 2 },
            expected_branches = { { action = 10 }, { action = 15 } },
            positioning = { target = 15, tolerance = 5 }, max_verified_repeats = 1,
            verification = { status = "verified" } },
    },
}
assert(Validator.validate(valid).ok == true)

local invalid = {
    monster = "em999", required_action_category = 4,
    moves = { ["2"] = {}, ["10"] = {} },
    actions = {
        ["2"] = { kind = "fixed", next = { { action = "10" }, { action = "11" } } },
    },
    training_scenarios = {
        { id = "bad", training_category = "conditional_branch",
            execution_mode = "natural_condition", actions = { 2 },
            expected_successor = 99, positioning = "manual", max_verified_repeats = 0,
            verification = { status = "candidate" } },
    },
}
local result = Validator.validate(invalid)
assert(result.ok == false and #result.errors >= 6)
local paths = {}
for _, error in ipairs(result.errors) do paths[error.path] = true end
assert(paths["actions.2.next"] == true, "multi-target fixed branch is rejected")
assert(paths["actions.2.next[2].action"] == true, "unknown successor is rejected")
assert(paths["training_scenarios[1].expected_successor"] == true,
    "scenario cannot declare a branch absent from the graph")

local malformed = Validator.validate({
    monster = "em032", required_action_category = 4, moves = {}, actions = {
        ["2"] = { kind = "conditional", next = { false } },
    }, training_scenarios = { false },
})
assert(malformed.ok == false, "malformed rows are rejected without crashing")
local malformed_paths = {}
for _, error in ipairs(malformed.errors) do malformed_paths[error.path] = true end
assert(malformed_paths["actions.2.next[1]"] == true)
assert(malformed_paths["training_scenarios[1]"] == true)

print("test_monster_pack_validator.lua: PASS")
