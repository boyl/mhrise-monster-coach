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
}
local config = {
    enabled = true,
    time_control_enabled = true,
    slowmo_scale = 0.25,
    keys = { slowmo_hold = 117, quick_reset = 118, capture_anchor = 119 },
}
local controller = Controller.new(model, runtime, {}, config, {})

keys[117] = true
controller:update_slowmo()
controller:update_slowmo()
assert(#runtime.scales == 1, "hold applies slow motion once")

keys[117] = false
controller:update_slowmo()
assert(runtime.restores == 1, "release restores once")

keys[117] = true
controller:update_slowmo()
model.context.is_online = true
controller:update_slowmo()
assert(runtime.restores == 2, "online transition restores time")

model.context.is_online = false
model.context.build_supported = false
controller:update_slowmo()
assert(#runtime.scales == 2, "unsupported build never reapplies slow motion")

model.context.build_supported = true
config.diagnostic_safe_mode = true
controller:update_slowmo()
assert(#runtime.scales == 3, "guarded time control remains available in diagnostic safe mode")
config.time_control_enabled = false
controller:update_slowmo()
assert(runtime.restores == 3, "disabling time control immediately restores normal speed")

local function same_failure() error("boom") end
controller:guard("same_failure", same_failure)
controller:guard("same_failure", same_failure)
assert(logged_errors == 1, "identical callback errors are logged once")

local captures, resets = 0, 0
runtime.capture_anchors = function() captures = captures + 1 return true end
runtime.quick_reset = function() resets = resets + 1 return true end
model.reset_round = function() end
config.diagnostic_safe_mode = false
config.time_control_enabled = true
controller.input_state = { capture_pressed = true, reset_pressed = false }
controller:capture_anchors()
assert(captures == 1, "gamepad short chord reaches capture use case")
controller.input_state = { capture_pressed = false, reset_pressed = true }
controller:quick_reset()
assert(resets == 1, "gamepad long chord reaches reset use case")
drawing_ui = true
controller.input_state = { capture_pressed = true, reset_pressed = true }
controller:capture_anchors()
controller:quick_reset()
assert(captures == 1 and resets == 1, "open REFramework menu consumes controller events without execution")
drawing_ui = false

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
