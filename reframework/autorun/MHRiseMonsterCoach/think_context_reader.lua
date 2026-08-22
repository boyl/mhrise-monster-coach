local M = {}

local function attempt(fn)
    local ok, value = pcall(fn)
    return ok and value or nil
end

local function address(value)
    return value and tostring(attempt(function() return value:get_address() end)) or nil
end

local function type_name(value)
    return value and attempt(function()
        local definition = value:get_type_definition()
        return definition and definition:get_full_name() or nil
    end) or nil
end

local function collection_items(collection, limit)
    local result = {}
    local count = tonumber(collection and attempt(function() return collection:call("get_Count") end))
    if count == nil or count < 0 or count > limit then return result, count, "invalid_count" end
    for index = 0, count - 1 do
        result[#result + 1] = attempt(function() return collection:call("get_Item", index) end)
    end
    return result, count, nil
end

local function member_snapshot(value)
    local result = { type = type_name(value), fields = {} }
    local definition = value and attempt(function() return value:get_type_definition() end)
    local seen, depth = {}, 0
    while definition and depth < 6 do
        local owner = attempt(function() return definition:get_full_name() end) or "unknown"
        if seen[owner] then break end
        seen[owner] = true
        for _, field in ipairs(attempt(function() return definition:get_fields() end) or {}) do
            local name = attempt(function() return field:get_name() end)
            local field_value = attempt(function() return field:get_data(value) end)
            if type(field_value) == "number" or type(field_value) == "boolean"
                or type(field_value) == "string" then
                result.fields[owner .. "." .. tostring(name)] = field_value
            end
        end
        definition = attempt(function() return definition:get_parent_type() end)
        depth = depth + 1
    end
    return result
end

local function state_snapshot(state, include_members)
    if state == nil then return nil end
    local row = {
        address = address(state),
        id = tonumber(attempt(function() return state:call("get_ID") end)),
        tree_node_id = tonumber(attempt(function() return state:call("get_TreeNodeID") end)),
        has_reference = attempt(function() return state:call("get_HasReferenceThinkData") end) == true,
    }
    if not include_members then return row end
    local actions, action_count, action_error = collection_items(
        attempt(function() return state:call("get_ActionList") end), 64)
    local conditions, condition_count, condition_error = collection_items(
        attempt(function() return state:call("get_ConditionList") end), 64)
    row.action_count, row.condition_count = action_count, condition_count
    row.action_error, row.condition_error = action_error, condition_error
    row.action_types, row.condition_types = {}, {}
    row.action_details, row.condition_details = {}, {}
    for _, action in ipairs(actions) do
        row.action_types[#row.action_types + 1] = type_name(action)
        row.action_details[#row.action_details + 1] = member_snapshot(action)
    end
    for _, condition in ipairs(conditions) do
        row.condition_types[#row.condition_types + 1] = type_name(condition)
        row.condition_details[#row.condition_details + 1] = member_snapshot(condition)
    end
    local reference = attempt(function() return state:call("get_ReferenceThinkData") end)
    row.reference_address = address(reference)
    row.reference_path = reference and attempt(function() return reference:call("get_Path") end) or nil
    return row
end

function M.read(character, include_catalog)
    local result = { available = false, policy = "read_only_enemy_think_context" }
    if character == nil then return result end
    local behavior = attempt(function() return character:get_field("<RefEnemyThinkBehavior>k__BackingField") end)
        or attempt(function() return character:call("get_RefEnemyThinkBehavior") end)
    if behavior == nil then
        result.reason = "EnemyThinkBehavior unavailable"
        return result
    end
    local info = attempt(function() return behavior:call("getCurrentStateInfo") end)
    if info == nil then
        result.reason = "Current ThinkInfoData unavailable"
        return result
    end
    result.available = true
    result.behavior_address = address(behavior)
    result.info_address = address(info)
    result.current_state_no = tonumber(attempt(function() return info:call("get_CurrentStateNo") end))
    result.is_call_start = attempt(function() return info:call("get_IsCallStart") end) == true
    result.current_state = state_snapshot(attempt(function() return info:call("get_CurrentState") end), false)
    if include_catalog then
        local states, count, err = collection_items(attempt(function() return info:call("get_StateList") end), 64)
        result.state_count, result.state_error, result.states = count, err, {}
        for _, state in ipairs(states) do result.states[#result.states + 1] = state_snapshot(state, true) end
    end
    return result
end

return M
