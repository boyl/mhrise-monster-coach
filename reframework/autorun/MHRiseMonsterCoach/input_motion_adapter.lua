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
    "config", "attack", "action", "on", "trg", "rel", "delay", "update", "check", "set",
}

local SEMANTIC_INPUT_TYPES = {
    { name = "snow.StmInputManager", singleton = true },
    { name = "snow.StmPlayerInput", singleton = true },
    { name = "snow.player.PlayerInput", singleton = false },
    { name = "snow.StmInputManager.InputUI", singleton = false },
}

local SEMANTIC_QUERY_METHODS = {
    getOn = true,
    getTrg = true,
    getRel = true,
    getDelay = true,
    isOn = true,
    isTrg = true,
    isRel = true,
    isDelay = true,
}

local SEMANTIC_BITSET_GETTERS = { "getOn", "getTrg", "getRel", "getDelay" }
local SEMANTIC_BITSET_TERMS = {
    "bit", "flag", "get", "is", "set", "clear", "reset", "add", "remove", "toggle",
}

local PLAYER_INPUT_OWNER_TERMS = { "input", "command", "button" }
local PLAYER_INPUT_INSTANCE_TERMS = {
    "input", "command", "button", "pad", "flag", "now", "trg", "rel", "delay",
}
local PLAYER_INPUT_OWNER_TYPES = {
    ["snow.StmPlayerInput"] = true,
    ["snow.player.PlayerInput"] = true,
}
local PLAYER_INPUT_QUERY_COMMANDS = { "Atk_X", "Atk_A", "Atk_R_A", "Escape" }

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
    local is_static = safe(function() return field:is_static() end) == true
    local owner = is_static and nil or instance
    local value = safe(function() return field:get_data(owner) end)
    local primitive = nil
    if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then
        primitive = value
    end
    local object_type = nil
    if value ~= nil and primitive == nil then
        object_type = type_name(safe(function() return value:get_type_definition() end))
    end
    local contract = {
        name = safe(function() return field:get_name() end),
        type = type_name(safe(function() return field:get_type() end)),
        is_static = is_static,
        value_available = value ~= nil,
        primitive_value = primitive,
        object_available = object_type ~= nil,
        object_type = object_type,
    }
    return contract, value
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
local function filtered_type_contract(type_name_value, instance, terms, field_observer)
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
        local field_name = safe(function() return field:get_name() end)
        local field_type = type_name(safe(function() return field:get_type() end))
        if mentions_any(field_name, terms) or mentions_any(field_type, terms) then
            -- Read only a field whose metadata already matches the bounded terms.
            -- This prevents unrelated current-player fields from being touched.
            local contract, value = field_contract(field, instance)
            result.fields[#result.fields + 1] = contract
            if field_observer ~= nil then field_observer(contract, value) end
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

local function filtered_type_hierarchy_contract(type_name_value, instance, terms, field_observer)
    local type_def = safe(function() return sdk.find_type_definition(type_name_value) end)
    local result = { type = type_name_value, available = type_def ~= nil, levels = {} }
    local seen, depth = {}, 0
    while type_def ~= nil and depth < MAX_CONTRACT_LEVELS do
        local current_name = type_name(type_def) or "unknown"
        if seen[current_name] then break end
        seen[current_name] = true
        local level = filtered_type_contract(current_name, instance, terms, function(contract, value)
            if field_observer ~= nil then field_observer(current_name, contract, value) end
        end)
        result.levels[#result.levels + 1] = level
        type_def = safe(function() return type_def:get_parent_type() end)
        depth = depth + 1
    end
    if type_def ~= nil then result.truncated = true end
    return result
end

local function allowlisted_method_contracts(type_def, allowlist)
    local result = {}
    for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
        if #result >= MAX_CONTRACT_MEMBERS then break end
        local name = safe(function() return method:get_name() end)
        if allowlist[name] then result[#result + 1] = method_metadata(method) end
    end
    table.sort(result, function(a, b)
        local a_key = tostring(a.name) .. "(" .. table.concat(a.param_types, ",") .. ")"
        local b_key = tostring(b.name) .. "(" .. table.concat(b.param_types, ",") .. ")"
        return a_key < b_key
    end)
    return result
end

-- Bounded metadata for the MHR semantic command layer. Singleton resolution and
-- type inspection are read-only; no discovered gameplay method is called or hooked.
local function semantic_input_metadata_contract()
    local result = {
        schema_version = 1,
        policy = "read_only_exact_semantic_input_metadata",
        gameplay_method_calls = 0,
        gameplay_writes = 0,
        command_enum = enum_contract("snow.player.PlayerInput.CommandButton2"),
        types = {},
    }
    for _, spec in ipairs(SEMANTIC_INPUT_TYPES) do
        local type_def = safe(function() return sdk.find_type_definition(spec.name) end)
        local instance = nil
        if spec.singleton then
            instance = safe(function() return sdk.get_managed_singleton(spec.name) end)
        end
        local contract = filtered_type_contract(spec.name, instance, PLAYER_INPUT_TERMS)
        contract.singleton_lookup = spec.singleton
        contract.instance_available = instance ~= nil
        contract.semantic_query_methods = allowlisted_method_contracts(
            type_def, SEMANTIC_QUERY_METHODS)
        result.types[#result.types + 1] = contract
    end
    return result
end

local function exact_zero_arg_method(type_def, name)
    for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
        if safe(function() return method:get_name() end) == name then
            local params = safe(function() return method:get_param_types() end) or {}
            if #params == 0 then return method end
        end
    end
    return nil
end

local function exact_one_arg_method(type_def, name, param_type_name)
    for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
        if safe(function() return method:get_name() end) == name then
            local params = safe(function() return method:get_param_types() end) or {}
            if #params == 1 and type_name(params[1]) == param_type_name then return method end
        end
    end
    return nil
end

local function exact_method(type_def, name, expected_param_types)
    for _, method in ipairs(safe(function() return type_def:get_methods() end) or {}) do
        if safe(function() return method:get_name() end) == name then
            local params = safe(function() return method:get_param_types() end) or {}
            local matches = #params == #expected_param_types
            for index, expected in ipairs(expected_param_types) do
                if type_name(params[index]) ~= expected then matches = false break end
            end
            if matches then return method end
        end
    end
    return nil
end

local function exact_one_arg_method_in_hierarchy(type_def, name, param_type_name)
    local seen, depth = {}, 0
    while type_def ~= nil and depth < MAX_CONTRACT_LEVELS do
        local current_name = type_name(type_def) or tostring(type_def)
        if seen[current_name] then break end
        seen[current_name] = true
        local method = exact_one_arg_method(type_def, name, param_type_name)
        if method ~= nil then return method, current_name end
        type_def = safe(function() return type_def:get_parent_type() end)
        depth = depth + 1
    end
    return nil, nil
end

-- The previous metadata-only gate established these four exact no-argument
-- getters on snow.StmInputManager. This next layer invokes only those read
-- methods once per adapter, then inspects the returned bit-set object metadata.
-- No method on a returned object is called and no field is written.
local function semantic_bitset_read_contract()
    local manager_type = safe(function()
        return sdk.find_type_definition("snow.StmInputManager")
    end)
    local manager = safe(function()
        return sdk.get_managed_singleton("snow.StmInputManager")
    end)
    local result = {
        schema_version = 1,
        policy = "bounded_read_only_semantic_bitset_getters",
        max_calls = #SEMANTIC_BITSET_GETTERS,
        call_count = 0,
        call_failures = 0,
        gameplay_writes = 0,
        manager_type_available = manager_type ~= nil,
        manager_instance_available = manager ~= nil,
        getters = {},
    }
    for _, name in ipairs(SEMANTIC_BITSET_GETTERS) do
        local method = exact_zero_arg_method(manager_type, name)
        local entry = {
            name = name,
            method_available = method ~= nil,
            method = method and method_metadata(method) or nil,
            status = "method_unavailable",
        }
        if method ~= nil and manager ~= nil and result.call_count < result.max_calls then
            result.call_count = result.call_count + 1
            local ok, object = pcall(function() return method:call(manager) end)
            if not ok then
                result.call_failures = result.call_failures + 1
                entry.status = "call_failed"
            elseif object == nil then
                entry.status = "object_unavailable"
            else
                local object_type = safe(function() return object:get_type_definition() end)
                local object_type_name = type_name(object_type)
                entry.status = object_type_name and "resolved" or "object_type_unavailable"
                entry.object_available = true
                entry.object_type = object_type_name
                if object_type_name ~= nil then
                    entry.object_contract = filtered_type_contract(
                        object_type_name, object, SEMANTIC_BITSET_TERMS)
                    entry.object_hierarchy = filtered_type_hierarchy_contract(
                        object_type_name, object, SEMANTIC_BITSET_TERMS)
                end
            end
        elseif method ~= nil and manager == nil then
            entry.status = "manager_unavailable"
        elseif method ~= nil then
            entry.status = "call_limit"
            result.truncated = true
        end
        result.getters[#result.getters + 1] = entry
    end
    return result
end

-- The current master player is supplied by runtime composition.  This adapter
-- only inspects matching input/command/button fields on its concrete type
-- hierarchy; it does not discover players, invoke candidate methods, or retain
-- the managed object in diagnostics.
local function player_input_owner_contract(player)
    local result = {
        schema_version = 1,
        policy = "read_only_current_player_input_fields",
        gameplay_method_calls = 0,
        gameplay_writes = 0,
        player_available = player ~= nil,
    }
    if player == nil then return result end
    local player_type = safe(function() return player:get_type_definition() end)
    result.player_type = type_name(player_type)
    result.player_type_available = player_type ~= nil
    local resolved_instance = nil
    if result.player_type ~= nil then
        result.hierarchy = filtered_type_hierarchy_contract(
            result.player_type, player, PLAYER_INPUT_OWNER_TERMS,
            function(level_type, contract, value)
                if resolved_instance == nil and contract.object_available
                    and PLAYER_INPUT_OWNER_TYPES[contract.object_type] then
                    resolved_instance = value
                    result.resolved_owner = {
                        level_type = level_type,
                        field = contract.name,
                        declared_type = contract.type,
                        object_type = contract.object_type,
                    }
                end
            end)
    end
    return result, resolved_instance
end

-- The owner path is now proven, so this layer makes four exact Boolean read
-- queries on that one instance.  It does not call update/set/clear methods and
-- it never writes the returned values back into the game.
local function player_input_instance_read_contract(instance, instance_type_name)
    local result = {
        schema_version = 1,
        policy = "bounded_read_only_player_input_queries",
        max_calls = #PLAYER_INPUT_QUERY_COMMANDS,
        call_count = 0,
        call_failures = 0,
        gameplay_writes = 0,
        instance_available = instance ~= nil,
        instance_type = instance_type_name,
        queries = {},
    }
    if instance == nil or instance_type_name == nil then return result end
    result.hierarchy = filtered_type_hierarchy_contract(
        instance_type_name, instance, PLAYER_INPUT_INSTANCE_TERMS)
    local instance_type = safe(function() return instance:get_type_definition() end)
    local method = exact_one_arg_method(
        instance_type, "isDelay", "snow.player.PlayerInput.CommandButton2")
    local commands = enum_contract("snow.player.PlayerInput.CommandButton2")
    for _, name in ipairs(PLAYER_INPUT_QUERY_COMMANDS) do
        local value = enum_value_by_name(commands, name)
        local entry = {
            command = name,
            value = value,
            method_available = method ~= nil,
            status = method and "command_unavailable" or "method_unavailable",
        }
        if method ~= nil and value ~= nil and result.call_count < result.max_calls then
            result.call_count = result.call_count + 1
            local ok, query_value = pcall(function() return method:call(instance, value) end)
            if ok then
                entry.status = "resolved"
                entry.result = query_value == true
            else
                result.call_failures = result.call_failures + 1
                entry.status = "call_failed"
            end
        end
        result.queries[#result.queries + 1] = entry
    end
    return result
end

local function exact_field(type_def, name)
    for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
        if safe(function() return field:get_name() end) == name then return field end
    end
    return nil
end

local function object_key(object)
    if object == nil then return nil end
    return tostring(safe(function() return object:get_address() end) or object)
end

local stm_player_input_capture = {
    install_attempted = false,
    hook_installed = false,
    capture_count = 0,
    instance = nil,
    error = nil,
}

local STM_PLAYER_INPUT_UPDATE_PARAMS = {
    "System.Boolean[]", "via.hid.MouseButton",
    "System.Boolean[]", "via.hid.MouseButton",
    "System.Boolean[]", "via.hid.MouseButton",
    "System.Boolean[]", "via.hid.MouseButton",
}

local function install_stm_player_input_capture_hook()
    if stm_player_input_capture.install_attempted then return end
    stm_player_input_capture.install_attempted = true
    local type_def = safe(function() return sdk.find_type_definition("snow.StmPlayerInput") end)
    local update = type_def and exact_method(
        type_def, "update", STM_PLAYER_INPUT_UPDATE_PARAMS) or nil
    if update == nil or sdk == nil or type(sdk.hook) ~= "function" then
        stm_player_input_capture.error = "exact update hook unavailable"
        return
    end
    local ok = pcall(function()
        sdk.hook(update, function(args)
            local instance = safe(function() return sdk.to_managed_object(args[2]) end)
            local instance_type = instance and type_name(safe(function()
                return instance:get_type_definition()
            end)) or nil
            if instance ~= nil and instance_type == "snow.StmPlayerInput" then
                if object_key(stm_player_input_capture.instance) ~= object_key(instance) then
                    stm_player_input_capture.instance = instance
                    stm_player_input_capture.capture_count =
                        stm_player_input_capture.capture_count + 1
                end
            end
        end, function(retval) return retval end)
    end)
    stm_player_input_capture.hook_installed = ok
    if not ok then stm_player_input_capture.error = "sdk.hook failed" end
end

-- Both obvious GameObject locations were rejected in real runtime. Capture the
-- naturally executing StmPlayerInput.update `this` object without changing its
-- arguments or return value, then prove Refinput identity. This gate performs
-- one Boolean query and no set/clear call.
local function stm_player_input_capture_contract(player_input)
    local result = {
        schema_version = 1,
        policy = "bounded_read_only_stm_player_input_hook_capture",
        capture_method = "snow.StmPlayerInput.update(Boolean[],MouseButton,Boolean[],MouseButton,Boolean[],MouseButton,Boolean[],MouseButton)",
        max_calls = 1,
        call_count = 0,
        call_failures = 0,
        gameplay_writes = 0,
        install_attempted = stm_player_input_capture.install_attempted,
        hook_installed = stm_player_input_capture.hook_installed,
        capture_count = stm_player_input_capture.capture_count,
        capture_error = stm_player_input_capture.error,
        instance_available = false,
        refinput_available = false,
        refinput_matches_current = false,
        methods = {},
    }
    local instance = stm_player_input_capture.instance
    result.instance_available = instance ~= nil
    local instance_type = instance and safe(function()
        return instance:get_type_definition()
    end) or nil
    result.instance_type = type_name(instance_type)
    result.instance_key = object_key(instance)
    local refinput_field = instance_type and exact_field(instance_type, "Refinput") or nil
    local refinput = refinput_field and safe(function()
        return refinput_field:get_data(instance)
    end) or nil
    result.refinput_available = refinput ~= nil
    result.refinput_type = refinput and type_name(safe(function()
        return refinput:get_type_definition()
    end)) or nil
    result.refinput_key = object_key(refinput)
    result.current_player_input_key = object_key(player_input)
    result.refinput_matches_current = result.refinput_key ~= nil
        and result.refinput_key == result.current_player_input_key
    local command_type = "snow.player.PlayerInput.CommandButton2"
    local set_button = exact_one_arg_method(instance_type, "setButton", command_type)
    local clear_button = exact_one_arg_method(instance_type, "clearButton", command_type)
    local is_delay = exact_one_arg_method(instance_type, "isDelay", command_type)
    result.methods = {
        set_button = { available = set_button ~= nil, signature = "setButton(" .. command_type .. ")" },
        clear_button = { available = clear_button ~= nil, signature = "clearButton(" .. command_type .. ")" },
        is_delay = { available = is_delay ~= nil, signature = "isDelay(" .. command_type .. ")" },
    }
    local value = enum_value_by_name(enum_contract(command_type), "Escape")
    result.query = { command = "Escape", value = value, status = "unavailable" }
    if instance ~= nil and is_delay ~= nil and value ~= nil then
        result.call_count = 1
        local ok, active = pcall(function() return is_delay:call(instance, value) end)
        if ok and type(active) == "boolean" then
            result.query.status = "resolved"
            result.query.result = active
        else
            result.call_failures = 1
            result.query.status = "call_failed"
        end
    end
    return result, instance
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
    install_stm_player_input_capture_hook()
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
        semantic_input_snapshot = nil,
        semantic_bitset_snapshot = nil,
        player_input_owner_snapshot = nil,
        player_input_instance_snapshot = nil,
        player_input_player_key = nil,
        player_input_instance = nil,
        stm_player_input_capture_snapshot = nil,
        stm_player_input_instance = nil,
        stm_player_input_capture_count = -1,
        semantic_trigger = {
            status = "idle",
            command = nil,
            command_value = nil,
            hid_cycles = 0,
            write_count = 0,
            read_count = 0,
            error = nil,
        },
        emu_up = emu_up_field and safe(function() return emu_up_field:get_data(nil) end) or nil,
    }, { __index = M })
end

function M:arm_semantic_trigger(command)
    if command ~= "Escape" then return false, "Only Escape is allowlisted" end
    if self.semantic_trigger.status ~= "idle"
        and self.semantic_trigger.status ~= "released"
        and self.semantic_trigger.status ~= "failed" then
        return false, "A semantic trigger is already active"
    end
    local contract = self.player_input_instance_snapshot
    if contract == nil or contract.instance_available ~= true
        or tonumber(contract.call_failures or 0) ~= 0
        or tonumber(contract.call_count or 0) ~= tonumber(contract.max_calls or -1) then
        return false, "Player input read contract is not verified"
    end
    local value = enum_value_by_name(
        enum_contract("snow.player.PlayerInput.CommandButton2"), command)
    if value == nil then return false, "Semantic command is unavailable" end
    self.semantic_trigger = {
        schema_version = 1,
        policy = "single_frame_trigger_only",
        status = "pending",
        command = command,
        command_value = value,
        hid_cycles = 0,
        write_count = 0,
        read_count = 0,
        error = nil,
    }
    return true
end

function M:flush_semantic_trigger()
    local trigger = self.semantic_trigger
    if trigger.status ~= "pending" and trigger.status ~= "injected" then return true end
    trigger.hid_cycles = trigger.hid_cycles + 1
    local manager_type = safe(function() return sdk.find_type_definition("snow.StmInputManager") end)
    local manager = safe(function() return sdk.get_managed_singleton("snow.StmInputManager") end)
    if manager_type == nil or manager == nil then
        trigger.status = "failed"
        trigger.error = "StmInputManager unavailable"
        return false, trigger.error
    end
    if trigger.status == "pending" then
        local getter = exact_zero_arg_method(manager_type, "getTrg")
        local bitset = getter and safe(function() return getter:call(manager) end) or nil
        local bitset_type = bitset and safe(function() return bitset:get_type_definition() end) or nil
        local setter, declaring_type = exact_one_arg_method_in_hierarchy(
            bitset_type, "set", "System.UInt32")
        if setter == nil or bitset == nil then
            trigger.status = "failed"
            trigger.error = "Semantic trigger setter unavailable"
            return false, trigger.error
        end
        local ok = pcall(function() setter:call(bitset, trigger.command_value) end)
        if not ok then
            trigger.status = "failed"
            trigger.error = "Semantic trigger write failed"
            return false, trigger.error
        end
        trigger.status = "injected"
        trigger.setter_declaring_type = declaring_type
        trigger.write_count = trigger.write_count + 1
        return true
    end
    local query = exact_one_arg_method(
        manager_type, "isTrg", "snow.player.PlayerInput.CommandButton2")
    if query == nil then
        trigger.status = "failed"
        trigger.error = "Semantic trigger release query unavailable"
        return false, trigger.error
    end
    local ok, active = pcall(function() return query:call(manager, trigger.command_value) end)
    trigger.read_count = trigger.read_count + 1
    if not ok or type(active) ~= "boolean" then
        trigger.status = "failed"
        trigger.error = "Semantic trigger release query failed"
        return false, trigger.error
    end
    if active ~= true then
        trigger.status = "released"
        trigger.released_after_hid_cycles = trigger.hid_cycles
        return true
    end
    if trigger.hid_cycles >= 3 then
        trigger.status = "failed"
        trigger.error = "Semantic trigger did not release naturally"
        return false, trigger.error
    end
    return true
end

function M:cancel_semantic_trigger()
    local trigger = self.semantic_trigger
    if trigger.status == "pending" then
        trigger.status = "cancelled"
        trigger.error = "Cancelled before injection"
    end
    return trigger.status ~= "pending"
end

function M:semantic_trigger_diagnostics()
    return self.semantic_trigger
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

function M:diagnostics(player)
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
    if self.semantic_input_snapshot == nil then
        self.semantic_input_snapshot = semantic_input_metadata_contract()
    end
    if self.semantic_bitset_snapshot == nil then
        self.semantic_bitset_snapshot = semantic_bitset_read_contract()
    end
    local player_key = object_key(player)
    if player ~= nil and self.player_input_player_key ~= player_key then
        local owner_contract, owner_instance = player_input_owner_contract(player)
        self.player_input_player_key = player_key
        self.player_input_owner_snapshot = owner_contract
        self.player_input_instance = owner_instance
        self.player_input_instance_snapshot = player_input_instance_read_contract(
            owner_instance,
            owner_contract.resolved_owner and owner_contract.resolved_owner.object_type or nil)
    end
    local capture_count = stm_player_input_capture.capture_count
    if self.stm_player_input_capture_count ~= capture_count
        or self.stm_player_input_capture_snapshot == nil then
        self.stm_player_input_capture_count = capture_count
        self.stm_player_input_capture_snapshot, self.stm_player_input_instance =
            stm_player_input_capture_contract(self.player_input_instance)
    end
    local player_input_owner = self.player_input_owner_snapshot
        or player_input_owner_contract(nil)
    return {
        schema_version = 14,
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
        semantic_input_contract = self.semantic_input_snapshot,
        semantic_bitset_contract = self.semantic_bitset_snapshot,
        player_input_owner_contract = player_input_owner,
        player_input_instance_contract = self.player_input_instance_snapshot
            or player_input_instance_read_contract(nil, nil),
        stm_player_input_capture_contract = self.stm_player_input_capture_snapshot
            or stm_player_input_capture_contract(nil),
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
        semantic_trigger = self.semantic_trigger,
    }
end

return M
