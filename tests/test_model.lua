package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Model = require("MHRiseMonsterCoach.model")

local config = {
    min_prediction_samples = 3,
    transition_history_limit = 8,
    learned_action_limit = 16,
}

local profile = {
    id = "test",
    name = "Test Monster",
    moves = {
        ["10"] = {
            name = "Fixed starter",
            short_name = "Starter",
            advice = "Dodge",
            next_kind = "fixed",
            next = { { action = "11" } },
        },
        ["11"] = { name = "Follow-up", short_name = "Follow", advice = "Guard" },
        ["30"] = {
            name = "Invalid fixed data",
            short_name = "Invalid",
            advice = "Test",
            next_kind = "fixed",
            next = { { action = "31" }, { action = "32" } },
        },
    },
    scenarios = {},
}

local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function truthy(value, message)
    if not value then error(message) end
end

local model = Model.new(profile, { moves = {}, scenarios = {} }, config)
model:set_context({ in_quest = false, is_online = false, target_found = false, reader_ready = false })
equal(model.state, Model.states.WAITING, "outside quest")

model:set_context({ in_quest = true, is_online = true, target_found = true, reader_ready = true })
equal(model.state, Model.states.DISABLED, "online is disabled")

model:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true, build_supported = false, game_name = "mhrise", tdb_version = 999 })
equal(model.state, Model.states.DISABLED, "unsupported build is read-only")
model:observe_action("10", 0.5)
equal(model.state, Model.states.DISABLED, "action observation does not unlock unsupported build")
model:set_context({ in_quest = false, is_online = false, target_found = false, reader_ready = false })

model:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true, safe_mode = true })
equal(model.state, Model.states.DISABLED, "diagnostic safe mode is disabled for gameplay")
model:set_context({ in_quest = false, is_online = false, target_found = false, reader_ready = false })

model:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true })
equal(model.state, Model.states.READY, "offline ready")

truthy(model:observe_action("10", 1), "first action changes state")
equal(model.prediction.kind, "fixed", "profile fixed prediction wins")
equal(model.prediction.candidates[1].action, "11", "fixed target")

model:observe_action("30", 1.5)
equal(model.prediction.kind, "conditional", "invalid multi-target fixed data is downgraded")
model:observe_action("10", 1.75)

model:observe_damage(12.5)
model:observe_action("11", 2)
equal(model.failures, 1, "damage closes failed round")
equal(model.streak, 0, "failure resets streak")

model:observe_action("12", 3)
equal(model.successes, 3, "no damage closes successful round")

-- Three identical observed transitions produce observed_single, never fixed.
for index = 1, 3 do
    model:observe_action("20", 10 + index * 2)
    model:observe_action("21", 11 + index * 2)
end
model:observe_action("20", 30)
equal(model.prediction.kind, "observed_single", "learned single remains observational")

-- A second target turns the result into candidates.
model:observe_action("22", 31)
model:observe_action("20", 32)
equal(model.prediction.kind, "observed_candidates", "multiple observed targets remain candidates")

-- History is bounded.
for index = 1, 20 do model:observe_action(tostring(100 + index), 100 + index) end
truthy(#model.history <= config.transition_history_limit, "history stays bounded")

model:set_context({ in_quest = false, is_online = false, target_found = false, reader_ready = false })
equal(model.current_action, nil, "leaving quest clears current action")

print("test_model.lua: PASS")
