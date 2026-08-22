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

local function array_items(array, limit)
    local elements = array and attempt(function() return array:get_elements() end)
    local result = {}
    if type(elements) ~= "table" then return result end
    for index, value in ipairs(elements) do
        if index > limit then break end
        if value ~= nil then result[#result + 1] = value end
    end
    return result
end

local function behavior_for(character)
    return character and (attempt(function()
        return character:get_field("<RefEnemyThinkBehavior>k__BackingField")
    end) or attempt(function() return character:call("get_RefEnemyThinkBehavior") end)) or nil
end

local function active_infos(behavior)
    local result, seen = {}, {}
    local function append(info)
        local key = address(info)
        if info ~= nil and not seen[key] then
            seen[key] = true
            result[#result + 1] = info
        end
    end
    append(behavior and attempt(function() return behavior:call("getCurrentStateInfo") end))
    local stack = behavior and attempt(function() return behavior:get_field("_PlayStateInfo") end)
    local array = stack and attempt(function() return stack:call("ToArray") end)
    for _, info in ipairs(array_items(array, 32)) do append(info) end
    return result
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

local function inherited_field(value, wanted)
    local definition = value and attempt(function() return value:get_type_definition() end)
    local seen, depth = {}, 0
    while definition and depth < 8 do
        local owner = attempt(function() return definition:get_full_name() end) or "unknown"
        if seen[owner] then return nil end
        seen[owner] = true
        local field = attempt(function() return definition:get_field(wanted) end)
        if field ~= nil then return attempt(function() return field:get_data(value) end) end
        definition = attempt(function() return definition:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function state_for_action(info, action_no)
    local matches = {}
    local states = collection_items(attempt(function() return info:call("get_StateList") end), 64)
    for _, state in ipairs(states) do
        local actions = collection_items(attempt(function() return state:call("get_ActionList") end), 64)
        for _, action in ipairs(actions) do
            if tonumber(inherited_field(action, "_ActionNo")) == tonumber(action_no) then
                matches[#matches + 1] = state
            end
        end
    end
    if #matches ~= 1 then return nil, "Expected one state for Action " .. tostring(action_no)
        .. ", found " .. tostring(#matches) end
    return matches[1]
end

local function resolve_combo_info(behavior, returned_info)
    local candidates, seen = {}, {}
    local function append(info)
        local key = address(info)
        if info ~= nil and not seen[key] then
            seen[key] = true
            candidates[#candidates + 1] = info
        end
    end
    append(returned_info)
    for _, info in ipairs(active_infos(behavior)) do append(info) end
    local matches = {}
    for _, info in ipairs(candidates) do
        local root = state_for_action(info, 5000)
        local successor = state_for_action(info, 5001)
        if root ~= nil and successor ~= nil then
            matches[#matches + 1] = { info = info, root = root, successor = successor }
        end
    end
    if #matches ~= 1 then return nil, "Expected one active combo ThinkInfoData, found "
        .. tostring(#matches) end
    return matches[1]
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
    local behavior = behavior_for(character)
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

function M.find_reference_state(character, path_suffix)
    local behavior = behavior_for(character)
    if behavior == nil then return nil, "EnemyThinkBehavior unavailable" end
    local matches = {}
    for _, info in ipairs(active_infos(behavior)) do
        local states = collection_items(attempt(function() return info:call("get_StateList") end), 64)
        for _, state in ipairs(states) do
            local reference = attempt(function() return state:call("get_ReferenceThinkData") end)
            local path = reference and attempt(function() return reference:call("get_Path") end) or nil
            if type(path) == "string" and string.sub(path, -#path_suffix) == path_suffix then
                matches[#matches + 1] = {
                    info = info,
                    state = state,
                    info_address = address(info),
                    state_id = tonumber(attempt(function() return state:call("get_ID") end)),
                    tree_node_id = tonumber(attempt(function() return state:call("get_TreeNodeID") end)),
                    reference_path = path,
                }
            end
        end
    end
    if #matches ~= 1 then
        return nil, "Expected one active reference state, found " .. tostring(#matches)
    end
    return matches[1]
end

local function find_loaded_reference(behavior, path_suffix)
    local matches, visited = {}, {}
    local function visit_states(states, depth)
        if depth > 16 then return end
        for _, state in ipairs(collection_items(states, 64)) do
            local reference = attempt(function() return state:call("get_ReferenceThinkData") end)
            if reference ~= nil then
                local key = address(reference)
                local path = attempt(function() return reference:call("get_Path") end)
                if type(path) == "string" and string.sub(path, -#path_suffix) == path_suffix then
                    matches[#matches + 1] = { data = reference, path = path, address = key }
                end
                if not visited[key] then
                    visited[key] = true
                    visit_states(attempt(function() return reference:call("get_StateList") end), depth + 1)
                end
            end
        end
    end
    visit_states(attempt(function() return behavior:get_field("_MainThinkStateList") end), 0)
    local unique, by_address = {}, {}
    for _, match in ipairs(matches) do
        if not by_address[match.address] then
            by_address[match.address] = true
            unique[#unique + 1] = match
        end
    end
    if #unique ~= 1 then
        return nil, "Expected one loaded reference data, found " .. tostring(#unique)
    end
    return unique[1]
end

function M.request_reference_state(character, path_suffix)
    local match, reason = M.find_reference_state(character, path_suffix)
    if match ~= nil then
        local ok = attempt(function()
            match.info:call("setState", match.state_id)
            return true
        end) == true
        if not ok then return false, "ThinkInfoData.setState failed", false end
        return true, {
            mode = "active_parent_set_state",
            info_address = match.info_address,
            state_id = match.state_id,
            tree_node_id = match.tree_node_id,
            reference_path = match.reference_path,
        }, false
    end
    local behavior = behavior_for(character)
    local loaded, loaded_reason = find_loaded_reference(behavior, path_suffix)
    if loaded == nil then return false, loaded_reason or reason, true end
    local info = attempt(function() return behavior:call("nextJumpThinkData", loaded.data) end)
    if info == nil then return false, "EnemyThinkBehavior.nextJumpThinkData failed", false end
    local resolved, resolve_reason = resolve_combo_info(behavior, info)
    if resolved == nil then return false, resolve_reason, false end
    info = resolved.info
    local root_state, successor_state = resolved.root, resolved.successor
    local root_id = tonumber(attempt(function() return root_state:call("get_ID") end))
    local successor_id = tonumber(attempt(function() return successor_state:call("get_ID") end))
    if root_id ~= 8 or successor_id ~= 6 then
        return false, "Think action contract IDs changed", false
    end
    local selected = attempt(function()
        info:call("setState", root_id)
        return true
    end) == true
    if not selected then return false, "ThinkInfoData.setState(8) failed", false end
    local started = attempt(function()
        behavior:call("startActionTable", info)
        return true
    end) == true
    if not started then return false, "EnemyThinkBehavior.startActionTable failed", false end
    return true, {
        mode = "next_jump_set_validated_state_and_start",
        info_address = address(info),
        root_state_id = root_id,
        successor_state_id = successor_id,
        reference_address = loaded.address,
        reference_path = loaded.path,
    }, false
end

return M
