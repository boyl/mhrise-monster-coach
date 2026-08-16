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

local row = model:export_calibration({}).observed_hitbox_windows["4:10"]
assert(row.samples == 3 and row.window_count == 1)
assert(row.status == "confirmed")
assert(row.aggregate_windows[1].min_start_frame == 10)
assert(row.aggregate_windows[1].max_end_frame == 15)
assert(row.observations[1][1].max_active_count == 2)

print("test_hitbox_window_recorder.lua: PASS")
