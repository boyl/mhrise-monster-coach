local QuestRestart = require("MHRiseMonsterCoach.quest_restart")
local BehaviorPathTracker = require("MHRiseMonsterCoach.behavior_path_tracker")
local BehaviorGraphRecorder = require("MHRiseMonsterCoach.behavior_graph_recorder")

local M = {}

local function target_quest(context, quest_id)
    return context.in_quest and tonumber(context.quest_no) == tonumber(quest_id)
        and not context.is_online and context.build_supported ~= false
end

-- Native area numbers are inconsistent in the Forlorn Arena (the player can
-- report 0/1 while Tigrex remains -1 after a successful transfer).  Runtime
-- therefore derives a scene-layer signal from the live actor transforms.
local function player_only_probe(request)
    return request ~= nil and request.kind == "player_action_evidence"
end

local function combat_area_ready(areas, allow_player_only)
    return areas ~= nil and (areas.combat_layer == true
        or (allow_player_only == true and areas.player_combat_layer == true))
end

local SEMANTIC_TRIGGER_NEUTRAL_NODES = {
    ["wait.main"] = true,
    ["wait.wait_pre_mot_end"] = true,
    ["atk.atk_wait.atk_wait_main.atk_wait_main"] = true,
}

local function semantic_trigger_neutral(action)
    return action ~= nil and action.availability == "available"
        and SEMANTIC_TRIGGER_NEUTRAL_NODES[tostring(action.node_name)] == true
end

function M.new(api, quest_id, options)
    options = options or {}
    local self = setmetatable({
        api = api,
        quest_id = quest_id,
        default_quest_id = quest_id,
        player_action_quest_id = options.player_action_quest_id or quest_id,
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
        behavior_path = nil,
        behavior_survey = nil,
        native_branch = nil,
        condition_branch = nil,
        input_motion = nil,
        player_action = nil,
        ui_contract = nil,
    }, { __index = M })
    return self
end

function M:select_request_quest(request)
    local quest_id = self.default_quest_id
    if player_only_probe(request) then quest_id = self.player_action_quest_id end
    self.quest_id = quest_id
    self.quest_flow = QuestRestart.new(self.api.quest_api, quest_id, {
        hub_stable_frames = self.quest_flow.hub_stable_required,
        timeout_frames = self.quest_flow.timeout_frames,
    })
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
    local ui_only = self.request and self.request.kind == "ui_contract_snapshot"
    local evidence = not ui_only and self.api:environment_evidence() or nil
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
        areas = not ui_only and self.api:area_snapshot() or nil,
        arena_transfer = self.arena_transfer,
        monster_respawn = self.monster_respawn,
        forced_actions = {
            requested = self.forced_actions,
            results = self.forced_results,
            evidence = not ui_only and self.api.action_request_evidence
                and self.api:action_request_evidence() or nil,
        },
        training_acceptance = self.training_acceptance,
        behavior_tree = not ui_only and self.api.behavior_tree_snapshot
            and self.api:behavior_tree_snapshot() or nil,
        think_context = not ui_only and self.api.think_context_snapshot
            and self.api:think_context_snapshot(true) or nil,
        behavior_survey = self.behavior_survey and self.behavior_survey.recorder:result() or nil,
        native_branch = self.native_branch,
        condition_branch = self.condition_branch,
        input_motion = self.input_motion,
        player_action = self.player_action,
        training_timeline = not ui_only and self.api.training_timeline_diagnostics
            and self.api:training_timeline_diagnostics() or nil,
        ui_contract = self.ui_contract,
    }
    self.api:write_report(report)
    if report.session_id and (status == "completed" or status == "failed") then
        self.completed_sessions[report.session_id] = true
    end
    return report
end

function M:fail(reason)
    if self.api.release_input_motion_axis then self.api:release_input_motion_axis() end
    if self.api.cancel_semantic_input_trigger then self.api:cancel_semantic_input_trigger() end
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
    if self.api.release_input_motion_axis then self.api:release_input_motion_axis() end
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
            and request.kind ~= "training_scenario_acceptance"
            and request.kind ~= "behavior_path_survey"
            and request.kind ~= "condition_induced_branch"
            and request.kind ~= "input_motion_metadata"
            and request.kind ~= "semantic_input_trigger"
            and request.kind ~= "player_action_evidence"
            and request.kind ~= "input_motion_axis_write"
            and request.kind ~= "ui_contract_snapshot"
            and request.kind ~= "native_think_branch")
        or type(request.session_id) ~= "string" or request.session_id == "" then return false end
    if self.completed_sessions[request.session_id] then return false end
    self:select_request_quest(request)
    if request.target_quest_id ~= nil
        and tonumber(request.target_quest_id) ~= tonumber(self.quest_id) then
        self.request = request
        return self:fail("Developer probe target quest is not allowlisted")
    end
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
    self.behavior_survey = nil
    self.native_branch = nil
    self.condition_branch = nil
    self.input_motion = nil
    self.player_action = nil
    self.ui_contract = nil
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
        local response_step = tostring(request.training_response_step or "none")
        if response_step ~= "none" and response_step ~= "dodge" then
            return self:fail("Training response is not allowlisted")
        end
        if response_step == "dodge"
            and (request.training_scenario_id ~= "tigrex_rotate_attack_right_single"
                or tonumber(request.training_repeat_count) ~= 1) then
            return self:fail("Dodge response requires the single-repeat right-spin scenario")
        end
    end
    if request.kind == "behavior_path_survey" then
        local frames = tonumber(request.behavior_survey_frames)
        if frames == nil or frames < 300 or frames > 7200 then
            return self:fail("Behavior survey requires 300-7200 frames")
        end
    end
    if request.kind == "native_think_branch" then
        if request.think_reference ~= "em032_combo_001.user"
            or tonumber(request.expected_successor) ~= 5001 then
            return self:fail("Native Think branch is not allowlisted")
        end
        self.native_branch = {
            reference = request.think_reference,
            expected_roots = { 5000, 5002 },
            expected_successor = 5001,
            status = "pending",
        }
    end
    if request.kind == "condition_induced_branch" then
        if tonumber(request.target_root) ~= 5000
            or tonumber(request.expected_successor) ~= 5001
            or tonumber(request.target_distance) ~= 7 then
            return self:fail("Condition-induced branch is not allowlisted")
        end
        self.condition_branch = {
            target_root = 5000,
            expected_successor = 5001,
            target_distance = 7,
            tolerance = 2,
            timeout_frames = math.min(7200, math.max(300,
                tonumber(request.condition_timeout_frames) or 7200)),
            status = "seeking_root",
            desired_movement = "hold_band",
        }
    end
    if request.kind == "input_motion_axis_write" then
        if tonumber(request.axis_x) ~= 0 or tonumber(request.axis_y) ~= 1
            or tonumber(request.axis_frames) ~= 60 then
            return self:fail("Input motion axis write is not allowlisted")
        end
        self.input_motion = {
            status = "pending",
            axis = { x = 0, y = 1 },
            target_frames = 60,
        }
    end
    if request.kind == "semantic_input_trigger" then
        if request.semantic_command ~= "Escape" then
            return self:fail("Semantic input trigger only allows Escape")
        end
        self.input_motion = {
            status = "pending",
            semantic_command = "Escape",
            observed_nodes = {},
            neutral_gate = {
                policy = "verified_neutral_node_stability",
                required_frames = 15,
                stable_frames = 0,
                status = "waiting",
            },
        }
    end
    if context.is_online or context.build_supported == false then
        return self:fail("Developer probe requires a supported offline runtime")
    end
    if request.kind == "ui_contract_snapshot" then
        local repeats = tonumber(request.ui_requested_repeats)
        if repeats == nil or repeats < 1 or repeats > 20 then
            return self:fail("UI contract snapshot requires 1-20 requested repeats")
        end
        self.ui_contract = self.api:training_menu_snapshot(repeats)
        self:complete()
        return true
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
        local player_only = player_only_probe(self.request)
        local combat_ready = self.request.require_combat_area ~= true
            or combat_area_ready(areas, player_only)
        if self.request.require_combat_area == true and self.request.auto_native_arena_transfer == true
            and not combat_ready
            and self.state_frames % 30 == 1 then
            local ok, reason, retry = self.api:request_arena_transfer()
            self.arena_transfer = { attempted = true, ok = ok, reason = reason, retry = retry }
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        local actor_ready = context.target_found
            or (player_only and context.player_found == true)
        if target_quest(context, self.quest_id) and actor_ready and combat_ready then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                if self.request.allow_spawn_probe ~= true then
                    if self.request.kind == "training_scenario_acceptance" then
                        if self.request.training_response_step == "dodge" then
                            self.input_motion = self.api.input_motion_diagnostics
                                and self.api:input_motion_diagnostics() or nil
                            self.player_action = self.api.player_action_diagnostics
                                and self.api:player_action_diagnostics() or nil
                            local bindings = self.input_motion and self.input_motion.current_bindings
                            if type(bindings) ~= "table"
                                or bindings.policy ~= "read_only_exact_dictionary_lookup"
                                or tonumber(bindings.call_failures or 0) ~= 0
                                or tonumber(bindings.value_failures or 0) ~= 0
                                or bindings.truncated == true then
                                return self:fail("Training response current bindings are unavailable")
                            end
                            if type(self.player_action) ~= "table"
                                or self.player_action.weapon_type ~= "long_sword" then
                                return self:fail("Training response requires the current Long Sword loadout")
                            end
                        end
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
                    if self.request.kind == "behavior_path_survey" then
                        self.behavior_survey = {
                            target_frames = tonumber(self.request.behavior_survey_frames),
                            sampled_frames = 0,
                            reentry_count = 0,
                            recorder = BehaviorGraphRecorder.new(1024),
                        }
                        self:set_state("behavior_survey")
                        return true
                    end
                    if self.request.kind == "native_think_branch" then
                        self:set_state("native_branch_request")
                        return true
                    end
                    if self.request.kind == "condition_induced_branch" then
                        self:set_state("condition_branch_seek")
                        return true
                    end
                    if self.request.kind == "input_motion_metadata" then
                        self.input_motion = self.api.input_motion_diagnostics
                            and self.api:input_motion_diagnostics() or nil
                        if self.input_motion == nil then
                            return self:fail("Input motion diagnostics unavailable")
                        end
                        return self:complete()
                    end
                    if self.request.kind == "semantic_input_trigger" then
                        local diagnostics = self.api.input_motion_diagnostics
                            and self.api:input_motion_diagnostics() or nil
                        local instance = diagnostics and diagnostics.player_input_instance_contract
                            or nil
                        if instance == nil
                            or instance.policy ~= "bounded_read_only_player_input_queries"
                            or tonumber(instance.call_failures or 0) ~= 0
                            or tonumber(instance.call_count or 0)
                                ~= tonumber(instance.max_calls or -1) then
                            return self:fail("Player input read contract is unavailable")
                        end
                        self.input_motion.preflight = diagnostics
                        self.player_action = {
                            before = nil,
                            observed = {},
                        }
                        self.input_motion.status = "waiting_for_neutral"
                        self:set_state("semantic_input_trigger_prepare")
                        return true
                    end
                    if self.request.kind == "player_action_evidence" then
                        self.input_motion = self.api.input_motion_diagnostics
                            and self.api:input_motion_diagnostics() or nil
                        local bindings = self.input_motion and self.input_motion.current_bindings or nil
                        if bindings == nil
                            or bindings.policy ~= "read_only_exact_dictionary_lookup"
                            or tonumber(bindings.call_failures or 0) ~= 0
                            or tonumber(bindings.value_failures or 0) ~= 0
                            or bindings.truncated == true then
                            return self:fail("Current input binding contract is unavailable")
                        end
                        self.player_action = self.api.player_action_diagnostics
                            and self.api:player_action_diagnostics() or nil
                        local action = self.player_action and self.player_action.player_action or nil
                        if action == nil or action.availability ~= "available"
                            or action.node_id == nil or type(action.node_name) ~= "string"
                            or action.node_name == "" then
                            return self:fail("Player action node name is unavailable")
                        end
                        return self:complete()
                    end
                    if self.request.kind == "input_motion_axis_write" then
                        local areas = self.api:area_snapshot()
                        self.input_motion.status = "writing"
                        self.input_motion.start_position = areas and areas.player_position or nil
                        self:set_state("input_motion_axis_write")
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
        local target_rounds = math.max(1,
            tonumber(self.training_acceptance.target_rounds) or 1)
        if self.state_frames > 3600 * target_rounds then
            return self:fail("Training acceptance timed out")
        end
    elseif self.state == "behavior_survey_reenter" then
        local areas = self.api:area_snapshot()
        if target_quest(context, self.quest_id) and context.target_found
            and combat_area_ready(areas) then
            self.stable_frames = self.stable_frames + 1
            if self.stable_frames >= self.stable_required then
                self:set_state("behavior_survey")
                self:report("running")
            end
        else
            self.stable_frames = 0
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        if self.state_frames > 1800 then
            return self:fail("Behavior survey could not re-enter the combat area after hunter recovery")
        end
    elseif self.state == "behavior_survey" then
        local areas = self.api:area_snapshot()
        if not combat_area_ready(areas) then
            self.behavior_survey.reentry_count = self.behavior_survey.reentry_count + 1
            self:set_state("behavior_survey_reenter")
            self:report("running")
            return true
        end
        local current = self.api:current_action() or {}
        local snapshot = self.api:behavior_tree_snapshot()
        local include_catalog = self.state_frames % 30 == 1
        local think = self.api.think_context_snapshot
            and self.api:think_context_snapshot(include_catalog) or nil
        local geometry = self.api.target_geometry_snapshot
            and self.api:target_geometry_snapshot() or nil
        self.behavior_survey.recorder:sample(self.frame, snapshot, current, think, geometry)
        self.behavior_survey.sampled_frames = self.behavior_survey.sampled_frames + 1
        if self.state_frames % 120 == 0 then self:report("running") end
        if self.behavior_survey.sampled_frames >= self.behavior_survey.target_frames then
            return self:complete()
        end
    elseif self.state == "condition_branch_seek" then
        local current = self.api:current_action() or {}
        local geometry = self.api.target_geometry_snapshot
            and self.api:target_geometry_snapshot() or nil
        self.condition_branch.current_action = tonumber(current.action)
        self.condition_branch.current_category = tonumber(current.category)
        self.condition_branch.horizontal_distance = geometry
            and tonumber(geometry.horizontal_distance) or nil
        if tonumber(current.category) == 4
            and tonumber(current.action) == self.condition_branch.target_root then
            self.condition_branch.status = "root_acquired"
            self.condition_branch.desired_movement = "stop"
            self.condition_branch.root_frame = self.frame
            self.condition_branch.root_distance = self.condition_branch.horizontal_distance
            self:set_state("condition_branch_verify_successor")
            self:report("running")
            return true
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        if self.state_frames >= self.condition_branch.timeout_frames then
            self.condition_branch.status = "failed"
            return self:fail("Condition induction did not observe root Action 5000")
        end
    elseif self.state == "input_motion_axis_write" then
        local ok, reason = self.api:write_input_motion_axis(0, 1)
        if not ok then
            self.input_motion.status = "failed"
            return self:fail(reason)
        end
        self.input_motion.written_frames = self.state_frames
        if self.state_frames % 15 == 1 then self:report("running") end
        if self.state_frames >= self.input_motion.target_frames then
            local released, release_reason = self.api:release_input_motion_axis()
            if not released then return self:fail(release_reason) end
            self.input_motion.status = "released"
            self:set_state("input_motion_axis_verify")
        end
    elseif self.state == "input_motion_axis_verify" then
        if self.state_frames >= 15 then
            local areas = self.api:area_snapshot()
            self.input_motion.end_position = areas and areas.player_position or nil
            local start = self.input_motion.start_position
            local finish = self.input_motion.end_position
            if start and finish then
                local dx = tonumber(finish.x) - tonumber(start.x)
                local dz = tonumber(finish.z) - tonumber(start.z)
                self.input_motion.displacement = math.sqrt(dx * dx + dz * dz)
            end
            self.input_motion.diagnostics = self.api:input_motion_diagnostics()
            self.input_motion.status = "completed"
            return self:complete()
        end
    elseif self.state == "semantic_input_trigger_prepare" then
        local snapshot = self.api.player_action_diagnostics
            and self.api:player_action_diagnostics() or nil
        local action = snapshot and snapshot.player_action or nil
        local gate = self.input_motion.neutral_gate
        if semantic_trigger_neutral(action) then
            if gate.node_id == action.node_id and gate.node_name == action.node_name then
                gate.stable_frames = gate.stable_frames + 1
            else
                gate.node_id = action.node_id
                gate.node_name = action.node_name
                gate.stable_frames = 1
            end
            if gate.stable_frames >= gate.required_frames then
                gate.status = "ready"
                self.player_action.before = action
                local ok, reason = self.api:request_semantic_input_trigger(
                    self.input_motion.semantic_command)
                if not ok then return self:fail(reason) end
                self.input_motion.status = "armed"
                self:set_state("semantic_input_trigger_wait")
                return true
            end
        else
            gate.status = "waiting"
            gate.stable_frames = 0
            gate.node_id = action and action.node_id or nil
            gate.node_name = action and action.node_name or nil
        end
        if self.state_frames % 30 == 1 then self:report("running") end
        if self.state_frames > 600 then
            return self:fail("Semantic input trigger found no stable neutral player action")
        end
    elseif self.state == "semantic_input_trigger_wait" then
        local trigger = self.api:semantic_input_trigger_diagnostics()
        self.input_motion.semantic_trigger = trigger
        local snapshot = self.api.player_action_diagnostics
            and self.api:player_action_diagnostics() or nil
        local action = snapshot and snapshot.player_action or nil
        local last = self.player_action.observed[#self.player_action.observed]
        local before = self.player_action.before
        local changed_from_before = before == nil or action == nil
            or before.node_id ~= action.node_id or before.node_name ~= action.node_name
        if action ~= nil and action.availability == "available" and changed_from_before
            and (last == nil or last.node_id ~= action.node_id
                or last.node_name ~= action.node_name) then
            self.player_action.observed[#self.player_action.observed + 1] = {
                frame = self.frame,
                node_id = action.node_id,
                node_name = action.node_name,
            }
        end
        if trigger.status == "failed" then
            self.input_motion.status = "failed"
            return self:fail(trigger.error)
        end
        if trigger.status == "released" then
            self.input_motion.status = "released"
            if #self.player_action.observed > 0 or self.state_frames >= 60 then
                self.input_motion.postflight = self.api:input_motion_diagnostics()
                return self:complete()
            end
        end
        if self.state_frames % 15 == 1 then self:report("running") end
        if self.state_frames > 180 then
            return self:fail("Semantic input trigger timed out")
        end
    elseif self.state == "condition_branch_verify_successor" then
        local current = self.api:current_action() or {}
        local action = tonumber(current.action)
        self.condition_branch.current_action = action
        self.condition_branch.current_category = tonumber(current.category)
        if tonumber(current.category) == 4
            and action == self.condition_branch.expected_successor then
            self.condition_branch.status = "passed"
            self.condition_branch.successor_frame = self.frame
            self.condition_branch.continuation_frames = self.frame
                - self.condition_branch.root_frame
            return self:complete()
        end
        if self.state_frames % 15 == 1 then self:report("running") end
        if action ~= self.condition_branch.target_root or self.state_frames > 300 then
            self.condition_branch.status = "failed"
            return self:fail("Root Action 5000 did not continue naturally to Action 5001")
        end
    elseif self.state == "native_branch_request" then
        if self.state_frames % 30 == 1 then self:report("running") end
        local ok, result, retry = self.api:request_think_reference(self.native_branch.reference)
        if ok then
            self.native_branch.status = "requested"
            self.native_branch.requested_at_frame = self.frame
            self.native_branch.contract = result
            self.behavior_path = BehaviorPathTracker.new(256)
            self:set_state("native_branch_verify_root")
        elseif not retry or self.state_frames > 600 then
            self.native_branch.status = "failed"
            self.native_branch.reason = tostring(result)
            self.quest_flow:reset_terminal()
            local recovered, reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.native_branch.reason
                .. "; recovery failed: " .. tostring(reason)) end
            self:set_state("native_branch_recovery")
        end
    elseif self.state == "native_branch_verify_root" then
        local current = self.api:current_action() or {}
        if self.behavior_path then
            self.behavior_path:sample(self.frame, self.api:behavior_tree_snapshot(), current)
        end
        local action = tonumber(current.action)
        if tonumber(current.category) == 4 and (action == 5000 or action == 5002) then
            self.native_branch.root_action = action
            self.native_branch.root_observed_at_frame = self.frame
            self.native_branch.status = "root_observed"
            self:set_state("native_branch_verify_successor")
        elseif self.state_frames > 240 then
            self.native_branch.status = "failed"
            self.native_branch.reason = "Native root 5000/5002 was not observed"
            self.quest_flow:reset_terminal()
            local recovered, reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.native_branch.reason
                .. "; recovery failed: " .. tostring(reason)) end
            self:set_state("native_branch_recovery")
        end
    elseif self.state == "native_branch_verify_successor" then
        local current = self.api:current_action() or {}
        if self.behavior_path then
            self.behavior_path:sample(self.frame, self.api:behavior_tree_snapshot(), current)
        end
        if tonumber(current.category) == 4
            and tonumber(current.action) == self.native_branch.expected_successor then
            self.native_branch.status = "passed"
            self.native_branch.successor_observed_at_frame = self.frame
            self.native_branch.behavior_path = self.behavior_path:result()
            self.quest_flow:reset_terminal()
            local recovered, reason = self.quest_flow:start(context)
            if not recovered then return self:fail("Native branch passed but recovery failed: "
                .. tostring(reason)) end
            self:set_state("native_branch_recovery")
        elseif self.state_frames > 900 then
            self.native_branch.status = "failed"
            self.native_branch.reason = "Expected native successor 5001 was not observed"
            self.native_branch.behavior_path = self.behavior_path:result()
            self.quest_flow:reset_terminal()
            local recovered, reason = self.quest_flow:start(context)
            if not recovered then return self:fail(self.native_branch.reason
                .. "; recovery failed: " .. tostring(reason)) end
            self:set_state("native_branch_recovery")
        end
    elseif self.state == "native_branch_recovery" then
        self.quest_flow:update(context)
        if self.state_frames % 30 == 0 then self:report("running") end
        if self.quest_flow.state == "failed" then
            return self:fail("Native branch recovery failed: " .. tostring(self.quest_flow.error))
        end
        if self.quest_flow.state == "complete" then
            if self.native_branch.status == "passed" then return self:complete() end
            return self:fail(self.native_branch.reason or "Native Think branch failed")
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
            self.behavior_path = BehaviorPathTracker.new(128)
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
        if self.behavior_path and self.api.behavior_tree_snapshot then
            self.behavior_path:sample(self.frame, self.api:behavior_tree_snapshot(), current)
        end
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
        if self.behavior_path and self.api.behavior_tree_snapshot then
            self.behavior_path:sample(self.frame, self.api:behavior_tree_snapshot(), current)
        end
        local left_requested = tonumber(current.category) ~= 4
            or tonumber(current.action) ~= tonumber(result.action)
        local left_attack_tree = self.behavior_path
            and self.behavior_path:attack_cycle_completed_since(result.matched_at_frame)
        if self.state_frames >= 10 and (left_requested or left_attack_tree) then
            result.status = "completed"
            result.completed_at_frame = self.frame
            result.duration_frames = self.frame - result.matched_at_frame
            result.completion_basis = left_attack_tree and "behavior_tree_attack_exit"
                or "action_identity_changed"
            result.exit_to = {
                category = current.category,
                action = current.action,
                motion_name = current.motion_name,
            }
            result.behavior_path = self.behavior_path and self.behavior_path:result() or nil
            self.behavior_path = nil
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
