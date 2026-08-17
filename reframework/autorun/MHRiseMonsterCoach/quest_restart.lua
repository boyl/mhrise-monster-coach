local M = {}

M.states = {
    IDLE = "idle",
    WAIT_HUB = "wait_hub",
    OPEN_COUNTER = "open_counter",
    START_SESSION = "start_session",
    SELECT_QUEST = "select_quest",
    WAIT_POSTED = "wait_posted",
    WAIT_COUNTER_CLOSE = "wait_counter_close",
    DEPART = "depart",
    WAIT_QUEST = "wait_quest",
    COMPLETE = "complete",
    FAILED = "failed",
}

local LABELS = {
    wait_hub = "Returning to hub",
    open_counter = "Opening quest counter",
    start_session = "Starting quest session",
    select_quest = "Selecting training quest",
    wait_posted = "Posting training quest",
    wait_counter_close = "Closing quest counter",
    depart = "Departing automatically",
    wait_quest = "Loading training quest",
    complete = "Training quest restarted",
    failed = "Automatic restart failed",
}

function M.new(api, quest_id, options)
    options = options or {}
    return setmetatable({
        api = api,
        quest_id = quest_id,
        state = M.states.IDLE,
        status = "Waiting for training quest",
        state_frames = 0,
        hub_stable_frames = 0,
        timeout_frames = options.timeout_frames or 3600,
        hub_stable_required = options.hub_stable_frames or 30,
        error = nil,
    }, { __index = M })
end

function M:is_active()
    return self.state ~= M.states.IDLE
        and self.state ~= M.states.COMPLETE
        and self.state ~= M.states.FAILED
end

function M:set_state(state)
    self.state = state
    self.status = LABELS[state] or state
    self.state_frames = 0
end

function M:fail(reason)
    self.error = tostring(reason or "unknown error")
    self.api:cancel_posting()
    self:set_state(M.states.FAILED)
    self.status = "Automatic restart failed: " .. self.error
    return false
end

function M:start(context)
    if self:is_active() then return false, "Automatic restart already in progress" end
    if not context.in_quest or context.is_online or context.build_supported == false
        or tonumber(context.quest_no) ~= tonumber(self.quest_id) then
        return false, "Enter the supported single-player training quest"
    end
    local ok, reason = self.api:request_reset()
    if not ok then return false, reason end
    self.error = nil
    self.hub_stable_frames = 0
    self:set_state(M.states.WAIT_HUB)
    return true
end

local function advance(self, next_state, fn)
    local ok, reason = fn(self.api, self.quest_id)
    if not ok then return self:fail(reason) end
    self:set_state(next_state)
    return true
end

function M:update(context)
    if not self:is_active() then return false end
    self.state_frames = self.state_frames + 1
    if self.state_frames > self.timeout_frames then
        return self:fail("timeout in " .. self.state)
    end

    if context.is_online then return self:fail("multiplayer detected") end
    if context.build_supported == false then return self:fail("unsupported runtime") end

    if self.state == M.states.SELECT_QUEST or self.state == M.states.WAIT_POSTED then
        local ok, reason = self.api:tick_posting()
        if not ok then return self:fail(reason) end
    end

    if self.state == M.states.WAIT_HUB then
        if context.in_quest then
            self.hub_stable_frames = 0
        elseif self.api:is_hub_ready() then
            self.hub_stable_frames = self.hub_stable_frames + 1
            if self.hub_stable_frames >= self.hub_stable_required then
                self:set_state(M.states.OPEN_COUNTER)
            end
        else
            self.hub_stable_frames = 0
        end
    elseif self.state == M.states.OPEN_COUNTER then
        return advance(self, M.states.START_SESSION, self.api.open_counter)
    elseif self.state == M.states.START_SESSION then
        return advance(self, M.states.SELECT_QUEST, self.api.start_session)
    elseif self.state == M.states.SELECT_QUEST then
        local result, reason = self.api:select_quest()
        if result == true then self:set_state(M.states.WAIT_POSTED)
        elseif result == false then return self:fail(reason) end
    elseif self.state == M.states.WAIT_POSTED then
        local result, reason = self.api:update_posting()
        if result == true then self:set_state(M.states.WAIT_COUNTER_CLOSE)
        elseif result == false then return self:fail(reason) end
    elseif self.state == M.states.WAIT_COUNTER_CLOSE then
        if self.api:is_counter_closed() then self:set_state(M.states.DEPART) end
    elseif self.state == M.states.DEPART then
        return advance(self, M.states.WAIT_QUEST, self.api.depart)
    elseif self.state == M.states.WAIT_QUEST then
        if context.in_quest and tonumber(context.quest_no) == tonumber(self.quest_id) then
            self.api:finish_posting()
            self:set_state(M.states.COMPLETE)
        end
    end
    return true
end

function M:reset_terminal()
    if self.state == M.states.COMPLETE or self.state == M.states.FAILED then
        self:set_state(M.states.IDLE)
    end
end

function M:shutdown()
    self.api:cancel_posting()
    self:set_state(M.states.IDLE)
end

return M
