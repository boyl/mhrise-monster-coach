local M = {}

local BRANCH_KINDS = { fixed = true, conditional = true, random = true,
    observed = true, unresolved = true }
local TRAINING_CATEGORIES = { independent = true, fixed_branch = true,
    conditional_branch = true, random_branch = true, observed_branch = true }
local EXECUTION_MODES = { forced_single = true, natural_condition = true,
    native_branch = true, native_combo = true, single_move = true }

local function add(target, path, message)
    target[#target + 1] = { path = path, message = message }
end

local function action_key(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local text = tostring(value)
    return tonumber(text) ~= nil and text or nil
end

function M.validate(pack)
    local result = { ok = true, errors = {}, warnings = {} }
    if type(pack) ~= "table" then
        add(result.errors, "$", "monster pack must be a table")
        result.ok = false
        return result
    end
    if type(pack.monster) ~= "string" or pack.monster == "" then
        add(result.errors, "monster", "stable monster id is required")
    end
    if tonumber(pack.required_action_category) == nil then
        add(result.errors, "required_action_category", "numeric action category is required")
    end
    local moves = type(pack.moves) == "table" and pack.moves or {}
    local actions = type(pack.actions) == "table" and pack.actions or {}
    if type(pack.moves) ~= "table" then add(result.errors, "moves", "move catalog is required") end
    if type(pack.actions) ~= "table" then add(result.errors, "actions", "branch graph is required") end

    for key, row in pairs(actions) do
        local path = "actions." .. tostring(key)
        if action_key(key) == nil then add(result.errors, path, "action key must be numeric") end
        if type(row) ~= "table" then
            add(result.errors, path, "branch row must be a table")
        else
            local kind = tostring(row.kind or "")
            local next_rows = type(row.next) == "table" and row.next or {}
            if not BRANCH_KINDS[kind] then add(result.errors, path .. ".kind", "unknown branch kind") end
            if #next_rows == 0 then add(result.errors, path .. ".next", "at least one successor is required") end
            if kind == "fixed" and #next_rows ~= 1 then
                add(result.errors, path .. ".next", "fixed branch must have exactly one successor")
            end
            for index, edge in ipairs(next_rows) do
                local edge_path = path .. ".next[" .. tostring(index) .. "]"
                local target = type(edge) == "table" and action_key(edge.action) or nil
                if target == nil then
                    add(result.errors, edge_path, "successor action is required")
                elseif moves[target] == nil then
                    add(result.errors, edge_path .. ".action", "successor is missing from move catalog")
                end
                local condition = type(edge) == "table" and edge.condition or nil
                if kind == "conditional" and (type(condition) ~= "string" or condition == "") then
                    add(result.errors, edge_path .. ".condition", "conditional edge needs an explicit condition")
                end
            end
        end
    end

    local seen_scenarios = {}
    for index, scenario in ipairs(type(pack.training_scenarios) == "table"
        and pack.training_scenarios or {}) do
        local path = "training_scenarios[" .. tostring(index) .. "]"
        local row = type(scenario) == "table" and scenario or {}
        if type(scenario) ~= "table" then
            add(result.errors, path, "scenario must be a table")
        end
        local id = row.id
        if type(id) ~= "string" or id == "" then
            add(result.errors, path .. ".id", "scenario id is required")
        elseif seen_scenarios[id] then
            add(result.errors, path .. ".id", "scenario id must be unique")
        else
            seen_scenarios[id] = true
        end
        local category = row.training_category
        if not TRAINING_CATEGORIES[category] then
            add(result.errors, path .. ".training_category", "unknown training category")
        end
        local mode = row.execution_mode
        if not EXECUTION_MODES[mode] then
            add(result.errors, path .. ".execution_mode", "unknown execution mode")
        end
        local root = type(row.actions) == "table" and action_key(row.actions[1]) or nil
        if root == nil or moves[root] == nil then
            add(result.errors, path .. ".actions[1]", "root action must exist in move catalog")
        end
        if tonumber(row.max_verified_repeats) == nil
            or tonumber(row.max_verified_repeats) < 1 then
            add(result.errors, path .. ".max_verified_repeats", "positive verified repeat limit is required")
        end
        if type(row.verification) ~= "table" or row.verification.status ~= "verified" then
            add(result.errors, path .. ".verification", "only verified scenarios may be exposed")
        end
        if mode == "natural_condition" then
            local positioning = row.positioning
            if type(positioning) ~= "table" or tonumber(positioning.target) == nil
                or tonumber(positioning.tolerance) == nil then
                add(result.errors, path .. ".positioning", "natural condition needs target and tolerance")
            end
            local declared = {}
            local branch = actions[root]
            for _, edge in ipairs(type(branch) == "table" and branch.next or {}) do
                local target = type(edge) == "table" and action_key(edge.action) or nil
                if target ~= nil then declared[target] = true end
            end
            local expected = action_key(row.expected_successor)
            if expected and not declared[expected] then
                add(result.errors, path .. ".expected_successor", "successor is absent from branch graph")
            end
            for branch_index, edge in ipairs(type(row.expected_branches) == "table"
                and row.expected_branches or {}) do
                local target = type(edge) == "table" and action_key(edge.action) or nil
                if target == nil or not declared[target] then
                    add(result.errors, path .. ".expected_branches[" .. tostring(branch_index) .. "]",
                        "branch is absent from branch graph")
                end
            end
        end
    end

    for key in pairs(moves) do
        if action_key(key) == nil then add(result.errors, "moves." .. tostring(key), "move key must be numeric") end
    end
    result.ok = #result.errors == 0
    return result
end

return M
