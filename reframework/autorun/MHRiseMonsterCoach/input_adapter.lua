local M = {}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function first_enum_value(type_def, names)
    if type_def == nil then return nil end
    for _, name in ipairs(names) do
        local field = safe(function() return type_def:get_field(name) end)
        local value = field and safe(function() return field:get_data(nil) end) or nil
        if value ~= nil then return value, name end
    end
    return nil
end

function M.new(config)
    config = config or {}
    local gamepad = safe(function() return sdk.get_native_singleton("via.hid.GamePad") end)
    local gamepad_type = safe(function() return sdk.find_type_definition("via.hid.GamePad") end)
    local button_type = safe(function() return sdk.find_type_definition("via.hid.GamePadButton") end)
    local left_shoulder, left_shoulder_name = first_enum_value(button_type, { "LShoulder", "LB", "L1" })
    local right_shoulder, right_shoulder_name = first_enum_value(button_type, { "RShoulder", "RB", "R1" })
    local left_stick, left_stick_name = first_enum_value(button_type, { "LStickPush", "LStick", "LS" })
    local right_stick, right_stick_name = first_enum_value(button_type, { "RStickPush", "RStick", "RS" })
    return setmetatable({
        enabled = config.enabled ~= false,
        hold_seconds = tonumber(config.long_hold_seconds) or 0.75,
        singleton = gamepad,
        singleton_type = gamepad_type,
        buttons = {
            left_shoulder = left_shoulder,
            right_shoulder = right_shoulder,
            left_stick = left_stick,
            right_stick = right_stick,
        },
        button_names = {
            left_shoulder = left_shoulder_name,
            right_shoulder = right_shoulder_name,
            left_stick = left_stick_name,
            right_stick = right_stick_name,
        },
        round_started_at = nil,
        round_long_fired = false,
        active_device = "keyboard",
        last_state = nil,
    }, { __index = M })
end

local function read_device(self)
    if self.singleton == nil or self.singleton_type == nil then return nil end
    return safe(function()
        return sdk.call_native_func(self.singleton, self.singleton_type, "get_LastInputDevice")
    end) or safe(function()
        return sdk.call_native_func(self.singleton, self.singleton_type, "get_Device")
    end)
end

local function is_down(device, button)
    return device ~= nil and button ~= nil
        and safe(function() return device:call("isDown", button) end) == true
end

function M.poll(self, current_time)
    local available = self.enabled and self.singleton ~= nil and self.singleton_type ~= nil
        and self.buttons.left_shoulder ~= nil and self.buttons.right_shoulder ~= nil
        and self.buttons.left_stick ~= nil and self.buttons.right_stick ~= nil
    local state = {
        available = available,
        device = self.active_device,
        slowmo_down = false,
        capture_pressed = false,
        reset_pressed = false,
    }
    if not available then self.last_state = state return state end

    local device = read_device(self)
    local slowmo_down = is_down(device, self.buttons.left_shoulder)
        and is_down(device, self.buttons.right_shoulder)
    local round_down = is_down(device, self.buttons.left_stick)
        and is_down(device, self.buttons.right_stick)
    local now = tonumber(current_time) or 0

    if slowmo_down or round_down then self.active_device = "gamepad" end
    if round_down and self.round_started_at == nil then
        self.round_started_at = now
        self.round_long_fired = false
    elseif round_down and not self.round_long_fired and now - self.round_started_at >= self.hold_seconds then
        state.reset_pressed = true
        self.round_long_fired = true
    elseif not round_down and self.round_started_at ~= nil then
        if not self.round_long_fired then state.capture_pressed = true end
        self.round_started_at = nil
        self.round_long_fired = false
    end

    state.device = self.active_device
    state.slowmo_down = slowmo_down
    self.last_state = state
    return state
end

function M.mark_keyboard(self)
    self.active_device = "keyboard"
    if self.last_state then self.last_state.device = "keyboard" end
end

function M.description(self)
    return {
        available = self.last_state and self.last_state.available or false,
        device = self.active_device,
        slowmo_chord = "LB+RB / L1+R1",
        round_chord = "L3+R3",
        long_hold_seconds = self.hold_seconds,
        resolved_buttons = self.button_names,
    }
end

return M
