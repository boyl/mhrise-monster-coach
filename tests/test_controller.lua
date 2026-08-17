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
    keys = { slowmo_hold = 117, quick_reset = 118, capture_anchor = 119 },
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

local traces_started, traces_flushed, native_resets = 0, 0, 0
runtime.quest_reset_trace = { active = false }
runtime.start_quest_reset_trace = function(self)
    traces_started = traces_started + 1
    self.quest_reset_trace.active = true
    return true
end
runtime.flush_quest_reset_trace = function(self, _, stop)
    traces_flushed = traces_flushed + 1
    if stop then self.quest_reset_trace.active = false end
    return true
end
runtime.request_native_quest_reset = function()
    native_resets = native_resets + 1
    return true
end
model.reset_round = function(self, reason) self.last_reset = reason end
config.diagnostic_safe_mode = false
config.time_control_enabled = true
controller.input_state = { capture_pressed = false, reset_pressed = true }
controller:quick_reset()
assert(traces_started == 1 and native_resets == 1 and runtime.quest_reset_trace.active,
    "F7 requests only the observed native reset entry and arms tracing")
drawing_ui = true
controller.input_state = { capture_pressed = false, reset_pressed = true }
controller:quick_reset()
assert(traces_started == 1 and native_resets == 1,
    "open REFramework menu consumes reset shortcut without execution")
drawing_ui = false

model.context.in_quest = false
for _ = 1, 120 do controller:update_quest_reset_trace() end
assert(not runtime.quest_reset_trace.active and traces_flushed == 120,
    "trace completes after the quest has exited for a stable window")
assert(model.last_reset == "Quest reset trace captured", "trace completion is visible")

controller:arm_quest_launch_trace()
assert(runtime.quest_reset_trace.active and controller.reset_trace_mode == "hub_launch",
    "F7 at the hub arms launch tracing without gameplay writes")
model.context.in_quest = true
for _ = 1, 120 do controller:update_quest_reset_trace() end
assert(not runtime.quest_reset_trace.active and model.last_reset == "Quest launch trace captured",
    "launch trace completes after stable quest entry")

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

print("test_controller.lua: PASS")
