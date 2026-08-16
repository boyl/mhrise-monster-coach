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

    self.candidates[#self.candidates + 1] = {
        kind = "motion",
        name = "via.motion.Motion layer 0",
        member = layer,
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
        if #self.candidates == 0 then add_motion_candidate(self, enemy) end
    end

    return #self.candidates > 0
end

local function read_candidate(candidate, enemy)
    if candidate.kind == "motion" then
        local bank = safe_call(function() return candidate.member:call("get_MotionBankID") end)
        local motion = safe_call(function() return candidate.member:call("get_MotionID") end)
        if bank == nil or motion == nil then return nil end
        return tostring(bank) .. ":" .. tostring(motion)
    end
    if candidate.kind == "method" then
        return safe_call(function() return candidate.member:call(enemy) end)
    end
    return safe_call(function() return candidate.member:get_data(enemy) end)
end

function M.read(self, enemy)
    if not M.discover(self, enemy) then return nil end
    self.samples = self.samples + 1

    for _, candidate in ipairs(self.candidates) do
        local value = value_key(read_candidate(candidate, enemy))
        if value ~= nil then
            candidate.values[value] = true
            if candidate.last ~= nil and candidate.last ~= value then candidate.changes = candidate.changes + 1 end
            candidate.last = value
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

    return self.active and self.active.last or nil
end

function M.ready(self)
    return self.active ~= nil and self.active.last ~= nil
end

function M.description(self)
    if self.active == nil then return nil end
    return { kind = self.active.kind, name = self.active.name, changes = self.active.changes }
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
