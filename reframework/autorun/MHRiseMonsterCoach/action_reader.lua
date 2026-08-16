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
local ACTION_PARAM_PROBE_PATH = "MHRiseMonsterCoach/runtime_action_param_probe.json"
local SAFE_ACTION_PARAM_METHOD_NAMES = {
    "get_ActionNo",
    "get_ActionID",
    "get_ActionId",
    "get_CurrentActionNo",
    "get_CurrentActionID",
    "get_CurrentActionId",
    "get_ActionCategory",
    "get_Category",
    "get_ActionCode",
}
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

local function semantic_priority(name)
    local lower = string.lower(name or "")
    if string.find(lower, "actionno", 1, true) then return 100 end
    if string.find(lower, "actionid", 1, true) then return 90 end
    if string.find(lower, "actioncategory", 1, true) then return 50 end
    if string.find(lower, "category", 1, true) then return 40 end
    if string.find(lower, "actioncode", 1, true) then return 10 end
    return 0
end

local function find_member_in_hierarchy(type_def, lookup, name)
    local current = type_def
    local visited = {}
    local depth = 0
    while current ~= nil and depth < 12 do
        local key = safe_call(function() return current:get_full_name() end) or tostring(current)
        if visited[key] then return nil end
        visited[key] = true
        local member = safe_call(function() return current[lookup](current, name) end)
        if member ~= nil then return member end
        current = safe_call(function() return current:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function find_method(type_def, name)
    return find_member_in_hierarchy(type_def, "get_method", name)
end

local function find_field(type_def, name)
    return find_member_in_hierarchy(type_def, "get_field", name)
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
    local method = find_method(type_def, name)
    if method == nil then return end
    local count = safe_call(function() return method:get_num_params() end)
    if count ~= 0 then return end
    self.candidates[#self.candidates + 1] = {
        kind = "method",
        name = name,
        priority = semantic_priority(name),
        member = method,
        metadata = {},
        values = {},
        changes = 0,
        last = nil,
    }
end

local function add_field_candidate(self, type_def, name)
    local field = find_field(type_def, name)
    if field == nil then return end
    self.candidates[#self.candidates + 1] = {
        kind = "field",
        name = name,
        priority = semantic_priority(name),
        member = field,
        metadata = {},
        values = {},
        changes = 0,
        last = nil,
    }
end

local function add_action_param_candidates(self, enemy_type)
    local probe = {
        schema_version = 1,
        enemy_type = safe_call(function() return enemy_type:get_full_name() end),
        accessor_found = false,
        action_param_type_found = false,
        fields = {},
        methods = {},
        selected = {},
    }
    self.action_param_probe = probe
    if sdk == nil or sdk.find_type_definition == nil then return end
    local accessor = find_method(enemy_type, "get_ActionParam")
    probe.accessor_found = accessor ~= nil
    if accessor == nil or safe_call(function() return accessor:get_num_params() end) ~= 0 then
        safe_call(function() json.dump_file(ACTION_PARAM_PROBE_PATH, probe) end)
        return
    end
    local param_type = safe_call(function() return sdk.find_type_definition(ACTION_PARAM_TYPE) end)
    probe.action_param_type_found = param_type ~= nil
    if param_type == nil then
        safe_call(function() json.dump_file(ACTION_PARAM_PROBE_PATH, probe) end)
        return
    end

    local visited = {}
    local field_names = {}
    local method_names = {}
    local discovered = {}
    local depth = 0
    while param_type ~= nil and depth < 8 do
        local type_name = safe_call(function() return param_type:get_full_name() end) or ""
        if visited[type_name] then break end
        visited[type_name] = true
        local fields = safe_call(function() return param_type:get_fields() end) or {}
        for _, field in ipairs(fields) do
            local name = safe_call(function() return field:get_name() end)
            if name ~= nil and not field_names[name] then probe.fields[#probe.fields + 1] = name end
            if name ~= nil and SAFE_ACTION_PARAM_FIELDS[name] == true and not field_names[name] then
                field_names[name] = true
                discovered[#discovered + 1] = {
                    kind = "action_param_field",
                    name = "get_ActionParam()." .. name,
                    field_name = name,
                    priority = semantic_priority(name),
                    accessor = accessor,
                    member = field,
                    metadata = {},
                    values = {},
                    changes = 0,
                    last = nil,
                }
            end
        end
        local methods = safe_call(function() return param_type:get_methods() end) or {}
        for _, method in ipairs(methods) do
            local name = safe_call(function() return method:get_name() end)
            local params = safe_call(function() return method:get_num_params() end)
            if name ~= nil and not method_names[name] then
                probe.methods[#probe.methods + 1] = { name = name, params = params }
                method_names[name] = true
            end
        end
        for _, name in ipairs(SAFE_ACTION_PARAM_METHOD_NAMES) do
            if not method_names["selected:" .. name] then
                local method = safe_call(function() return param_type:get_method(name) end)
                local params = method and safe_call(function() return method:get_num_params() end) or nil
                if method ~= nil and params == 0 then
                    method_names["selected:" .. name] = true
                    discovered[#discovered + 1] = {
                        kind = "action_param_method",
                        name = "get_ActionParam()." .. name .. "()",
                        field_name = name,
                        priority = semantic_priority(name),
                        accessor = accessor,
                        member = method,
                        metadata = {},
                        values = {},
                        changes = 0,
                        last = nil,
                    }
                end
            end
        end
        param_type = safe_call(function() return param_type:get_parent_type() end)
        depth = depth + 1
    end
    table.sort(discovered, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.field_name < b.field_name
    end)
    local category_candidate = nil
    for _, candidate in ipairs(discovered) do
        if candidate.priority == 50 or candidate.priority == 40 then
            category_candidate = candidate
            break
        end
    end
    for _, candidate in ipairs(discovered) do
        if candidate.priority == 100 and category_candidate ~= nil then
            candidate.category_kind = category_candidate.kind
            candidate.category_member = category_candidate.member
        end
        self.candidates[#self.candidates + 1] = candidate
        probe.selected[#probe.selected + 1] = candidate.name
    end
    safe_call(function() json.dump_file(ACTION_PARAM_PROBE_PATH, probe) end)
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
        priority = -1,
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
    if candidate.kind == "action_param_field" or candidate.kind == "action_param_method" then
        if shared.action_param_unread then
            shared.action_param = safe_call(function() return candidate.accessor:call(enemy) end)
            shared.action_param_unread = false
        end
        if shared.action_param == nil then return nil end
        local raw_value = nil
        if candidate.kind == "action_param_method" then
            raw_value = safe_call(function() return candidate.member:call(shared.action_param) end)
        else
            raw_value = safe_call(function() return candidate.member:get_data(shared.action_param) end)
        end
        if candidate.category_member == nil then return raw_value end
        local category = nil
        if candidate.category_kind == "action_param_method" then
            category = safe_call(function() return candidate.category_member:call(shared.action_param) end)
        else
            category = safe_call(function() return candidate.category_member:get_data(shared.action_param) end)
        end
        return raw_value, {
            action_no = tonumber(raw_value),
            action_category = tonumber(category),
            source = "EnemyActionParam",
        }
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
            if metadata ~= nil then
                candidate.metadata = candidate.metadata or {}
                candidate.metadata[value] = metadata
            end
        end
    end

    if self.active == nil then
        for _, candidate in ipairs(self.candidates) do
            if candidate.last ~= nil then self.active = candidate break end
        end
    end
    if self.samples >= 30 then
        for _, candidate in ipairs(self.candidates) do
            local priority = candidate.priority or 0
            local active_priority = self.active and (self.active.priority or 0) or -1
            if candidate.changes > 0 and (self.active == nil
                or priority > active_priority
                or (priority == active_priority and candidate.changes > self.active.changes)) then
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
        action_no = metadata and metadata.action_no or nil,
        action_category = metadata and metadata.action_category or nil,
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
