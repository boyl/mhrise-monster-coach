local device_type = {}
function device_type:get_full_name() return "via.hid.MergedGamePadDevice" end
function device_type:get_method(name)
    if name == "get_AxisL" or name == "set_AxisL(via.vec2)" then return { name = name } end
    return nil
end
local device = {}
function device:get_type_definition() return device_type end
function device:call(name)
    if name == "get_AxisL" then return { x = 0.25, y = -0.5 } end
end
local stm = {}
function stm:get_type_definition()
    return { get_full_name = function() return "snow.StmInputManager" end }
end
function stm:get_field(name)
    if name == "_ActiveDevice" then
        return { get_field = function(_, nested) return nested == "_ActiveDevice" and 1 or nil end }
    end
end
local button_type = {}
function button_type:get_field(name)
    if name == "EmuLup" then return { get_data = function() return 8 end } end
end
sdk = {
    find_type_definition = function(name)
        if name == "via.hid.GamePad" then return {} end
        if name == "via.hid.GamePadButton" then return button_type end
    end,
    get_native_singleton = function() return {} end,
    call_native_func = function(_, _, name)
        if name == "get_LastInputDevice" then return device end
    end,
    get_managed_singleton = function(name) return name == "snow.StmInputManager" and stm or nil end,
}
Vector2f = { new = function(x, y) return { x = x, y = y } end }

local Adapter = require("MHRiseMonsterCoach.input_motion_adapter")
local diagnostics = Adapter.new():diagnostics()
assert(diagnostics.policy == "read_only_known_hid_contract_probe")
assert(diagnostics.device_available and diagnostics.device_source == "get_LastInputDevice")
assert(diagnostics.device_type == "via.hid.MergedGamePadDevice")
assert(diagnostics.axis_l.x == 0.25 and diagnostics.axis_l.y == -0.5)
assert(diagnostics.methods.get_axis_l.available)
assert(diagnostics.methods.set_axis_l.available)
assert(not diagnostics.methods.set_button.available)
assert(diagnostics.stm_input_manager_available)
assert(diagnostics.stm_active_device == 1 and diagnostics.emu_left_up_available)
local adapter = Adapter.new()
assert(adapter:write_axis(0, 1))
assert(adapter:diagnostics().owned and adapter:diagnostics().request_count == 1)
assert(adapter:flush() and adapter:diagnostics().write_count == 1)
assert(adapter:release())
assert(adapter:diagnostics().owned, "release remains owned until zero-axis flush")
assert(adapter:flush())
assert(not adapter:diagnostics().owned and adapter:diagnostics().write_count == 2)
print("test_input_motion_adapter.lua: PASS")
