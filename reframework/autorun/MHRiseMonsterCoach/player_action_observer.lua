local M = {}

local function copy_tags(tags)
    local result = {}
    for name, value in pairs(tags or {}) do
        if type(value) == "boolean" then result[name] = value end
    end
    return result
end

local function copy_snapshot(snapshot)
    if type(snapshot) ~= "table" then return nil end
    local unavailable = {}
    for index, value in ipairs(snapshot.unavailable or {}) do unavailable[index] = value end
    return {
        availability = snapshot.availability,
        node_id = snapshot.node_id,
        tags = copy_tags(snapshot.tags),
        source = snapshot.source,
        reason = snapshot.reason,
        unavailable = unavailable,
    }
end

local function snapshot_key(snapshot)
    if type(snapshot) ~= "table" or snapshot.availability == "unavailable" then return nil end
    local tags = {}
    for name, value in pairs(snapshot.tags or {}) do
        if type(value) == "boolean" then
            tags[#tags + 1] = tostring(name) .. "=" .. tostring(value)
        end
    end
    table.sort(tags)
    return table.concat({
        tostring(snapshot.availability or "unknown"),
        tostring(snapshot.node_id or "unknown"),
        table.concat(tags, ","),
    }, "|")
end

function M.new(limit)
    return setmetatable({
        schema_version = 1,
        limit = math.max(1, math.floor(tonumber(limit) or 128)),
        revision = 0,
        dropped_events = 0,
        events = {},
        current = nil,
        last_key = nil,
    }, { __index = M })
end

function M.sample(self, sample_index, snapshot)
    local key = snapshot_key(snapshot)
    self.current = copy_snapshot(snapshot)
    if key == nil or key == self.last_key then return false end

    local event = copy_snapshot(snapshot)
    event.sample = tonumber(sample_index) or 0
    self.events[#self.events + 1] = event
    if #self.events > self.limit then
        table.remove(self.events, 1)
        self.dropped_events = self.dropped_events + 1
    end
    self.last_key = key
    self.revision = self.revision + 1
    return true
end

function M.result(self)
    local events = {}
    for index, event in ipairs(self.events) do events[index] = copy_snapshot(event) end
    for index, event in ipairs(self.events) do events[index].sample = event.sample end
    return {
        schema_version = self.schema_version,
        policy = "read_only_bounded_player_action_evidence",
        revision = self.revision,
        dropped_events = self.dropped_events,
        current = copy_snapshot(self.current),
        events = events,
    }
end

return M
