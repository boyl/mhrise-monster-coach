package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local keys = {}
reframework = {
    is_key_down = function(_, key) return keys[key] == true end,
    is_drawing_ui = function() return false end,
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
assert(#runtime.scales == 2, "safe mode never applies slow motion")

local function same_failure() error("boom") end
controller:guard("same_failure", same_failure)
controller:guard("same_failure", same_failure)
assert(logged_errors == 1, "identical callback errors are logged once")

print("test_controller.lua: PASS")
