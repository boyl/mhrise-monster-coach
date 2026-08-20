local M = {}

local CONTINUE_INDEX = 1
local NEW_GAME_INDEX = 0
local FIRST_SAVE_SLOT = 0
local TITLE_STATE_INIT = 0
local TITLE_STATE_PRESS_ANY = 1
local TITLE_STATE_MENU = 2
local TITLE_STATE_NEW_GAME = 3

function M.new(api, options)
    options = options or {}
    return setmetatable({
        api = api,
        state = "idle",
        request = nil,
        frame = 0,
        state_frames = 0,
        started_at = nil,
        now = options.now or os.time,
        timeout_seconds = options.timeout_seconds or 180,
        completed_sessions = {},
    }, { __index = M })
end

function M:set_state(state)
    self.state = state
    self.state_frames = 0
end

function M:write_status(status, reason, action)
    local diagnostics = self.api.diagnostics and self.api:diagnostics() or nil
    self.api:write_status({
        schema_version = 1,
        session_id = self.request and self.request.session_id or nil,
        status = status,
        reason = reason,
        state = self.state,
        action = action,
        diagnostics = diagnostics,
        frame = self.frame,
    })
end

function M:fail(reason)
    self:write_status("failed", tostring(reason or "unknown bootstrap error"))
    if self.request then self.completed_sessions[self.request.session_id] = true end
    self.request = nil
    self:set_state("idle")
    return false
end

function M:complete()
    self:write_status("completed")
    if self.request then self.completed_sessions[self.request.session_id] = true end
    self.request = nil
    self:set_state("idle")
    return true
end

function M:request_key(action_name)
    self:write_status("input_required", nil, {
        id = tostring(self.request.session_id) .. ":" .. action_name,
        kind = "press_enter",
    })
end

function M:accept_request(request)
    if type(request) ~= "table" or request.auto_load_save ~= true
        or type(request.session_id) ~= "string" or request.session_id == "" then return false end
    if self.completed_sessions[request.session_id] then return false end
    self.request = request
    self.started_at = self.now()
    self:set_state("observing")
    self:write_status("running")
    return true
end

function M:update()
    self.frame = self.frame + 1
    if self.state == "idle" then
        if self.frame % 30 == 1 then self:accept_request(self.api:read_request()) end
        return
    end
    self.state_frames = self.state_frames + 1
    if self.started_at and self.now() - self.started_at > self.timeout_seconds then
        return self:fail("Title/save bootstrap timed out")
    end

    local view = self.api:observe() or {}
    if view.in_hub == true then return self:complete() end
    if view.build_supported == false then return self:fail("Unsupported game build") end
    if view.title_state == TITLE_STATE_NEW_GAME then
        return self:fail("Safety stop: game entered the New Game state")
    end

    if view.title_state == TITLE_STATE_INIT then
        local ok, reason = self.api:advance_to_press_any()
        if not ok then return self:fail(reason or "Unable to advance the title INIT state") end
        self:write_status("running")
        return
    end

    if self.state == "wait_hub" then
        self:write_status("running")
        return
    end

    if self.state == "wait_save_menu" and view.save_menu_available == true then
        local ok, reason = self.api:select_save_slot(FIRST_SAVE_SLOT)
        if not ok then return self:fail(reason or "Unable to select the first save slot") end
        local verified = self.api:observe() or {}
        if tonumber(verified.current_save_slot) ~= FIRST_SAVE_SLOT then
            return self:fail("First save slot verification failed")
        end
        self:set_state("wait_hub")
        self:request_key("choose_first_save")
        return
    end

    if view.title_state == TITLE_STATE_PRESS_ANY then
        self:set_state("wait_title_menu")
        self:request_key("press_any")
        return
    end

    if view.title_state == TITLE_STATE_MENU then
        local ok, reason = self.api:select_title_menu(CONTINUE_INDEX)
        if not ok then return self:fail(reason or "Unable to select Continue") end
        local verified = self.api:observe() or {}
        if tonumber(verified.title_cursor_index) == NEW_GAME_INDEX then
            return self:fail("Safety stop: title cursor still points to New Game")
        end
        if tonumber(verified.title_cursor_index) ~= CONTINUE_INDEX then
            return self:fail("Continue cursor verification failed")
        end
        self:set_state("wait_save_menu")
        self:request_key("choose_continue")
        return
    end

    self:write_status("running")
end

function M:shutdown()
    if self.state ~= "idle" then self:fail("script shutdown") end
end

return M
