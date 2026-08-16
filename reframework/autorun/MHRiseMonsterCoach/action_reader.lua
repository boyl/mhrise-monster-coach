local M = {}

local SAFE_METHOD_NAMES = {
    "get_ActionNo",
    "get_ActionID",
    "get_ActionId",
    "get_CurrentActionNo",
    "get_CurrentActionID",
    "get_CurrentActionId",
    "get_ThinkActionNo",
    "get_OldActionNo",
    "get_MotionNo",
    "get_CurrentMotionNo",
}

local SAFE_FIELD_NAMES = {
    "_ActionNo",
    "_ActionID",
    "_CurrentActionNo",
    "<ActionNo>k__BackingField",
    "<ActionID>k__BackingField",
    "_MotionNo",
}

local ACTION_PARAM_TYPE = "snow.enemy.EnemyActionParam"
local SAFE_ACTION_PARAM_FIELDS = {
    ["_ActionNo"] = true,
    ["ActionNo"] = true,
    ["<ActionNo>k__BackingField"] = true,
    ["_CurrentActionNo"] = true,
    ["CurrentActionNo"] = true,
    ["<CurrentActionNo>k__BackingField"] = true,
    ["_ActionID"] = true,
    ["ActionID"] = true,
    ["<ActionID>k__BackingField"] = true,
    ["_ActionCategory"] = true,
    ["ActionCategory"] = true,
    ["<ActionCategory>k__BackingField"] = true,
    ["_Category"] = true,
}

local function safe_call(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function primitive(value)
    local kind = type(value)
    return kind == "number" or kind == "string" or kind == "boolean"
end

local function value_key(value)
    if not primitive(value) then return nil end
    return tostring(value)
end

function M.new(config)
    return setmetatable({
        config = config,
        target_type = nil,
        candidates = {},
        active = nil,
        samples = 0,
    }, { __index = M })
end

local function release_candidates(candidates)
    for _, candidate in ipairs(candidates or {}) do
        if candidate.motion_info ~= nil then
            safe_call(function() candidate.motion_info:release() end)
            candidate.motion_info = nil
        end
    end
end

local function add_method_candidate(self, type_def, name)
    local method = safe_call(function() return type_def:get_method(name) end)
    if method == nil then return end
    local count = safe_call(function() return method:get_num_params() end)
    if count ~= 0 then return end
    self.candidates[#self.candidates + 1] = {
        kind = "method",
        name = name,
        member = method,
        values = {},
        changes = 0,
        last = nil,
    }
end

local function add_field_candidate(self, type_def, name)
    local field = safe_call(function() return type_def:get_field(name) end)
    if field == nil then return end
    self.candidates[#self.candidates + 1] = {
        kind = "field",
        name = name,
        member = field,
        values = {},
        changes = 0,
        last = nil,
    }
end

local function add_action_param_candidates(self, enemy_type)
    if sdk == nil or sdk.find_type_definition == nil then return end
    local accessor = safe_call(function() return enemy_type:get_method("get_ActionParam") end)
    if accessor == nil or safe_call(function() return accessor:get_num_params() end) ~= 0 then return end
    local param_type = safe_call(function() return sdk.find_type_definition(ACTION_PARAM_TYPE) end)
    if param_type == nil then return end

    local visited = {}
    local field_names = {}
    local discovered = {}
    local depth = 0
    while param_type ~= nil and depth < 8 do
        local type_name = safe_call(function() return param_type:get_full_name() end) or ""
        if visited[type_name] then break end
        visited[type_name] = true
        local fields = safe_call(function() return param_type:get_fields() end) or {}
        for _, field in ipairs(fields) do
            local name = safe_call(function() return field:get_name() end)
            if name ~= nil and SAFE_ACTION_PARAM_FIELDS[name] == true and not field_names[name] then
                field_names[name] = true
                discovered[#discovered + 1] = {
                    kind = "action_param_field",
                    name = "get_ActionParam()." .. name,
                    field_name = name,
                    accessor = accessor,
                    member = field,
                    values = {},
                    changes = 0,
                    last = nil,
                }
            end
        end
        param_type = safe_call(function() return param_type:get_parent_type() end)
        depth = depth + 1
    end
    table.sort(discovered, function(a, b)
        local a_category = string.find(string.lower(a.field_name), "category", 1, true) ~= nil
        local b_category = string.find(string.lower(b.field_name), "category", 1, true) ~= nil
        if a_category ~= b_category then return not a_category end
        return a.field_name < b.field_name
    end)
    for _, candidate in ipairs(discovered) do self.candidates[#self.candidates + 1] = candidate end
end

local function add_motion_candidate(self, enemy)
    local motion_type = safe_call(function() return sdk.typeof("via.motion.Motion") end)
    if motion_type == nil then return end
    local game_object = safe_call(function() return enemy:call("get_GameObject") end)
    if game_object == nil then return end
    local motion = safe_call(function()
        return game_object:call("getComponent(System.Type)", motion_type)
    end)
    if motion == nil then return end
    local layer = safe_call(function() return motion:call("getLayer(System.UInt32)", 0) end)
    if layer == nil then layer = safe_call(function() return motion:call("getLayer", 0) end) end
    if layer == nil then return end

    local motion_info = safe_call(function()
        local value = sdk.create_instance("via.motion.MotionInfo")
        if value ~= nil then value:add_ref() end
        return value
    end)

    self.candidates[#self.candidates + 1] = {
        kind = "motion",
        name = "via.motion.Motion layer 0",
        member = layer,
        motion = motion,
        motion_info = motion_info,
        metadata = {},
        values = {},
        changes = 0,
        last = nil,
    }
end

function M.discover(self, enemy)
    if enemy == nil then return false end
    local type_def = enemy:get_type_definition()
    local type_name = type_def:get_full_name()
    if self.target_type == type_name then return #self.candidates > 0 end

    release_candidates(self.candidates)
    self.target_type = type_name
    self.candidates = {}
    self.active = nil
    self.samples = 0

    local requested = self.config.action_reader
    if requested.kind == "method" and requested.name ~= "" then
        add_method_candidate(self, type_def, requested.name)
    elseif requested.kind == "field" and requested.name ~= "" then
        add_field_candidate(self, type_def, requested.name)
    else
        for _, name in ipairs(SAFE_METHOD_NAMES) do add_method_candidate(self, type_def, name) end
        for _, name in ipairs(SAFE_FIELD_NAMES) do add_field_candidate(self, type_def, name) end
        if #self.candidates == 0 then add_action_param_candidates(self, type_def) end
        if #self.candidates == 0 then add_motion_candidate(self, enemy) end
    end

    return #self.candidates > 0
end

local function read_candidate(candidate, enemy, shared)
    if candidate.kind == "motion" then
        local bank = safe_call(function() return candidate.member:call("get_MotionBankID") end)
        local motion = safe_call(function() return candidate.member:call("get_MotionID") end)
        if bank == nil or motion == nil then return nil end
        local key = tostring(bank) .. ":" .. tostring(motion)
        local cached = candidate.metadata[key]
        if cached ~= nil and cached.motion_name ~= nil then return key, cached end
        local metadata = {
            bank_id = tonumber(bank),
            motion_id = tonumber(motion),
        }
        if candidate.motion_info ~= nil then
            local resolved, found = pcall(function()
                return candidate.motion:call(
                    "getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)",
                    bank,
                    motion,
                    candidate.motion_info
                )
            end)
            if resolved and found ~= false then
                local name = safe_call(function() return candidate.motion_info:call("get_MotionName") end)
                local end_frame = safe_call(function() return candidate.motion_info:call("get_MotionEndFrame") end)
                if type(name) == "string" and name ~= "" then metadata.motion_name = name end
                if type(end_frame) == "number" then metadata.end_frame = end_frame end
            end
        end
        return key, metadata
    end
    if candidate.kind == "method" then
        return safe_call(function() return candidate.member:call(enemy) end)
    end
    if candidate.kind == "action_param_field" then
        if shared.action_param_unread then
            shared.action_param = safe_call(function() return candidate.accessor:call(enemy) end)
            shared.action_param_unread = false
        end
        if shared.action_param == nil then return nil end
        return safe_call(function() return candidate.member:get_data(shared.action_param) end)
    end
    return safe_call(function() return candidate.member:get_data(enemy) end)
end

function M.read(self, enemy)
    if not M.discover(self, enemy) then return nil end
    self.samples = self.samples + 1
    local shared = { action_param_unread = true, action_param = nil }

    for _, candidate in ipairs(self.candidates) do
        local raw_value, metadata = read_candidate(candidate, enemy, shared)
        local value = value_key(raw_value)
        if value ~= nil then
            candidate.values[value] = true
            if candidate.last ~= nil and candidate.last ~= value then candidate.changes = candidate.changes + 1 end
            candidate.last = value
            if metadata ~= nil then candidate.metadata[value] = metadata end
        end
    end

    if self.active == nil then
        for _, candidate in ipairs(self.candidates) do
            if candidate.last ~= nil then self.active = candidate break end
        end
    end
    if self.samples >= 30 then
        for _, candidate in ipairs(self.candidates) do
            if candidate.changes > 0 and (self.active == nil or candidate.changes > self.active.changes) then
                self.active = candidate
            end
        end
    end

    if self.active == nil then return nil end
    return self.active.last, self.active.metadata and self.active.metadata[self.active.last] or nil
end

function M.ready(self)
    return self.active ~= nil and self.active.last ~= nil
end

function M.description(self)
    if self.active == nil then return nil end
    local metadata = self.active.metadata and self.active.metadata[self.active.last] or nil
    return {
        kind = self.active.kind,
        name = self.active.name,
        changes = self.active.changes,
        motion_name = metadata and metadata.motion_name or nil,
    }
end

function M.shutdown(self)
    release_candidates(self.candidates)
    self.candidates = {}
    self.active = nil
end

function M.diagnostics(self)
    local items = {}
    for _, candidate in ipairs(self.candidates) do
        local distinct = 0
        for _ in pairs(candidate.values) do distinct = distinct + 1 end
        items[#items + 1] = {
            kind = candidate.kind,
            name = candidate.name,
            changes = candidate.changes,
            distinct = distinct,
            last = candidate.last,
        }
    end
    return items
end

return M
