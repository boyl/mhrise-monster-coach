package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local keys = {}
local drawing_ui = false
reframework = {
    is_key_down = function(_, key) return keys[key] == true end,
    is_drawing_ui = function() return drawing_ui end,
}
imgui = {}
local logged_errors = 0
log = { error = function() logged_errors = logged_errors + 1 end }

local Controller = require("MHRiseMonsterCoach.controller")

local model = {
    context = { in_quest = true, is_online = false, target_found = true },
    state = "running",
    fail = function(self, message) self.failed = message end,
}
local runtime = {
    scales = {},
    restores = 0,
    set_time_scale = function(self, scale) self.scales[#self.scales + 1] = scale return true end,
    restore_time_scale = function(self) self.restores = self.restores + 1 return true end,
    anchors_ready = function() return true end,
    read_player_health = function() return 100 end,
}
local config = {
    enabled = true,
    time_control_enabled = true,
    slowmo_scale = 0.25,
    quick_reset_enabled = true,
    auto_capture_anchors = true,
    quick_reset_safe_frames = 2,
    quick_reset_cooldown_frames = 10,
    keys = { slowmo_hold = 117, quick_reset = 118, capture_anchor = 119, in_place_reset = 120 },
}
local controller = Controller.new(model, runtime, {}, config, {})

keys[117] = true
controller:update_slowmo()
controller:update_slowmo()
assert(#runtime.scales == 2, "toggle mode reapplies global speed while active")

keys[117] = false
controller:update_slowmo()
assert(#runtime.scales == 3 and runtime.restores == 0, "key release keeps toggle mode active")

keys[117] = true
controller:update_slowmo()
assert(runtime.restores == 1, "second F6 press disables slow motion")
keys[117] = false
controller:update_slowmo()
keys[117] = true
controller:update_slowmo()
assert(#runtime.scales == 4, "third F6 press enables slow motion again")
model.context.is_online = true
controller:update_slowmo()
assert(runtime.restores == 2, "online transition restores time")

model.context.is_online = false
model.context.build_supported = false
controller:update_slowmo()
assert(#runtime.scales == 4, "unsupported build never reapplies slow motion")

model.context.build_supported = true
config.diagnostic_safe_mode = true
keys[117] = false
controller:update_slowmo()
keys[117] = true
controller:update_slowmo()
assert(#runtime.scales == 5, "guarded time control remains available in diagnostic safe mode")
config.time_control_enabled = false
controller:update_slowmo()
assert(runtime.restores == 3, "disabling time control immediately restores normal speed")

local function same_failure() error("boom") end
controller:guard("same_failure", same_failure)
controller:guard("same_failure", same_failure)
assert(logged_errors == 1, "identical callback errors are logged once")

local restart_starts = 0
runtime.quest_restart = {
    state = "idle", status = "Waiting",
    is_active = function(self) return self.state == "wait_hub" end,
    start = function(self)
        restart_starts = restart_starts + 1
        self.state = "wait_hub"
        self.status = "Returning to hub"
        return true
    end,
    update = function(self)
        self.state = "complete"
        self.status = "Training quest restarted"
    end,
}
model.reset_round = function(self, reason) self.last_reset = reason end
config.diagnostic_safe_mode = false
config.time_control_enabled = true
controller.input_state = { capture_pressed = false, reset_pressed = true }
controller:quick_reset()
assert(restart_starts == 1 and runtime.quest_restart.state == "wait_hub",
    "F7 starts the complete one-key restart workflow")
drawing_ui = true
controller.input_state = { capture_pressed = false, reset_pressed = true }
controller:quick_reset()
assert(restart_starts == 1,
    "open REFramework menu consumes reset shortcut without execution")
drawing_ui = false
controller:update_quest_restart()
assert(runtime.quest_restart.state == "complete" and model.last_reset == "Training quest restarted",
    "one-key restart completion is visible")

local captures, in_place_resets = 0, 0
runtime.capture_anchors = function() captures = captures + 1 return true end
runtime.experimental_native_in_place_reset = function()
    in_place_resets = in_place_resets + 1
    return true
end
model.clear_round_runtime = function(self, reason) self.last_reset = reason end
keys[119] = true
controller:capture_reset_anchor()
keys[119] = false
controller:capture_reset_anchor()
keys[120] = true
controller:experimental_in_place_reset()
assert(captures == 1 and in_place_resets == 1,
    "F8 records a chosen point and F9 requests the native in-place candidate once")
keys[120] = false

local writes = 0
local health_values = { 100, 80 }
local health_index = 0
model.observe_damage = function(_, amount) assert(amount == 20) return true end
model.export_calibration = function() return { observed_hit_timing = {} } end
runtime.read_player_health = function()
    health_index = health_index + 1
    return health_values[health_index]
end
runtime.reader = { description = function() return { kind = "test" } end }
local config_module = { write_calibration = function() writes = writes + 1 end }
controller.config_module = config_module
config.diagnostic_safe_mode = true
controller:update_health()
controller:update_health()
assert(writes == 1, "safe mode passively persists hit timing evidence")

local training_requests = 0
local training_snapshot = { category = 0, action = 0 }
local scenario = {
    id = "tigrex_roar_single", name_zh = "咆哮", actions = { 19 },
    verification = { status = "verified" },
}
config.forced_action_training_enabled = true
config.training_repeat_count = 3
model.profile = { training_quest = { id = 200032001 } }
model.context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
model.current_metadata = { action_category = 0 }
model.coaching_state = function() return { phase = "unknown" } end
runtime.request_training_scenario = function(_, requested)
    assert(requested == scenario) training_requests = training_requests + 1 return true
end
runtime.current_action_snapshot = function() return training_snapshot end
controller.frame_counter = 100
assert(controller:start_training_scenario(scenario), "verified scenario starts from a safe entry state")
training_snapshot = { category = 4, action = 19 }
controller.frame_counter = 101
controller:update_training_scenario()
assert(controller.training_state == "running", "live Action match confirms scenario execution")
training_snapshot = { category = 0, action = 0 }
controller.frame_counter = 112
controller:update_training_scenario()
assert(controller.training_state == "waiting" and controller.training_completed_rounds == 1
    and training_requests == 1, "repeat training waits between rounds without a duplicate request")
controller.frame_counter = 142
controller:update_training_scenario()
assert(controller.training_state == "requested" and training_requests == 2,
    "repeat training automatically requests the next round after its safe gap")
training_snapshot = { category = 4, action = 19 }
controller.frame_counter = 143
controller:update_training_scenario()
training_snapshot = { category = 0, action = 0 }
controller.frame_counter = 154
controller:update_training_scenario()
controller.frame_counter = 184
controller:update_training_scenario()
training_snapshot = { category = 4, action = 19 }
controller.frame_counter = 185
controller:update_training_scenario()
training_snapshot = { category = 0, action = 0 }
controller.frame_counter = 196
controller:update_training_scenario()
assert(controller.training_state == "completed" and controller.training_completed_rounds == 3
    and training_requests == 3, "repeat training completes exactly the configured number of rounds")
model.current_metadata = { action_category = 4 }
model.coaching_state = function() return { phase = "startup" } end
controller.training_state = "idle"
assert(controller:start_training_scenario(scenario) and controller.training_state == "waiting"
    and training_requests == 3, "active monster attack queues training without interrupting the monster")
controller:cancel_training_scenario()
assert(controller.training_state == "cancelled", "queued repeat training can be stopped explicitly")

print("test_controller.lua: PASS")
