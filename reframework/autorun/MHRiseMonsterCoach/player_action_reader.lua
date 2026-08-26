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

local function object_key(value)
    if value == nil then return nil end
    return tostring(safe(function() return value:get_address() end) or value)
end

function M.new(game_name, tdb_version, event_limit, dump_interval)
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
        node_catalog_key = nil,
        node_tree = nil,
        node_catalog = {},
        node_catalog_count = 0,
        dump_interval = math.max(1, math.floor(tonumber(dump_interval) or 60)),
        last_dump_sample = nil,
        evidence_dirty = false,
    }, { __index = M })
end

function M.refresh_node_catalog(self, motion_fsm)
    local catalog_key = object_key(motion_fsm)
    if catalog_key == self.node_catalog_key then return false end
    self.node_catalog_key = catalog_key
    self.node_tree = nil
    self.node_catalog = {}
    self.node_catalog_count = 0
    if motion_fsm == nil then return true end

    local layer = safe(function() return motion_fsm:call("getLayer", 0) end)
    local tree = layer and safe(function() return layer:get_tree_object() end) or nil
    self.node_tree = tree
    local count = tonumber(tree and safe(function() return tree:get_node_count() end) or nil)
    if count == nil or count < 0 or count > 4096 then return true end
    for index = 0, count - 1 do
        local node = safe(function() return tree:get_node(index) end)
        local id = node and primitive(safe(function() return node:get_id() end)) or nil
        local name = node and safe(function() return node:get_full_name() end) or nil
        if id ~= nil and type(name) == "string" and name ~= "" then
            self.node_catalog[tostring(id)] = name
        end
    end
    for _ in pairs(self.node_catalog) do self.node_catalog_count = self.node_catalog_count + 1 end
    return true
end

function M.resolve_node_name(self, node_id)
    if node_id == nil then return nil, false end
    local key = tostring(node_id)
    local cached = self.node_catalog[key]
    if cached ~= nil then return cached, false end
    local node = self.node_tree and safe(function()
        return self.node_tree:get_node_by_id(node_id)
    end) or nil
    local name = node and safe(function() return node:get_full_name() end) or nil
    if type(name) ~= "string" or name == "" then return nil, false end
    self.node_catalog[key] = name
    self.node_catalog_count = self.node_catalog_count + 1
    return name, true
end

function M.catalog(self)
    local result = {}
    for id, name in pairs(self.node_catalog) do
        result[#result + 1] = { id = id, name = name }
    end
    table.sort(result, function(a, b)
        local left, right = tonumber(a.id), tonumber(b.id)
        if left ~= nil and right ~= nil then return left < right end
        return tostring(a.id) < tostring(b.id)
    end)
    return result
end

function M.flush_evidence(self, force)
    if not self.evidence_dirty then return false end
    local due = self.last_dump_sample == nil
        or self.sample_index - self.last_dump_sample >= self.dump_interval
    if force ~= true and not due then return false end
    local written = safe(function() json.dump_file(EVIDENCE_PATH, self:evidence()) return true end) == true
    if written then
        self.last_dump_sample = self.sample_index
        self.evidence_dirty = false
    end
    return written
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
    local catalog_reset = self:refresh_node_catalog(motion_fsm)
    local node_name, resolved_new = self:resolve_node_name(node_id)

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
        player_type = self.bindings.player_type,
        node_id = node_id,
        node_name = node_name,
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
    self.evidence_dirty = self.evidence_dirty or changed or catalog_reset or resolved_new
    -- A new FSM instance is rare and should be persisted immediately. Individual
    -- newly seen nodes remain under the normal interval to avoid combo-time I/O.
    self:flush_evidence(catalog_reset)
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
        node_catalog_count = self.node_catalog_count,
    }
    result.node_catalog = self:catalog()
    return result
end

function M.description(self)
    return {
        status = self.status,
        path = EVIDENCE_PATH,
        availability = self.state and self.state.availability or "unavailable",
        node_id = self.state and self.state.node_id or nil,
        node_name = self.state and self.state.node_name or nil,
        source = self.state and self.state.source or nil,
        revision = self.observer.revision,
        event_count = #self.observer.events,
        dropped_events = self.observer.dropped_events,
    }
end

return M
