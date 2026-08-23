local M = {}
M.__index = M

local EVENT_KINDS = {
    action_start = true,
    hitbox_open = true,
    hitbox_close = true,
    damage = true,
    result = true,
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function append_bounded(self, event)
    self.events[#self.events + 1] = event
    if #self.events > self.limit then
        table.remove(self.events, 1)
        self.dropped_events = self.dropped_events + 1
    end
end

function M.new(limit)
    limit = math.max(8, math.floor(tonumber(limit) or 128))
    return setmetatable({
        schema_version = 1,
        limit = limit,
        next_round_id = 1,
        active = false,
        round_id = nil,
        started_at = nil,
        events = {},
        dropped_events = 0,
        last_round = nil,
        last_reset_reason = nil,
    }, M)
end

function M:record(kind, at, payload)
    if not EVENT_KINDS[kind] then return false, "unsupported_event_kind" end
    if not self.active then return false, "timeline_inactive" end
    append_bounded(self, {
        sequence = self.dropped_events + #self.events + 1,
        kind = kind,
        at = tonumber(at),
        data = copy(payload or {}),
    })
    return true
end

function M:finish(at, outcome, payload)
    if not self.active then return false, "timeline_inactive" end
    local result_payload = copy(payload or {})
    result_payload.outcome = outcome or "unclassified"
    self:record("result", at, result_payload)
    self.last_round = {
        schema_version = self.schema_version,
        round_id = self.round_id,
        started_at = self.started_at,
        finished_at = tonumber(at),
        outcome = result_payload.outcome,
        dropped_events = self.dropped_events,
        events = copy(self.events),
    }
    self.active = false
    self.round_id = nil
    self.started_at = nil
    self.events = {}
    self.dropped_events = 0
    return true
end

function M:start(at, payload)
    if self.active then
        self:finish(at, "interrupted", { reason = "new_action_started" })
    end
    self.active = true
    self.round_id = self.next_round_id
    self.next_round_id = self.next_round_id + 1
    self.started_at = tonumber(at)
    self.events = {}
    self.dropped_events = 0
    self.last_reset_reason = nil
    return self:record("action_start", at, payload)
end

function M:has_event(kind)
    for _, event in ipairs(self.events) do
        if event.kind == kind then return true end
    end
    return false
end

function M:reset(reason, clear_last)
    self.active = false
    self.round_id = nil
    self.started_at = nil
    self.events = {}
    self.dropped_events = 0
    self.last_reset_reason = reason
    if clear_last == true then self.last_round = nil end
end

function M:snapshot()
    return copy({
        schema_version = self.schema_version,
        active = self.active,
        round_id = self.round_id,
        started_at = self.started_at,
        dropped_events = self.dropped_events,
        events = self.events,
        last_round = self.last_round,
        last_reset_reason = self.last_reset_reason,
    })
end

return M
