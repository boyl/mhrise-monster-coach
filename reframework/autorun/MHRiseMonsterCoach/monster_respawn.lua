local M = {}

M.states = {
    IDLE = "idle",
    REQUEST_DESTROY = "request_destroy",
    WAIT_ABSENT = "wait_absent",
    REQUEST_CREATE = "request_create",
    WAIT_PRESENT = "wait_present",
    COMPLETE = "complete",
    FAILED = "failed",
}

function M.new(api, options)
    options = options or {}
    return setmetatable({
        api = api,
        state = M.states.IDLE,
        state_frames = 0,
        timeout_frames = options.timeout_frames or 600,
        stable_required = options.stable_frames or 15,
        stable_frames = 0,
        contract = nil,
        result = nil,
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
    self.state_frames = 0
    self.stable_frames = 0
end

function M:fail(reason)
    self.error = tostring(reason or "unknown monster respawn error")
    self:set_state(M.states.FAILED)
    return false
end

function M:start(contract)
    if self:is_active() then return false, "Monster respawn already in progress" end
    if contract == nil or contract.set_info == nil or contract.enemy == nil then
        return false, "Verified monster spawn contract unavailable"
    end
    self.contract = contract
    self.result = nil
    self.error = nil
    self:set_state(M.states.REQUEST_DESTROY)
    return true
end

function M:update()
    if not self:is_active() then return false end
    self.state_frames = self.state_frames + 1
    if self.state_frames > self.timeout_frames then
        return self:fail("timeout in " .. self.state)
    end

    if self.state == M.states.REQUEST_DESTROY then
        local ok, reason = self.api:request_destroy(self.contract)
        if not ok then return self:fail(reason) end
        self:set_state(M.states.WAIT_ABSENT)
    elseif self.state == M.states.WAIT_ABSENT then
        if self.api:is_enemy_absent(self.contract) then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                self:set_state(M.states.REQUEST_CREATE)
            end
        else
            self.stable_frames = 0
        end
    elseif self.state == M.states.REQUEST_CREATE then
        local ok, enemy_or_reason = self.api:request_create(self.contract)
        if ok == false then return self:fail(enemy_or_reason) end
        if ok == true then
            self.result = enemy_or_reason
            self:set_state(M.states.WAIT_PRESENT)
        end
    elseif self.state == M.states.WAIT_PRESENT then
        local enemy = self.api:find_created_enemy(self.contract, self.result)
        if enemy ~= nil then
            self.stable_frames = self.stable_frames + 1
            self.result = enemy
            if self.stable_frames >= self.stable_required then
                self:set_state(M.states.COMPLETE)
            end
        else
            self.stable_frames = 0
        end
    end
    return true
end

function M:reset_terminal()
    if self.state == M.states.COMPLETE or self.state == M.states.FAILED then
        self.contract = nil
        self.result = nil
        self.error = nil
        self:set_state(M.states.IDLE)
    end
end

return M
