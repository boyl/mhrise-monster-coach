local QuestRestart = require("MHRiseMonsterCoach.quest_restart")

local M = {}

local function target_quest(context, quest_id)
    return context.in_quest and tonumber(context.quest_no) == tonumber(quest_id)
        and not context.is_online and context.build_supported ~= false
end

function M.new(api, quest_id, options)
    options = options or {}
    return setmetatable({
        api = api,
        quest_id = quest_id,
        state = "idle",
        frame = 0,
        state_frames = 0,
        stable_frames = 0,
        request = nil,
        probe_key = nil,
        quest_flow = QuestRestart.new(api.quest_api, quest_id, {
            hub_stable_frames = options.hub_stable_frames or 15,
            timeout_frames = options.quest_timeout_frames or 3600,
        }),
        stable_required = options.stable_frames or 120,
        collect_wait_frames = options.collect_wait_frames or 180,
        spawn_retry_interval_frames = options.spawn_retry_interval_frames or 30,
        spawn_timeout_frames = options.spawn_timeout_frames or 1800,
        spawn_attempts = 0,
        last_spawn_attempt_frame = nil,
        last_spawn_reason = nil,
        completed_sessions = {},
    }, { __index = M })
end

function M:set_state(state)
    self.state = state
    self.state_frames = 0
    self.stable_frames = 0
    self.spawn_attempts = 0
    self.last_spawn_attempt_frame = nil
    self.last_spawn_reason = nil
end

function M:report(status, reason)
    local evidence = self.api:environment_evidence()
    local report = {
        schema_version = 1,
        session_id = self.request and self.request.session_id or nil,
        kind = self.request and self.request.kind or nil,
        status = status,
        reason = reason,
        state = self.state,
        probe_key = self.probe_key,
        frames = self.frame,
        quest_flow = {
            state = self.quest_flow.state,
            status = self.quest_flow.status,
            error = self.quest_flow.error,
        },
        environment = evidence,
    }
    self.api:write_report(report)
    if report.session_id then self.completed_sessions[report.session_id] = true end
    return report
end

function M:fail(reason)
    self:report("failed", tostring(reason or "unknown error"))
    self.quest_flow:shutdown()
    self.request = nil
    self.probe_key = nil
    self:set_state("idle")
    return false
end

function M:complete()
    self:report("completed")
    self.request = nil
    self.probe_key = nil
    self:set_state("idle")
    return true
end

function M:accept_request(request, context)
    if type(request) ~= "table" or request.kind ~= "environment_creature_lifecycle"
        or type(request.session_id) ~= "string" or request.session_id == "" then return false end
    if self.completed_sessions[request.session_id] then return false end
    if request.auto_load_save == true and context.in_quest ~= true
        and context.player_found ~= true then return false end
    self.request = request
    if context.is_online or context.build_supported == false then
        return self:fail("Developer probe requires a supported offline runtime")
    end
    if context.in_quest then
        if not target_quest(context, self.quest_id) then
            return self:fail("Leave the current quest before starting the developer probe")
        end
        self:set_state("wait_stable")
        return true
    end
    self.quest_flow:reset_terminal()
    local ok, reason = self.quest_flow:start_from_hub(context)
    if not ok then return self:fail(reason) end
    self:set_state("launching")
    return true
end

function M:update()
    self.frame = self.frame + 1
    local context = self.api:get_context() or {}
    if self.state == "idle" then
        if self.frame % 60 == 1 then self:accept_request(self.api:read_request(), context) end
        return
    end
    self.state_frames = self.state_frames + 1

    if context.is_online or context.build_supported == false then
        return self:fail("Developer probe left the supported offline runtime")
    end

    if self.state == "launching" then
        self.quest_flow:update(context)
        if self.quest_flow.state == "failed" then return self:fail(self.quest_flow.error) end
        if self.quest_flow.state == "complete" then self:set_state("wait_stable") end
    elseif self.state == "wait_stable" then
        if target_quest(context, self.quest_id) and context.target_found then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                if self.request.allow_spawn_probe ~= true then
                    self.api:observe_environment()
                    self:set_state("wait_collection")
                    return true
                end
                local due = self.last_spawn_attempt_frame == nil
                    or self.state_frames - self.last_spawn_attempt_frame
                        >= self.spawn_retry_interval_frames
                if due then
                    self.last_spawn_attempt_frame = self.state_frames
                    self.spawn_attempts = self.spawn_attempts + 1
                    self.api:observe_environment()
                    local ok, key_or_reason = self.api:spawn_environment_probe(
                        self.request.session_id)
                    if ok then
                        self.probe_key = key_or_reason
                        self.api:observe_environment()
                        self:set_state("wait_collection")
                    else
                        self.last_spawn_reason = key_or_reason
                    end
                end
                if self.state == "wait_stable"
                    and self.stable_frames >= self.stable_required + self.spawn_timeout_frames then
                    return self:fail("Environment probe initialization timed out: "
                        .. tostring(self.last_spawn_reason or "unknown reason"))
                end
            end
        else
            self.stable_frames = 0
        end
    elseif self.state == "wait_collection" then
        if self.state_frames % 15 == 0 then self.api:observe_environment() end
        if self.state_frames >= self.collect_wait_frames then
            self.quest_flow:reset_terminal()
            local ok, reason = self.quest_flow:start(context)
            if not ok then return self:fail(reason) end
            self:set_state("restarting")
        end
    elseif self.state == "restarting" then
        self.quest_flow:update(context)
        if self.quest_flow.state == "failed" then return self:fail(self.quest_flow.error) end
        if self.quest_flow.state == "complete" then self:set_state("verify_restart") end
    elseif self.state == "verify_restart" then
        if target_quest(context, self.quest_id) and context.target_found then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                self.api:observe_environment()
                return self:complete()
            end
        else
            self.stable_frames = 0
        end
    end
end

function M:shutdown()
    if self.state ~= "idle" then self:fail("script shutdown") end
end

return M
