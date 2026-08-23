local Observer = require("MHRiseMonsterCoach.player_action_observer")

local M = {}
local EVIDENCE_PATH = "MHRiseMonsterCoach/runtime_player_action_evidence.json"
local TAG_NAMES = { "Attack", "Escape", "Damage", "Jump", "WireJump", "Ride", "Guard" }

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function type_name(type_def)
    return type_def and safe(function() return type_def:get_full_name() end) or nil
end

local function find_member(root_type, accessor, name)
    local current = root_type
    local visited = {}
    for _ = 1, 12 do
        if current == nil then return nil end
        local name_key = type_name(current) or tostring(current)
        if visited[name_key] then return nil end
        visited[name_key] = true
        local member = safe(function() return current[accessor](current, name) end)
        if member ~= nil then return member end
        current = safe(function() return current:get_parent_type() end)
    end
    return nil
end

local function primitive(value)
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return value end
    if value == nil then return nil end
    local int64 = safe(function() return sdk.to_int64(value) end)
    if type(int64) == "number" then return int64 end
    local numeric = tonumber(tostring(value))
    return numeric or tostring(value)
end

local function enum_value(field)
    return field and safe(function() return field:get_data(nil) end) or nil
end

function M.new(game_name, tdb_version, event_limit)
    return setmetatable({
        game_name = game_name,
        tdb_version = tdb_version,
        event_limit = event_limit or 128,
        observer = Observer.new(event_limit),
        fingerprint = nil,
        bindings = nil,
        sample_index = 0,
        state = nil,
        status = "waiting for player action evidence",
    }, { __index = M })
end

function M.configure(self, player_type)
    local fingerprint = type_name(player_type)
    if fingerprint == self.fingerprint and self.bindings ~= nil then return true end

    local motion_getter = find_member(player_type, "get_method", "getMotionFsm2")
    local status_method = find_member(player_type, "get_method",
        "isActionStatusTag(snow.player.ActStatus)")
    local act_status_type = safe(function() return sdk.find_type_definition("snow.player.ActStatus") end)
    local tags = {}
    for _, name in ipairs(TAG_NAMES) do
        local field = act_status_type and safe(function() return act_status_type:get_field(name) end) or nil
        tags[name] = enum_value(field)
    end

    self.bindings = {
        player_type = fingerprint,
        motion_getter = motion_getter,
        status_method = status_method,
        tags = tags,
    }
    self.fingerprint = fingerprint
    return motion_getter ~= nil or status_method ~= nil
end

function M.capture(self, player)
    self.sample_index = self.sample_index + 1
    if player == nil then
        self.state = { availability = "unavailable", reason = "player unavailable" }
        self.status = self.state.reason
        return false
    end

    local player_type = safe(function() return player:get_type_definition() end)
    if player_type == nil then
        self.state = { availability = "unavailable", reason = "player type unavailable" }
        self.status = self.state.reason
        return false
    end
    self:configure(player_type)

    local motion_fsm = self.bindings.motion_getter
        and safe(function() return self.bindings.motion_getter:call(player) end) or nil
    local motion_type = motion_fsm and safe(function() return motion_fsm:get_type_definition() end) or nil
    local node_method = motion_type and safe(function()
        return motion_type:get_method("getCurrentNodeID(System.Int32)")
            or motion_type:get_method("getCurrentNodeID")
    end) or nil
    local node_id = node_method and primitive(safe(function() return node_method:call(motion_fsm, 0) end)) or nil

    local tags = {}
    local tag_count = 0
    if self.bindings.status_method ~= nil then
        for _, raw_name in ipairs(TAG_NAMES) do
            local value = self.bindings.tags[raw_name]
            if value ~= nil then
                local semantic = raw_name == "WireJump" and "wire_jump" or string.lower(raw_name)
                tags[semantic] = safe(function()
                    return self.bindings.status_method:call(player, value)
                end) == true
                tag_count = tag_count + 1
            end
        end
    end

    local state = {
        availability = node_id ~= nil and "available" or (tag_count > 0 and "partial" or "unavailable"),
        node_id = node_id,
        tags = tags,
        source = node_id ~= nil and "player_motion_fsm2_and_act_status"
            or (tag_count > 0 and "player_act_status" or nil),
        unavailable = {},
    }
    if node_id == nil then state.unavailable[#state.unavailable + 1] = "motion_fsm_node" end
    -- Motion bank/id are intentionally deferred: mature implementations obtain them
    -- from a PlayerMotionControl hook, while this reader remains polling-only.
    state.unavailable[#state.unavailable + 1] = "motion_bank_id"
    state.unavailable[#state.unavailable + 1] = "motion_id"
    if tag_count == 0 then state.unavailable[#state.unavailable + 1] = "action_status_tags" end

    self.state = state
    self.status = string.format("node=%s; tags=%d; source=%s",
        tostring(node_id or "unknown"), tag_count, tostring(state.source or "unavailable"))
    local changed = self.observer:sample(self.sample_index, state)
    if changed then safe(function() json.dump_file(EVIDENCE_PATH, self:evidence()) end) end
    return changed
end

function M.suspend(self, reason)
    self.state = nil
    self.status = reason or "player action evidence suspended"
end

function M.evidence(self)
    local result = self.observer:result()
    result.runtime = { game_name = self.game_name, tdb_version = self.tdb_version }
    result.reader = {
        player_type = self.bindings and self.bindings.player_type or nil,
        status = self.status,
        polling_only = true,
        hook_installed = false,
    }
    return result
end

function M.description(self)
    return {
        status = self.status,
        path = EVIDENCE_PATH,
        availability = self.state and self.state.availability or "unavailable",
        node_id = self.state and self.state.node_id or nil,
        source = self.state and self.state.source or nil,
        revision = self.observer.revision,
        event_count = #self.observer.events,
        dropped_events = self.observer.dropped_events,
    }
end

return M
