local M = {}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function method_contract(type_def, name)
    local method = type_def and safe(function() return type_def:get_method(name) end) or nil
    if method == nil then return { available = false, name = name } end
    return { available = true, name = name, signature = tostring(method) }
end

local function type_name(type_def)
    return type_def and safe(function() return type_def:get_full_name() end) or nil
end

local INPUT_CONTRACT_TERMS = {
    "input", "key", "keyboard", "mouse", "button", "bind", "device", "config",
}

local function mentions_input_contract(value)
    local lower = string.lower(tostring(value or ""))
    for _, term in ipairs(INPUT_CONTRACT_TERMS) do
        if string.find(lower, term, 1, true) ~= nil then return true end
    end
    return false
end

-- This is deliberately a bounded metadata probe over one known singleton
-- hierarchy.  It never invokes an unknown input method or walks every TDB type.
local function input_contract_hierarchy(type_def, instance)
    local result, seen, depth = {}, {}, 0
    while type_def ~= nil and depth < 8 do
        local current_name = type_name(type_def) or "unknown"
        if seen[current_name] then break end
        seen[current_name] = true
        local level = { type = current_name, fields = {}, methods = {} }
        for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            local field_type = safe(function() return field:get_type() end)
            local field_type_name = type_name(field_type)
            if mentions_input_contract(name) or mentions_input_contract(field_type_name) then
                local value = safe(function() return field:get_data(instance) end)
                if type(value) ~= "number" and type(value) ~= "boolean"
                    and type(value) ~= "string" then value = nil end
                level.fields[#level.fields + 1] = {
                    name = name,
                    type = field_type_name,
                    is_static = safe(function() return field:is_static() end) == true,
                    primitive_value = value,
                }
            end
        end
        for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
            local name = safe(function() return method:get_name() end)
            local return_type = type_name(safe(function() return method:get_return_type() end))
            local param_types = {}
            for _, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
                param_types[#param_types + 1] = type_name(param_type) or "unknown"
            end
            if mentions_input_contract(name) or mentions_input_contract(return_type)
                or mentions_input_contract(table.concat(param_types, " ")) then
                level.methods[#level.methods + 1] = {
                    name = name,
                    return_type = return_type,
                    param_types = param_types,
                }
            end
        end
        table.sort(level.fields, function(a, b) return tostring(a.name) < tostring(b.name) end)
        table.sort(level.methods, function(a, b) return tostring(a.name) < tostring(b.name) end)
        result[#result + 1] = level
        type_def = safe(function() return type_def:get_parent_type() end)
        depth = depth + 1
    end
    return result
end

function M.new()
    local button_type = safe(function() return sdk.find_type_definition("via.hid.GamePadButton") end)
    local emu_up_field = button_type and safe(function() return button_type:get_field("EmuLup") end) or nil
    return setmetatable({
        singleton_type = safe(function() return sdk.find_type_definition("via.hid.GamePad") end),
        singleton = safe(function() return sdk.get_native_singleton("via.hid.GamePad") end),
        owned = false,
        desired_axis = nil,
        release_pending = false,
        requests = 0,
        writes = 0,
        emu_up = emu_up_field and safe(function() return emu_up_field:get_data(nil) end) or nil,
    }, { __index = M })
end

function M:write_axis(x, y)
    if self.singleton == nil or self.singleton_type == nil then
        return false, "via.hid.GamePad unavailable"
    end
    self.desired_axis = { x = tonumber(x) or 0, y = tonumber(y) or 0 }
    self.owned = true
    self.release_pending = false
    self.requests = self.requests + 1
    return true
end

function M:release()
    if not self.owned then return true end
    self.desired_axis = { x = 0, y = 0 }
    self.release_pending = true
    return true
end

function M:flush()
    if self.desired_axis == nil then return true end
    local device = safe(function()
        return sdk.call_native_func(self.singleton, self.singleton_type, "get_LastInputDevice")
    end)
    if device == nil then return false, "Last gamepad device unavailable" end
    local vector = safe(function()
        return Vector2f.new(self.desired_axis.x, self.desired_axis.y)
    end)
    if vector == nil then return false, "Vector2f unavailable" end
    local ok = pcall(function() device:call("set_AxisL", vector) end)
    if not ok then return false, "set_AxisL failed" end
    if self.emu_up ~= nil then
        local button = safe(function() return device:call("get_Button") end) or 0
        local desired_button = self.release_pending
            and (button & (~self.emu_up)) or (button | self.emu_up)
        local button_ok = pcall(function()
            device:call("set_Button", desired_button)
            device:call("set_ButtonDown", desired_button)
        end)
        if not button_ok then return false, "GamePadButton activity write failed" end
    end
    self.writes = self.writes + 1
    if self.release_pending then
        self.desired_axis = nil
        self.release_pending = false
        self.owned = false
    end
    return true
end

function M:diagnostics()
    local device = nil
    local device_source = nil
    if self.singleton ~= nil and self.singleton_type ~= nil then
        device = safe(function()
            return sdk.call_native_func(self.singleton, self.singleton_type, "get_LastInputDevice")
        end)
        if device ~= nil then device_source = "get_LastInputDevice" end
        if device == nil then
            device = safe(function()
                return sdk.call_native_func(self.singleton, self.singleton_type, "get_Device")
            end)
            if device ~= nil then device_source = "get_Device" end
        end
    end
    local device_type = device and safe(function() return device:get_type_definition() end) or nil
    local axis = device and safe(function() return device:call("get_AxisL") end) or nil
    local stm = safe(function() return sdk.get_managed_singleton("snow.StmInputManager") end)
    local stm_type = stm and safe(function() return stm:get_type_definition() end) or nil
    local active_device = stm and safe(function() return stm:get_field("_ActiveDevice") end) or nil
    return {
        schema_version = 1,
        policy = "read_only_known_hid_contract_probe",
        gamepad_singleton_available = self.singleton ~= nil,
        gamepad_type_available = self.singleton_type ~= nil,
        device_available = device ~= nil,
        device_source = device_source,
        device_type = device_type and safe(function() return device_type:get_full_name() end) or nil,
        axis_l = axis and { x = tonumber(axis.x), y = tonumber(axis.y) } or nil,
        methods = {
            get_axis_l = method_contract(device_type, "get_AxisL"),
            set_axis_l = method_contract(device_type, "set_AxisL(via.vec2)"),
            set_axis_l_unqualified = method_contract(device_type, "set_AxisL"),
            get_button = method_contract(device_type, "get_Button"),
            set_button = method_contract(device_type, "set_Button(via.hid.GamePadButton)"),
        },
        stm_input_manager_available = stm ~= nil,
        stm_input_manager_type = type_name(stm_type),
        stm_input_contract = input_contract_hierarchy(stm_type, stm),
        stm_active_device = active_device and safe(function()
            return tonumber(active_device:get_field("_ActiveDevice"))
                or tostring(active_device:get_field("_ActiveDevice"))
        end) or nil,
        emu_left_up_available = self.emu_up ~= nil,
        owned = self.owned,
        request_count = self.requests,
        write_count = self.writes,
    }
end

return M
