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
model.current_action = "10"
model.current_state_key = "0:10"
model:update_player_combat_state({
    weapon_type = "long_sword",
    active_scroll = "unknown",
    resources = { usable_wirebugs = 1 },
    action_state = {},
})
assert(#model.response_candidates >= 1, "model evaluates weapon response candidates")
assert(model.response_candidates[#model.response_candidates].action == "evade", "unknown loadout retains safe fallback")
model.current_action = nil
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

model:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true, outcome_tracking = true })
equal(model.state, Model.states.READY, "offline ready")

truthy(model:observe_action("10", 1), "first action changes state")
equal(model.prediction.kind, "fixed", "profile fixed prediction wins")
equal(model.prediction.candidates[1].action, "11", "fixed target")

model:observe_action("30", 1.5)
equal(model.prediction.kind, "unresolved", "invalid multi-target fixed data is not mislabeled as conditional")
model:observe_action("10", 1.75)

local static_profile = { id = "static", name = "Static", moves = {}, scenarios = {} }
local static_ai = {
    required_action_category = 4,
    training_scenarios = {
        { id = "roar", actions = { 19 }, verification = { status = "verified" } },
    },
    moves = { ["15"] = { name = "Drift turn", short_name = "Drift", advice = "Wait" } },
    actions = {
        ["15"] = { kind = "fixed", evidence_count = 3, next = { { action = "2" } } },
        ["2"] = { kind = "conditional", next = { { action = "6" }, { action = "10" } } },
        ["30"] = { kind = "random", next = { { action = "6" }, { action = "10" } } },
        ["31"] = { kind = "observed", next = { { action = "6" } } },
    },
}
local static_model = Model.new(static_profile, { moves = {}, scenarios = {} }, config, static_ai)
equal(static_model.scenarios[1].id, "roar", "static AI contributes deployable training scenarios")
static_model.scenarios = {
    { id = "later", training_category = "fixed_branch", training_order = 20 },
    { id = "roar", training_category = "independent", training_order = 10 },
    { id = "earlier", training_category = "fixed_branch", training_order = 10 },
}
local catalog = static_model:training_catalog()
equal(catalog[1].id, "independent", "training catalog puts independent key moves first")
equal(catalog[1].scenarios[1].id, "roar", "training catalog retains its scenario")
equal(catalog[2].id, "fixed_branch", "verified branch starters form a separate group")
equal(catalog[2].scenarios[1].id, "earlier", "training catalog uses profile-defined order")
equal(catalog[2].scenarios[2].id, "later", "training catalog ordering is deterministic")
local branch_tree = static_model:training_branch_tree({ actions = { 15 } }, 3)
equal(branch_tree.name, "Drift", "training tree labels its root from monster knowledge")
equal(branch_tree.kind, "fixed", "training tree preserves fixed branch semantics")
equal(branch_tree.candidates[1].node.action, "2", "training tree exposes the verified successor")
equal(branch_tree.candidates[1].node.kind, "conditional", "nested branch keeps its own semantics")
static_model:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true, safe_mode = true })
static_model:observe_action("15", 1, { action_category = 4 })
equal(static_model.current_move.name, "Drift turn", "static move labels current ActionNo")
equal(static_model.prediction.kind, "fixed", "static unique ActionEnd edge is fixed")
equal(static_model.prediction.candidates[1].action, "2", "static fixed target")
static_model:observe_action("2", 2, { action_category = 4 })
equal(static_model.prediction.kind, "conditional", "static multiple targets remain conditional")
static_model:observe_action("30", 2.25, { action_category = 4 })
equal(static_model.prediction.kind, "random", "static random branch remains explicitly random")
static_model:observe_action("31", 2.5, { action_category = 4 })
equal(static_model.prediction.kind, "observed", "static observed branch is not upgraded to deterministic")
local wrong_category = Model.new(static_profile, { moves = {}, scenarios = {} }, config, static_ai)
wrong_category:set_context({ in_quest = true, is_online = false, target_found = true, reader_ready = true, safe_mode = true })
wrong_category:observe_action("15", 1, { action_category = 3 })
equal(wrong_category.prediction, nil, "static attack graph is gated by ActionCategory")
equal(wrong_category.current_move, nil, "non-attack category never reuses an attack label")
wrong_category:observe_action("15", 2, { action_category = 4 })
equal(wrong_category.current_move.name, "Drift turn", "same ActionNo in attack category is a distinct state")
equal(wrong_category.current_state_key, "4:15", "state identity combines ActionCategory and ActionNo")
truthy(static_model:reload_static_ai({ required_action_category = 4, actions = {} }), "static AI data reload succeeds")
equal(static_model.prediction, nil, "static AI reload refreshes current prediction")
equal(#static_model.scenarios, 0, "static AI reload refreshes training scenarios without duplication")
equal(static_model:reload_static_ai({ actions = {}, validation = { ok = false } }), false,
    "invalid monster pack cannot enter the model")

model:observe_damage(12.5)
model:observe_action("11", 2)
equal(model.failures, 1, "damage closes failed round")
equal(model.streak, 0, "failure resets streak")
local failed_timeline = model:training_timeline_snapshot().last_round
equal(failed_timeline.outcome, "hit", "training timeline classifies an outcome-tracked hit")
equal(failed_timeline.events[1].kind, "action_start", "training timeline begins at action start")
equal(failed_timeline.events[#failed_timeline.events].kind, "result", "training timeline ends with a result")

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
truthy(model.history[#model.history].previous_duration >= 0, "history records non-negative state duration")

local readonly = Model.new(profile, { moves = {}, scenarios = {} }, config)
readonly:set_context({
    in_quest = true,
    is_online = false,
    target_found = true,
    reader_ready = true,
    safe_mode = true,
    outcome_tracking = false,
})
readonly:observe_action("10", 1.0)
readonly:observe_action("99", 1.5, {
    action_category = 4,
    motion_name = "em032_roar",
    bank_id = 91,
    motion_id = 332,
    current_frame = 30.0,
    end_frame = 60.0,
    motion_progress = 0.5,
})
truthy(readonly:observe_damage(18), "read-only damage observation records timing evidence")
equal(readonly.last_hit_event.damage, 18, "read-only mode exposes the latest hit result")
equal(readonly.last_hit_event.frame, 30, "latest hit result records the action frame")
readonly.current_metadata.current_frame = 36.0
readonly.current_metadata.motion_progress = 0.6
truthy(readonly:observe_damage(12), "repeated hit expands the observed timing range")
equal(readonly.current_move.name, "em032_roar", "engine motion name labels uncatalogued states")
equal(readonly.state_changes, 1, "read-only transitions are counted")
equal(readonly.rounds, 0, "read-only transitions do not invent completed rounds")
equal(readonly.successes, 0, "read-only transitions do not invent successful outcomes")
equal(readonly.history[2].previous_duration, 0.5, "read-only timeline records state duration")
local evidence = readonly:export_calibration({ kind = "motion", name = "test" })
equal(evidence.schema_version, 5, "hit timing export uses schema version 5")
equal(#evidence.observed_history, 2, "timeline export includes chronological history")
equal(evidence.outcome_tracking, false, "timeline export declares unavailable outcomes")
equal(evidence.observed_state_metadata["4:99"].motion_name, "em032_roar", "timeline exports engine motion metadata")
local hit_timing = evidence.observed_hit_timing["4:99"]
equal(hit_timing.samples, 2, "hit timing aggregates samples without manual annotation")
equal(hit_timing.min_hit_frame, 30, "hit timing keeps earliest observed frame")
equal(hit_timing.max_hit_progress, 0.6, "hit timing keeps latest observed progress")
equal(hit_timing.total_damage, 30, "hit timing retains total observed damage")

readonly:observe_action("100", 2.0, {
    action_category = 4,
    motion_name = "em032_next",
    current_frame = 0,
})
local readonly_timeline = readonly:training_timeline_snapshot().last_round
equal(readonly_timeline.outcome, "observed_hit", "read-only timeline reports observed hits without scoring success")
equal(readonly.rounds, 0, "read-only timeline does not change scored rounds")

readonly:clear_round_runtime("Round reset in place")
equal(readonly.current_action, nil, "quick reset clears the previous action prompt")
equal(readonly.current_metadata, nil, "quick reset clears stale motion metadata")
equal(readonly.prediction, nil, "quick reset clears stale branch prediction")
equal(readonly.round_damage, 0, "quick reset clears current-round damage")
equal(readonly.last_hit_event, nil, "quick reset clears the previous hit result")
equal(readonly.status, "Round reset in place", "quick reset exposes an explicit result")

model:set_context({ in_quest = false, is_online = false, target_found = false, reader_ready = false })
equal(model.current_action, nil, "leaving quest clears current action")

print("test_model.lua: PASS")
