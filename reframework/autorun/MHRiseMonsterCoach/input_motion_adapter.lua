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

local PLAYER_INPUT_TERMS = {
    "input", "command", "key", "keyboard", "mouse", "button", "bind", "device",
    "config", "attack", "action", "on", "trg", "rel", "delay",
}

local MAX_CONTRACT_MEMBERS = 256
local MAX_CONTRACT_LEVELS = 8
local BINDING_DICTIONARY_FIELDS = {
    { role = "main_keyboard", name = "main_pl_Conf" },
    { role = "sub_keyboard", name = "sub_pl_Conf" },
    { role = "player_pad", name = "pad_pl_Conf" },
    { role = "static_pad", name = "pad_pl_Static" },
}

local BINDING_DICTIONARY_METHODS = {
    get_Item = true,
    ContainsKey = true,
    TryGetValue = true,
    get_Count = true,
    get_Keys = true,
    GetEnumerator = true,
}

local BINDING_TARGETS = {
    { role = "evade", name = "ACTION_ESCAPE" },
    { role = "primary_attack", name = "ACTION_X_ATTACK" },
    { role = "secondary_attack", name = "ACTION_A_ATTACK" },
    { role = "weapon_special", name = "ACTION_EX_GUARD_FIRE" },
}

local MAX_BINDING_LOOKUP_CALLS = 24

local function mentions_any(value, terms)
    local lower = string.lower(tostring(value or ""))
    for _, term in ipairs(terms or INPUT_CONTRACT_TERMS) do
        if string.find(lower, term, 1, true) ~= nil then return true end
    end
    return false
end

local function primitive_value(field, instance)
    local is_static = safe(function() return field:is_static() end) == true
    local owner = instance
    if is_static then owner = nil end
    local value = safe(function() return field:get_data(owner) end)
    if type(value) ~= "number" and type(value) ~= "boolean"
        and type(value) ~= "string" then return nil, is_static end
    return value, is_static
end

local function field_contract(field, instance)
    local value, is_static = primitive_value(field, instance)
    return {
        name = safe(function() return field:get_name() end),
        type = type_name(safe(function() return field:get_type() end)),
        is_static = is_static,
        primitive_value = value,
    }
end

local function method_metadata(method)
    local param_types, params = {}, {}
    local names = safe(function() return method:get_param_names() end) or {}
    for index, param_type in ipairs(safe(function() return method:get_param_types() end) or {}) do
        local current_type = type_name(param_type) or "unknown"
        param_types[#param_types + 1] = current_type
        params[#params + 1] = {
            index = index - 1,
            name = names[index],
            type = current_type,
            is_by_ref = safe(function() return param_type:is_by_ref() end) == true,
        }
    end
    return {
        name = safe(function() return method:get_name() end),
        return_type = type_name(safe(function() return method:get_return_type() end)),
        param_types = param_types,
        params = params,
        is_static = safe(function() return method:is_static() end) == true,
    }
end

-- Exact-type enum metadata only. This reads literal/static field values and never
-- invokes the enum or any gameplay method. Unknown types fail closed.
local function enum_contract(type_name_value)
    local type_def = safe(function() return sdk.find_type_definition(type_name_value) end)
    local result = { type = type_name_value, available = type_def ~= nil, values = {} }
    if type_def == nil then return result end
    for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
        if #result.values >= MAX_CONTRACT_MEMBERS then
            result.truncated = true
            break
        end
        local value, is_static = primitive_value(field, nil)
        if is_static and value ~= nil then
            result.values[#result.values + 1] = {
                name = safe(function() return field:get_name() end),
                value = value,
            }
        end
    end
    table.sort(result.values, function(a, b)
        if type(a.value) == "number" and type(b.value) == "number" and a.value ~= b.value then
            return a.value < b.value
        end
        return tostring(a.name) < tostring(b.name)
    end)
    return result
end

local function enum_value_by_name(contract, name)
    for _, item in ipairs(contract and contract.values or {}) do
        if item.name == name then return item.value end
    end
    return nil
end

local function enum_name_by_value(contract, value)
    for _, item in ipairs(contract and contract.values or {}) do
        if item.value == value then return item.name end
    end
    return nil
end

-- Bounded metadata over an explicitly named type. It exposes signatures and
-- primitive fields only; it neither scans the global TDB nor calls discovered methods.
local function filtered_type_contract(type_name_value, instance, terms)
    local type_def = safe(function() return sdk.find_type_definition(type_name_value) end)
    local result = {
        type = type_name_value,
        available = type_def ~= nil,
        fields = {},
        methods = {},
    }
    if type_def == nil then return result end
    for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
        if #result.fields >= MAX_CONTRACT_MEMBERS then
            result.fields_truncated = true
            break
        end
        local contract = field_contract(field, instance)
        if mentions_any(contract.name, terms) or mentions_any(contract.type, terms) then
            result.fields[#result.fields + 1] = contract
        end
    end
    for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
        if #result.methods >= MAX_CONTRACT_MEMBERS then
            result.methods_truncated = true
            break
        end
        local contract = method_metadata(method)
        if mentions_any(contract.name, terms) or mentions_any(contract.return_type, terms)
            or mentions_any(table.concat(contract.param_types, " "), terms) then
            result.methods[#result.methods + 1] = contract
        end
    end
    table.sort(result.fields, function(a, b) return tostring(a.name) < tostring(b.name) end)
    table.sort(result.methods, function(a, b)
        local a_key = tostring(a.name) .. "(" .. table.concat(a.param_types, ",") .. ")"
        local b_key = tostring(b.name) .. "(" .. table.concat(b.param_types, ",") .. ")"
        return a_key < b_key
    end)
    return result
end

local function filtered_type_hierarchy_contract(type_name_value, instance, terms)
    local type_def = safe(function() return sdk.find_type_definition(type_name_value) end)
    local result = { type = type_name_value, available = type_def ~= nil, levels = {} }
    local seen, depth = {}, 0
    while type_def ~= nil and depth < MAX_CONTRACT_LEVELS do
        local current_name = type_name(type_def) or "unknown"
        if seen[current_name] then break end
        seen[current_name] = true
        local level = filtered_type_contract(current_name, instance, terms)
        result.levels[#result.levels + 1] = level
        type_def = safe(function() return type_def:get_parent_type() end)
        depth = depth + 1
    end
    if type_def ~= nil then result.truncated = true end
    return result
end

local function binding_dictionary_field_contract(config_type, config_instance, spec)
    local result = {
        role = spec.role,
        name = spec.name,
        available = false,
        methods = {},
    }
    if config_type == nil then return result end
    local field = safe(function() return config_type:get_field(spec.name) end)
    if field == nil then return result end
    result.available = true
    result.is_static = safe(function() return field:is_static() end) == true
    result.declared_type = type_name(safe(function() return field:get_type() end))
    local owner = config_instance
    if result.is_static then owner = nil end
    local object = safe(function() return field:get_data(owner) end)
    result.object_available = object ~= nil
    local object_type = object and safe(function() return object:get_type_definition() end) or nil
    result.object_type = type_name(object_type)
    for _, method in ipairs(safe(function() return object_type:get_methods() end) or {}) do
        local name = safe(function() return method:get_name() end)
        if BINDING_DICTIONARY_METHODS[name] then
            result.methods[#result.methods + 1] = method_metadata(method)
        end
    end
    table.sort(result.methods, function(a, b)
        local a_key = tostring(a.name) .. "(" .. table.concat(a.param_types, ",") .. ")"
        local b_key = tostring(b.name) .. "(" .. table.concat(b.param_types, ",") .. ")"
        return a_key < b_key
    end)
    return result
end

-- Exact, read-only metadata over the four binding dictionaries already exposed by
-- snow.StmInputConfig. No dictionary method is invoked in this contract probe.
local function binding_dictionary_contract()
    local config_type = safe(function() return sdk.find_type_definition("snow.StmInputConfig") end)
    local config_instance = safe(function() return sdk.get_managed_singleton("snow.StmInputConfig") end)
    local result = {
        schema_version = 1,
        policy = "read_only_exact_dictionary_metadata",
        config_type_available = config_type ~= nil,
        config_instance_available = config_instance ~= nil,
        fields = {},
    }
    for _, spec in ipairs(BINDING_DICTIONARY_FIELDS) do
        result.fields[#result.fields + 1] = binding_dictionary_field_contract(
            config_type, config_instance, spec)
    end
    return result
end


local function exact_dictionary_object(config_type, config_instance, field_name)
    local field = config_type and safe(function() return config_type:get_field(field_name) end) or nil
    if field == nil then return nil, nil end
    local owner = config_instance
    if safe(function() return field:is_static() end) == true then owner = nil end
    local object = safe(function() return field:get_data(owner) end)
    local object_type = object and safe(function() return object:get_type_definition() end) or nil
    return object, object_type
end

local function exact_dictionary_lookup(object, object_type, key, value_enum, state)
    if object == nil or object_type == nil then return { status = "dictionary_unavailable" } end
    local contains = safe(function() return object_type:get_method("ContainsKey(System.Int32)") end)
    local item = safe(function() return object_type:get_method("get_Item(System.Int32)") end)
    if contains == nil or item == nil then return { status = "method_unavailable" } end
    if state.call_count >= MAX_BINDING_LOOKUP_CALLS then
        state.truncated = true
        return { status = "call_limit" }
    end
    state.call_count = state.call_count + 1
    local contains_ok, present = pcall(function() return contains:call(object, key) end)
    if not contains_ok then
        state.call_failures = state.call_failures + 1
        return { status = "contains_call_failed" }
    end
    if present ~= true then return { status = "key_unavailable" } end
    if state.call_count >= MAX_BINDING_LOOKUP_CALLS then
        state.truncated = true
        return { status = "call_limit" }
    end
    state.call_count = state.call_count + 1
    local item_ok, value = pcall(function() return item:call(object, key) end)
    if not item_ok then
        state.call_failures = state.call_failures + 1
        return { status = "item_call_failed" }
    end
    local raw = tonumber(value)
    if raw == nil then
        state.value_failures = state.value_failures + 1
        return { status = "value_unreadable" }
    end
    return {
        status = "resolved",
        name = enum_name_by_value(value_enum, raw),
        value = raw,
    }
end

-- Read only four explicit player actions from the already validated dictionaries.
-- The operation is cached and capped at ContainsKey + get_Item for three paths.
local function current_binding_values()
    local config_type = safe(function() return sdk.find_type_definition("snow.StmInputConfig") end)
    local config_instance = safe(function() return sdk.get_managed_singleton("snow.StmInputConfig") end)
    local logical = enum_contract("snow.StmInputManager.PL_INPUT")
    local keyboard = enum_contract("snow.StmInputManager.InGameMouseKeyBoardKey")
    local pad = enum_contract("snow.Pad.Button")
    local main, main_type = exact_dictionary_object(config_type, config_instance, "main_pl_Conf")
    local sub, sub_type = exact_dictionary_object(config_type, config_instance, "sub_pl_Conf")
    local player_pad, player_pad_type = exact_dictionary_object(
        config_type, config_instance, "pad_pl_Conf")
    local state = { call_count = 0, call_failures = 0, value_failures = 0, truncated = false }
    local result = {
        schema_version = 1,
        policy = "read_only_exact_dictionary_lookup",
        max_calls = MAX_BINDING_LOOKUP_CALLS,
        targets = {},
    }
    for _, target in ipairs(BINDING_TARGETS) do
        local raw = enum_value_by_name(logical, target.name)
        local entry = {
            role = target.role,
            logical_input = { name = target.name, value = raw },
        }
        if raw == nil then
            entry.main = { status = "logical_input_unavailable" }
            entry.sub = { status = "logical_input_unavailable" }
            entry.pad = { status = "logical_input_unavailable" }
        else
            entry.main = exact_dictionary_lookup(main, main_type, raw, keyboard, state)
            entry.sub = exact_dictionary_lookup(sub, sub_type, raw, keyboard, state)
            entry.pad = exact_dictionary_lookup(player_pad, player_pad_type, raw, pad, state)
        end
        result.targets[#result.targets + 1] = entry
    end
    result.call_count = state.call_count
    result.call_failures = state.call_failures
    result.value_failures = state.value_failures
    result.truncated = state.truncated
    return result
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
            if mentions_any(name) or mentions_any(field_type_name) then
                level.fields[#level.fields + 1] = field_contract(field, instance)
            end
        end
        for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
            local name = safe(function() return method:get_name() end)
            local contract = method_metadata(method)
            if mentions_any(name) or mentions_any(contract.return_type)
                or mentions_any(table.concat(contract.param_types, " ")) then
                level.methods[#level.methods + 1] = contract
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
        binding_dictionary_snapshot = nil,
        current_binding_snapshot = nil,
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
    local player_input_data = stm and safe(function() return stm:get_field("plParam") end) or nil
    if self.binding_dictionary_snapshot == nil then
        self.binding_dictionary_snapshot = binding_dictionary_contract()
    end
    if self.current_binding_snapshot == nil then
        self.current_binding_snapshot = current_binding_values()
    end
    return {
        schema_version = 6,
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
        semantic_command_enum = enum_contract("snow.player.PlayerInput.CommandButton2"),
        input_enum_contracts = {
            enum_contract("snow.StmInputManager.ActiveGameDevice"),
            enum_contract("snow.StmInputManager.ActiveDevice"),
            enum_contract("snow.StmInputManager.InGameInputDevice"),
            enum_contract("snow.StmInputConfig.KeyConfigType"),
            enum_contract("snow.StmInputManager.PL_INPUT"),
            enum_contract("snow.StmInputManager.STATIC_PL_INPUT"),
            enum_contract("snow.StmInputManager.InGameMouseKeyBoardKey"),
            enum_contract("snow.Pad.Button"),
            enum_contract("via.hid.MouseButton"),
        },
        known_type_contracts = {
            filtered_type_contract("snow.StmPlInputData", player_input_data, PLAYER_INPUT_TERMS),
            filtered_type_contract("snow.StmInputConfig", nil, PLAYER_INPUT_TERMS),
        },
        known_type_hierarchies = {
            filtered_type_hierarchy_contract(
                "snow.StmPlInputData", player_input_data, PLAYER_INPUT_TERMS),
        },
        binding_dictionaries = self.binding_dictionary_snapshot,
        current_bindings = self.current_binding_snapshot,
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
