local QuestRestart = require("MHRiseMonsterCoach.quest_restart")

local M = {}

local function target_quest(context, quest_id)
    return context.in_quest and tonumber(context.quest_no) == tonumber(quest_id)
        and not context.is_online and context.build_supported ~= false
end

-- Native area numbers are inconsistent in the Forlorn Arena (the player can
-- report 0/1 while Tigrex remains -1 after a successful transfer).  Runtime
-- therefore derives a scene-layer signal from the live actor transforms.
local function combat_area_ready(areas)
    return areas ~= nil and areas.combat_layer == true
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
        arena_transfer = { attempted = false },
        monster_respawn = { attempted = false, state = "idle" },
        respawn_failure = nil,
        forced_actions = {},
        forced_index = 0,
        forced_results = {},
        forced_error = nil,
        forced_failure_count = 0,
        training_acceptance = nil,
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
        quest_flow = self.quest_flow:diagnostics(),
        environment = evidence,
        areas = self.api:area_snapshot(),
        arena_transfer = self.arena_transfer,
        monster_respawn = self.monster_respawn,
        forced_actions = {
            requested = self.forced_actions,
            results = self.forced_results,
            evidence = self.api.action_request_evidence and self.api:action_request_evidence() or nil,
        },
        training_acceptance = self.training_acceptance,
    }
    self.api:write_report(report)
    if report.session_id and (status == "completed" or status == "failed") then
        self.completed_sessions[report.session_id] = true
    end
    return report
end

function M:fail(reason)
    if self.request and self.request.kind == "training_scenario_acceptance"
        and self.api.finish_training_acceptance then self.api:finish_training_acceptance() end
    self:report("failed", tostring(reason or "unknown error"))
    self.quest_flow:shutdown()
    self.request = nil
    self.probe_key = nil
    self:set_state("idle")
    return false
end

function M:complete()
    local reason = nil
    if self.forced_failure_count > 0 then
        reason = tostring(self.forced_failure_count)
            .. " forced action(s) were isolated and safely recovered"
    end
    self:report("completed", reason)
    if self.request and self.request.kind == "training_scenario_acceptance"
        and self.api.finish_training_acceptance then self.api:finish_training_acceptance() end
    self.request = nil
    self.probe_key = nil
    self:set_state("idle")
    return true
end

function M:mark_forced_failure(reason)
    local action = self.forced_actions[self.forced_index]
    local result = self.forced_results[self.forced_index]
    if result == nil then
        result = { action = action }
        self.forced_results[self.forced_index] = result
    end
    if result.status ~= "failed" then self.forced_failure_count = self.forced_failure_count + 1 end
    result.status = "failed"
    result.reason = tostring(reason)
    result.failed_at_frame = self.frame
end

function M:accept_request(request, context)
    if type(request) ~= "table"
        or (request.kind ~= "environment_creature_lifecycle"
            and request.kind ~= "monster_respawn_lifecycle"
            and request.kind ~= "forced_action_sequence"
            and request.kind ~= "training_scenario_acceptance")
        or type(request.session_id) ~= "string" or request.session_id == "" then return false end
    if self.completed_sessions[request.session_id] then return false end
    if request.auto_load_save == true and context.in_quest ~= true
        and context.player_found ~= true then return false end
    self.request = request
    self.monster_respawn = { attempted = false, state = "idle" }
    self.respawn_failure = nil
    self.forced_actions = {}
    self.forced_index = 0
    self.forced_results = {}
    self.forced_error = nil
    self.forced_failure_count = 0
    self.training_acceptance = nil
    if request.kind == "forced_action_sequence" then
        if type(request.forced_actions) ~= "table"
            or #request.forced_actions == 0 or #request.forced_actions > 8 then
            return self:fail("Forced action sequence must contain 1-8 actions")
        end
        for _, action in ipairs(request.forced_actions) do
            if tonumber(action) == nil then return self:fail("Forced action sequence contains an invalid ID") end
            self.forced_actions[#self.forced_actions + 1] = tonumber(action)
        end
    end
    if request.kind == "training_scenario_acceptance" then
        if type(request.training_scenario_id) ~= "string" or request.training_scenario_id == ""
            or tonumber(request.training_repeat_count) == nil
            or tonumber(request.training_repeat_count) < 1 or tonumber(request.training_repeat_count) > 20 then
            return self:fail("Training acceptance requires a scenario ID and 1-20 repeats")
        end
    end
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
        local areas = self.api:area_snapshot()
        local combat_ready = self.request.require_combat_area ~= true
            or combat_area_ready(areas)
        if self.request.require_combat_area == true and self.request.auto_native_arena_transfer == true
            and not combat_ready
            and self.state_frames % 30 == 1 then
            local ok, reason, retry = self.api:request_arena_transfer()
            self.arena_transfer = { attempted = true, ok = ok, reason = reason, retry = retry }
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        if target_quest(context, self.quest_id) and context.target_found and combat_ready then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                if self.request.allow_spawn_probe ~= true then
                    if self.request.kind == "training_scenario_acceptance" then
                        local ok, reason = self.api:start_training_acceptance(
                            self.request.training_scenario_id, self.request.training_repeat_count)
                        if not ok then return self:fail(reason) end
                        self.training_acceptance = self.api:training_acceptance_status()
                        self:set_state("training_acceptance_wait")
                        return true
                    end
                    if self.request.kind == "forced_action_sequence" then
                        self.forced_index = 1
                        self:set_state("forced_prepare")
                        return true
                    end
                    if self.request.kind == "monster_respawn_lifecycle" then
                        local ok, reason = self.api:start_monster_respawn()
                        self.monster_respawn = { attempted = true, state = "starting", reason = reason }
                        if not ok then return self:fail(reason) end
                        self:set_state("monster_respawn")
                        return true
                    end
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
    elseif self.state == "training_acceptance_wait" then
        self.training_acceptance = self.api:training_acceptance_status()
        if self.state_frames % 30 == 0 then self:report("running") end
        if self.training_acceptance.state == "completed" then
            return self:complete()
        end
        if self.training_acceptance.state == "failed"
            or self.training_acceptance.state == "unavailable"
            or self.training_acceptance.state == "cancelled" then
            return self:fail("Training acceptance stopped: "
                .. tostring(self.training_acceptance.status or self.training_acceptance.state))
        end
        if self.state_frames > 3600 then
            return self:fail("Training acceptance timed out")
        end
    elseif self.state == "forced_prepare" then
        if self.state_frames % 30 == 1 then self:report("running") end
        local action = self.forced_actions[self.forced_index]
        if action == nil then return self:complete() end
        local ok, reason, retry = self.api:request_forced_action(action)
        if ok then
            self.forced_results[self.forced_index] = {
                action = action,
                requested_at_frame = self.frame,
                status = "requested",
            }
            self:set_state("forced_verify")
        elseif not retry or self.state_frames > 600 then
            self.forced_error = "Action " .. tostring(action) .. " request failed: " .. tostring(reason)
            self:mark_forced_failure(self.forced_error)
            self.quest_flow:reset_terminal()
            local recovered, recovery_reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.forced_error .. "; recovery failed: "
                .. tostring(recovery_reason)) end
            self:set_state("forced_recovery")
        end
    elseif self.state == "forced_verify" then
        if self.state_frames % 15 == 0 then self:report("running") end
        local result = self.forced_results[self.forced_index]
        local current = self.api:current_action() or {}
        if tonumber(current.category) == 4 and tonumber(current.action) == tonumber(result.action) then
            result.status = "matched"
            result.matched_at_frame = self.frame
            result.match_latency_frames = self.frame - result.requested_at_frame
            result.motion_name = current.motion_name
            self:set_state("forced_wait_exit")
        elseif self.state_frames > 180 then
            self.forced_error = "Action " .. tostring(result.action) .. " was not observed after request"
            self:mark_forced_failure(self.forced_error)
            self.quest_flow:reset_terminal()
            local recovered, recovery_reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.forced_error .. "; recovery failed: "
                .. tostring(recovery_reason)) end
            self:set_state("forced_recovery")
        end
    elseif self.state == "forced_wait_exit" then
        if self.state_frames % 30 == 0 then self:report("running") end
        local result = self.forced_results[self.forced_index]
        local current = self.api:current_action() or {}
        local left_requested = tonumber(current.category) ~= 4
            or tonumber(current.action) ~= tonumber(result.action)
        if self.state_frames >= 10 and left_requested then
            result.status = "completed"
            result.completed_at_frame = self.frame
            result.duration_frames = self.frame - result.matched_at_frame
            result.exit_to = {
                category = current.category,
                action = current.action,
                motion_name = current.motion_name,
            }
            self.forced_index = self.forced_index + 1
            self:set_state("forced_prepare")
        elseif self.state_frames > 900 then
            self.forced_error = "Action " .. tostring(result.action) .. " did not finish"
            self:mark_forced_failure(self.forced_error)
            self.quest_flow:reset_terminal()
            local recovered, recovery_reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.forced_error .. "; recovery failed: "
                .. tostring(recovery_reason)) end
            self:set_state("forced_recovery")
        end
    elseif self.state == "forced_recovery" then
        self.quest_flow:update(context)
        if self.state_frames % 30 == 0 then self:report("running") end
        if self.quest_flow.state == "failed" then
            return self:fail(self.forced_error .. "; F7 recovery failed: "
                .. tostring(self.quest_flow.error))
        end
        if self.quest_flow.state == "complete" then
            self:set_state("forced_recovery_verify")
        end
    elseif self.state == "forced_recovery_verify" then
        local areas = self.api:area_snapshot()
        local combat_ready = combat_area_ready(areas)
        if self.state_frames % 30 == 1 then self:report("running") end
        if target_quest(context, self.quest_id) and context.target_found and combat_ready then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                if self.request.continue_on_action_failure == true then
                    local result = self.forced_results[self.forced_index]
                    if result ~= nil then result.recovered = true end
                    self.forced_index = self.forced_index + 1
                    self.forced_error = nil
                    self:set_state("forced_prepare")
                    return true
                end
                return self:fail(self.forced_error
                    .. "; F7 recovery completed and combat area restored")
            end
        else
            self.stable_frames = 0
        end
    elseif self.state == "monster_respawn" then
        local state, reason, diagnostics = self.api:update_monster_respawn()
        self.monster_respawn = {
            attempted = true,
            state = state,
            reason = reason,
            diagnostics = diagnostics,
        }
        if self.state_frames % 15 == 0 then self:report("running") end
        if state == "complete" then return self:complete() end
        if state == "failed" then
            self.respawn_failure = reason or "Monster respawn lifecycle failed"
            self.quest_flow:reset_terminal()
            local ok, recovery_reason = self.quest_flow:start(context)
            if not ok then
                return self:fail(self.respawn_failure .. "; F7 recovery failed: "
                    .. tostring(recovery_reason))
            end
            self:set_state("monster_respawn_recovery")
        end
    elseif self.state == "monster_respawn_recovery" then
        self.quest_flow:update(context)
        if self.state_frames % 30 == 0 then self:report("running") end
        if self.quest_flow.state == "failed" then
            return self:fail(self.respawn_failure .. "; F7 recovery failed: "
                .. tostring(self.quest_flow.error))
        end
        if self.quest_flow.state == "complete" then
            self.monster_respawn.recovered = true
            self:set_state("monster_respawn_recovery_verify")
        end
    elseif self.state == "monster_respawn_recovery_verify" then
        local areas = self.api:area_snapshot()
        local combat_ready = combat_area_ready(areas)
        if self.state_frames % 30 == 1 then self:report("running") end
        if target_quest(context, self.quest_id) and context.target_found and combat_ready then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                return self:fail(self.respawn_failure
                    .. "; F7 recovery completed and combat area restored")
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
        local areas = self.api:area_snapshot()
        local combat_ready = self.request.require_combat_area ~= true
            or combat_area_ready(areas)
        if self.request.require_combat_area == true and self.request.auto_native_arena_transfer == true
            and not combat_ready
            and self.state_frames % 30 == 1 then
            local ok, reason, retry = self.api:request_arena_transfer()
            self.arena_transfer = { attempted = true, ok = ok, reason = reason, retry = retry }
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        if target_quest(context, self.quest_id) and context.target_found and combat_ready then
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
