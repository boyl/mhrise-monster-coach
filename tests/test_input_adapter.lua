package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local buttons = { LShoulder = 1, RShoulder = 2, LStickPush = 3, RStickPush = 4 }
local down = {}
local device = { call = function(_, method, button)
    assert(method == "isDown")
    return down[button] == true
end }
local button_type = { get_field = function(_, name)
    local value = buttons[name]
    if value == nil then return nil end
    return { get_data = function() return value end }
end }
local gamepad_type = {}
local singleton = {}
sdk = {
    get_native_singleton = function(name) assert(name == "via.hid.GamePad") return singleton end,
    find_type_definition = function(name)
        if name == "via.hid.GamePad" then return gamepad_type end
        if name == "via.hid.GamePadButton" then return button_type end
    end,
    call_native_func = function(owner, owner_type, method)
        assert(owner == singleton and owner_type == gamepad_type)
        assert(method == "get_LastInputDevice")
        return device
    end,
}

local Input = require("MHRiseMonsterCoach.input_adapter")
local adapter_config = { enabled = true, long_hold_seconds = 0.75 }
local input = Input.new(adapter_config)
local state = input:poll(0)
assert(state.available and state.device == "keyboard")

down[1], down[2] = true, true
state = input:poll(0.1)
assert(state.slowmo_down and state.device == "gamepad", "shoulder chord owns slow motion")
down[1], down[2] = false, false

down[3], down[4] = true, true
state = input:poll(1.0)
assert(not state.capture_pressed and not state.reset_pressed)
down[3], down[4] = false, false
state = input:poll(1.4)
assert(state.capture_pressed and not state.reset_pressed, "short chord fires capture on release")
state = input:poll(1.5)
assert(not state.capture_pressed, "short chord fires once")

down[3], down[4] = true, true
input:poll(2.0)
state = input:poll(2.8)
assert(state.reset_pressed and not state.capture_pressed, "long chord fires reset at threshold")
state = input:poll(3.0)
assert(not state.reset_pressed, "long chord stays latched")
down[3], down[4] = false, false
state = input:poll(3.1)
assert(not state.capture_pressed, "long chord release never fires short action")

input:mark_keyboard()
assert(input:description().device == "keyboard")
adapter_config.enabled = false
assert(not input:poll(4.0).available, "controller shortcuts can be disabled without reloading")

print("test_input_adapter.lua: PASS")
