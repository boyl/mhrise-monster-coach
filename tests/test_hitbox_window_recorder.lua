package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Model = require("MHRiseMonsterCoach.model")
local model = Model.new({ id = "test", moves = {}, scenarios = {} },
    { moves = {}, scenarios = {} },
    { min_prediction_samples = 3, transition_history_limit = 16, learned_action_limit = 16 },
    { actions = {} }, { actions = {} })
model:set_context({ in_quest = true, is_online = false, target_found = true,
    reader_ready = true, safe_mode = true, build_supported = true })

local function action(no, frame)
    model:observe_action(no, frame, { action_category = 4, motion_name = "em032_attack",
        current_frame = frame, motion_progress = frame / 30 })
end
local function hit(active, count)
    model:observe_hitboxes({ active = active, active_count = count or 0,
        source = "monster_coach_native", entries = {} })
end

for sample = 1, 3 do
    action(10, 0) hit(false)
    action(10, 10 + sample - 1) hit(true, 1)
    action(10, 13 + sample - 1) hit(true, 2)
    action(10, 14 + sample - 1) hit(false)
    action(11, 20)
    if sample < 3 then action(10, 0) end
end

local row = model:export_calibration({}).observed_hitbox_windows["4:10|em032_attack"]
assert(row.samples == 3 and row.window_count == 1)
assert(row.status == "confirmed")
assert(row.aggregate_windows[1].min_start_frame == 10)
assert(row.aggregate_windows[1].max_end_frame == 15)
assert(row.observations[1][1].max_active_count == 2)
model.current_state_key = "4:10"
model.current_metadata = { motion_name = "em032_attack", current_frame = 9 }
assert(model:current_monster_phase() == "startup")
model.current_metadata.current_frame = 12
assert(model:current_monster_phase() == "active")
model.current_metadata.current_frame = 20
assert(model:current_monster_phase() == "recovery")

-- A looping motion can keep the same Action ID while its frame counter wraps.
-- The recorder must create a new observation instead of a bogus start>end window.
local looping = Model.new({ id = "test", moves = {}, scenarios = {} },
    { moves = {}, scenarios = {} },
    { min_prediction_samples = 3, transition_history_limit = 16, learned_action_limit = 16 },
    { actions = {} }, { actions = {} })
looping:set_context({ in_quest = true, is_online = false, target_found = true,
    reader_ready = true, safe_mode = true, build_supported = true })
looping:observe_action(2, 0, { action_category = 4, motion_name = "rush", current_frame = 100 })
looping:observe_hitboxes({ active = true, active_count = 1, entries = {} })
looping:observe_action(2, 1, { action_category = 4, motion_name = "rush", current_frame = 110 })
looping:observe_hitboxes({ active = true, active_count = 1, entries = {} })
looping:observe_action(2, 2, { action_category = 4, motion_name = "rush", current_frame = 2 })
looping:observe_hitboxes({ active = true, active_count = 1, entries = {} })
looping:observe_action(2, 3, { action_category = 4, motion_name = "rush", current_frame = 14 })
looping:observe_hitboxes({ active = false, active_count = 0, entries = {} })
looping:observe_action(3, 4, { action_category = 4, motion_name = "idle", current_frame = 0 })
local loop_row = looping:export_calibration({}).observed_hitbox_windows["4:2|rush"]
assert(loop_row.samples == 2)
assert(loop_row.observations[1][1].start_frame == 100)
assert(loop_row.observations[1][1].end_frame == 110)
assert(loop_row.observations[2][1].start_frame == 2)
assert(loop_row.observations[2][1].end_frame == 2)

local migrated = Model.new({ id = "test", moves = {}, scenarios = {} }, {
    moves = {}, scenarios = {}, observed_hitbox_windows = { legacy = {
        state_key = "4:2", motion_name = "rush", samples = 2, status = "variable",
        observations = {
            { { start_frame = 110, end_frame = 15 } },
            { { start_frame = 2, end_frame = 14 }, { start_frame = 1, end_frame = 13 } },
        },
    } },
}, { min_prediction_samples = 3, transition_history_limit = 16, learned_action_limit = 16 },
    { actions = {} }, { actions = {} })
local repaired = migrated.hitbox_window_evidence.legacy
assert(migrated.evidence_revision == 1)
assert(repaired.samples == 2 and repaired.status == "repeated")
assert(repaired.observations[1][1].start_frame == 2)
assert(repaired.observations[2][1].start_frame == 1)

print("test_hitbox_window_recorder.lua: PASS")
