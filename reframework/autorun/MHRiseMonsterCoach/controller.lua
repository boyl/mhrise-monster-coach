local BehaviorPathTracker = require("MHRiseMonsterCoach.behavior_path_tracker")

local M = {}

local function now()
    return os.clock()
end

local function key_down(code)
    return reframework:is_key_down(code) == true
end

function M.new(model, runtime, view, config, config_module, font, input_adapter)
    return setmetatable({
        model = model,
        runtime = runtime,
        view = view,
        config = config,
        config_module = config_module,
        font = font,
        previous_keys = {},
        slowmo_active = false,
        slowmo_toggled = false,
        last_health = nil,
        last_error = nil,
        frame_counter = 0,
        input = input_adapter,
        input_state = { available = false, device = "keyboard" },
        saved_evidence_revision = 0,
        auto_anchor_stable_frames = 0,
        reset_pending = false,
        reset_status = "Waiting for training quest",
        reset_stage = 0,
        reset_safe_frames = 0,
        reset_cooldown_until = 0,
        reset_sequence = 0,
        reset_trace_exit_frames = 0,
        native_reset_requested = false,
        reset_trace_mode = nil,
        restart_state = "idle",
        training_state = "idle",
        training_status = "Specified-move training is disabled",
        training_scenario = nil,
        training_started_frame = 0,
        training_matched_frame = nil,
        training_target_rounds = 1,
        training_completed_rounds = 0,
        training_next_request_frame = 0,
        training_preview_scenario_id = nil,
        training_preview_tree = nil,
        training_behavior_tracker = nil,
        training_last_behavior_path = nil,
        training_root_frame = nil,
        training_actual_branch = nil,
    }, { __index = M })
end

function M.preview_training_scenario(self, scenario)
    local tree = self.model:training_branch_tree(scenario, 3)
    if tree == nil then
        self.training_status = "无法读取该场景的派生树"
        return false
    end
    self.training_preview_scenario_id = tostring(scenario.id)
    self.training_preview_tree = tree
    self.training_status = "已查看“" .. tostring(scenario.name_zh or scenario.name)
        .. "”派生树，可开始训练"
    return true
end

function M.set_training_state(self, state, status, scenario)
    self.training_state = state
    self.training_status = status
    if scenario ~= nil then self.training_scenario = scenario end
    self.model.training_scenario = {
        id = self.training_scenario and self.training_scenario.id or nil,
        name = self.training_scenario
            and (self.training_scenario.name_zh or self.training_scenario.name) or nil,
        state = state,
        status = status,
        completed_rounds = self.training_completed_rounds,
        target_rounds = self.training_target_rounds,
        actual_path = self.training_behavior_tracker and self.training_behavior_tracker:result()
            or self.training_last_behavior_path,
        actual_branch = self.training_actual_branch,
    }
end

function M.training_repeat_count(self, scenario, requested_override)
    local requested = math.max(1, math.min(20,
        math.floor(tonumber(requested_override or self.config.training_repeat_count) or 1)))
    local verified_limit = type(scenario) == "table"
        and tonumber(scenario.max_verified_repeats) or nil
    if verified_limit == nil then return requested end
    return math.min(requested, math.max(1, math.floor(verified_limit)))
end

function M.training_scenario_presentation(self, scenario, requested_override)
    local requested = math.max(1, math.min(20,
        math.floor(tonumber(requested_override or self.config.training_repeat_count) or 1)))
    local effective = M.training_repeat_count(self, scenario, requested)
    local name = tostring(scenario.name_zh or scenario.name or scenario.id)
    local limited = effective < requested
    return {
        scenario_id = tostring(scenario.id),
        name = name,
        requested_repeats = requested,
        effective_repeats = effective,
        start_label = "开始：" .. name .. " × " .. tostring(effective),
        repeat_gate_message = limited and ("该场景当前仅开放 " .. tostring(effective)
            .. " 轮：更高重复次数尚未通过稳定性门禁。") or nil,
    }
end

function M.training_entry_status(self)
    if self.config.forced_action_training_enabled ~= true then
        return false, "请先启用“指定出招训练”", false
    end
    local context = self.model.context or {}
    if not context.in_quest or context.is_online or context.build_supported == false
        or tonumber(context.quest_no) ~= tonumber(self.model.profile.training_quest.id)
        or not context.target_found then
        return false, "仅支持单人陪练任务的怪物区域", false
    end
    local category = self.model.current_metadata and tonumber(self.model.current_metadata.action_category)
    local coaching = self.model.coaching_state and self.model:coaching_state() or {}
    if category == 4 and coaching.phase ~= "recovery" then
        -- ActionNo can remain on the completed attack after the primary FSM has
        -- already returned to Normal/Wait/Move. Reuse the same strict behavior-
        -- tree classification that proves a sticky-ActionNo round completed.
        -- Unknown or still-Attack snapshots remain fail-closed.
        local family = "unknown"
        if self.runtime.behavior_tree_snapshot then
            local ok, snapshot = pcall(function()
                return self.runtime:behavior_tree_snapshot()
            end)
            if ok then family = BehaviorPathTracker.primary_family(snapshot) end
        end
        if family ~= "non_attack" then
            return false, "等待怪物进入非攻击或收招状态", true
        end
    end
    return true
end

function M.issue_training_scenario(self)
    local scenario = self.training_scenario
    local allowed, reason, retry = M.training_entry_status(self)
    if not allowed then
        M.set_training_state(self, retry and "waiting" or "unavailable", reason, scenario)
        self.training_next_request_frame = self.frame_counter + 15
        return false
    end
    if scenario.execution_mode == "natural_condition" then
        self.training_started_frame = self.frame_counter
        self.training_matched_frame = nil
        self.training_root_frame = nil
        self.training_behavior_tracker = BehaviorPathTracker.new(128)
        M.set_training_state(self, "positioning", "正在读取与怪物的距离…", scenario)
        return true
    end
    local ok, reason, retry = self.runtime:request_training_scenario(scenario)
    if not ok then
        M.set_training_state(self, retry and "waiting" or "unavailable", tostring(reason), scenario)
        self.training_next_request_frame = self.frame_counter + 15
        return false
    end
    self.training_started_frame = self.frame_counter
    self.training_matched_frame = nil
    self.training_root_frame = nil
    self.training_behavior_tracker = BehaviorPathTracker.new(128)
    M.set_training_state(self, "requested", "已请求，等待怪物进入“"
        .. tostring(scenario.name_zh or scenario.name) .. "”", scenario)
    return true
end

function M.start_training_scenario(self, scenario)
    if self.training_state == "requested" or self.training_state == "running"
        or self.training_state == "waiting" or self.training_state == "positioning" then
        M.set_training_state(self, self.training_state,
            "当前训练仍在进行；可点击“停止训练”或按 F7", self.training_scenario)
        return false
    end
    if self.training_preview_scenario_id ~= tostring(scenario.id) then
        M.set_training_state(self, "unavailable", "开始前请先查看该招式的派生树", scenario)
        return false
    end
    self.training_scenario = scenario
    self.training_target_rounds = M.training_repeat_count(self, scenario)
    self.training_completed_rounds = 0
    self.training_behavior_tracker = nil
    self.training_last_behavior_path = nil
    self.training_actual_branch = nil
    self.training_next_request_frame = self.frame_counter
    M.set_training_state(self, "waiting", "训练已开始，等待安全空档", scenario)
    M.issue_training_scenario(self)
    return self.training_state ~= "unavailable"
end

function M.cancel_training_scenario(self, status)
    self.training_next_request_frame = 0
    self.training_behavior_tracker = nil
    M.set_training_state(self, "cancelled", status or "训练已停止")
end

local function positioning_status(scenario, distance)
    local positioning = scenario and scenario.positioning
    local target = type(positioning) == "table" and tonumber(positioning.target) or nil
    local tolerance = type(positioning) == "table" and tonumber(positioning.tolerance) or nil
    if distance == nil or target == nil or tolerance == nil then
        return "无法读取距离；请保持在怪物区域", false
    end
    if distance > target + tolerance then
        return string.format("距离 %.1fm：接近怪物（目标 %.0f±%.0fm）", distance, target, tolerance), false
    end
    if distance < target - tolerance then
        return string.format("距离 %.1fm：远离怪物（目标 %.0f±%.0fm）", distance, target, tolerance), false
    end
    return string.format("距离 %.1fm 合适：等待目标起手", distance), true
end

local function expected_branch_map(scenario)
    local result = {}
    if type(scenario.expected_branches) == "table" then
        for _, branch in ipairs(scenario.expected_branches) do
            local action = type(branch) == "table" and tonumber(branch.action) or nil
            if action ~= nil then result[action] = branch end
        end
    end
    local legacy = tonumber(scenario.expected_successor)
    if legacy ~= nil and result[legacy] == nil then
        result[legacy] = { action = legacy, kind = "fixed" }
    end
    return result
end

function M.update_natural_condition_training(self, current)
    local scenario = self.training_scenario or {}
    local root = scenario.actions and tonumber(scenario.actions[1]) or nil
    local branches = expected_branch_map(scenario)
    local category, action = tonumber(current.category), tonumber(current.action)
    if self.training_behavior_tracker and self.runtime.behavior_tree_snapshot then
        self.training_behavior_tracker:sample(self.frame_counter,
            self.runtime:behavior_tree_snapshot(), current)
    end
    if self.training_state == "positioning" then
        if category == 4 and action == root then
            if self.model.rearm_current_action_round then
                self.model:rearm_current_action_round(now(), root)
            end
            self.training_root_frame = self.frame_counter
            self.training_matched_frame = self.frame_counter
            M.set_training_state(self, "running", "起手已出现：等待后续派生", scenario)
            return
        end
        local geometry = self.runtime.target_geometry_snapshot
            and self.runtime:target_geometry_snapshot() or nil
        local status = positioning_status(scenario,
            geometry and tonumber(geometry.horizontal_distance) or nil)
        M.set_training_state(self, "positioning", status, scenario)
        return
    end
    if self.training_state ~= "running" then return end
    local matched_branch = category == 4 and branches[action] or nil
    if matched_branch ~= nil then
        self.training_actual_branch = {
            action = action,
            name = matched_branch.name_zh or matched_branch.name,
            condition = matched_branch.condition,
            kind = matched_branch.kind or scenario.branch_kind or "candidate",
        }
        self.training_last_behavior_path = self.training_behavior_tracker
            and self.training_behavior_tracker:result() or nil
        self.training_behavior_tracker = nil
        self.training_completed_rounds = self.training_completed_rounds + 1
        if self.training_completed_rounds >= self.training_target_rounds then
            M.set_training_state(self, "completed", string.format("派生已确认：%d/%d",
                self.training_completed_rounds, self.training_target_rounds), scenario)
        else
            self.training_next_request_frame = self.frame_counter + 30
            M.set_training_state(self, "waiting", string.format("已完成 %d/%d，准备下一轮",
                self.training_completed_rounds, self.training_target_rounds), scenario)
        end
        return
    end
    if self.frame_counter - (self.training_root_frame or self.frame_counter) > 180
        or (category == 4 and action ~= root and branches[action] == nil
            and self.frame_counter - (self.training_root_frame or self.frame_counter) > 10) then
        M.set_training_state(self, "failed", "目标起手未进入已收录派生")
    end
end

function M.update_training_scenario(self)
    if self.training_state ~= "waiting" and self.training_state ~= "requested"
        and self.training_state ~= "running" and self.training_state ~= "positioning" then return end
    local context = self.model.context or {}
    if not context.in_quest or context.is_online or context.build_supported == false then
        M.set_training_state(self, "unavailable", "任务状态变化，指定出招已取消")
        return
    end
    if self.training_state == "waiting" then
        if self.frame_counter >= self.training_next_request_frame then
            M.issue_training_scenario(self)
        end
        return
    end
    local current = self.runtime:current_action_snapshot() or {}
    if self.training_scenario and self.training_scenario.execution_mode == "natural_condition" then
        M.update_natural_condition_training(self, current)
        return
    end
    if self.training_behavior_tracker and self.runtime.behavior_tree_snapshot then
        self.training_behavior_tracker:sample(self.frame_counter,
            self.runtime:behavior_tree_snapshot(), current)
    end
    local action = self.training_scenario and self.training_scenario.actions
        and tonumber(self.training_scenario.actions[1]) or nil
    if self.training_state == "requested" then
        if tonumber(current.category) == 4 and tonumber(current.action) == action then
            if self.model.rearm_current_action_round then
                self.model:rearm_current_action_round(now(), action)
            end
            self.training_matched_frame = self.frame_counter
            M.set_training_state(self, "running", "怪物正在执行“"
                .. tostring(self.training_scenario.name_zh or self.training_scenario.name) .. "”")
        elseif self.frame_counter - self.training_started_frame > 180 then
            M.set_training_state(self, "failed", "请求后未观察到目标招式；请调整站位后再试")
        end
        return
    end
    local left_requested = tonumber(current.category) ~= 4 or tonumber(current.action) ~= action
    local left_attack_tree = self.training_behavior_tracker
        and self.training_behavior_tracker:attack_cycle_completed_since(self.training_matched_frame)
    if self.frame_counter - (self.training_matched_frame or self.frame_counter) >= 10
        and (left_requested or left_attack_tree) then
        if left_attack_tree and not left_requested
            and self.model.complete_current_action_from_behavior_exit then
            self.model:complete_current_action_from_behavior_exit(now(), action)
        end
        self.training_last_behavior_path = self.training_behavior_tracker
            and self.training_behavior_tracker:result() or nil
        self.training_behavior_tracker = nil
        self.training_completed_rounds = self.training_completed_rounds + 1
        if self.training_completed_rounds >= self.training_target_rounds then
            M.set_training_state(self, "completed", string.format("训练完成：%d/%d",
                self.training_completed_rounds, self.training_target_rounds))
        else
            self.training_next_request_frame = self.frame_counter + 30
            M.set_training_state(self, "waiting", string.format("已完成 %d/%d，等待下一安全空档",
                self.training_completed_rounds, self.training_target_rounds))
        end
    elseif self.frame_counter - (self.training_matched_frame or self.frame_counter) > 900 then
        M.set_training_state(self, "failed", "招式未正常退出；请按 F7 安全重开")
    end
end

function M.guard(self, label, fn)
    local ok, error_message = pcall(fn)
    if ok then return true end
    self.runtime:restore_time_scale()
    self.slowmo_active = false
    self.slowmo_toggled = false
    local current_error = label .. ": " .. tostring(error_message)
    local is_new_error = current_error ~= self.last_error
    self.last_error = current_error
    self.model:fail(self.last_error)
    if is_new_error then log.error("[MHRiseMonsterCoach] " .. self.last_error) end
    return false
end

local function pressed(self, name, code)
    local down = key_down(code)
    local was_down = self.previous_keys[name] == true
    self.previous_keys[name] = down
    return down and not was_down, down
end

function M.update_context(self)
    self.frame_counter = self.frame_counter + 1
    if self.frame_counter % 15 == 1 then
        local previous = self.model.context or {}
        local context = self.runtime:context()
        self.model:set_context(context)
        if context.in_quest ~= true or context.player_found == false
            or previous.in_quest ~= context.in_quest
            or previous.quest_no ~= context.quest_no then
            self.last_health = nil
        end
        self.model:update_player_combat_state(self.runtime:player_combat_state(), now())
    end
end

function M.observe_enemy(self)
    local action, metadata = self.runtime:read_action()
    if action ~= nil then self.model:observe_action(action, now(), metadata) end
    local hitboxes = self.runtime:read_hitboxes()
    if hitboxes ~= nil then self.model:observe_hitboxes(hitboxes) end
    self.model:update_player_combat_state(self.runtime:player_combat_state(), now())
    if self.frame_counter % 30 == 0 and self.runtime.observe_environment_creatures then
        self.runtime:observe_environment_creatures()
    end
end

function M.persist_runtime_evidence(self, force)
    local revision = self.model.evidence_revision or 0
    if revision <= self.saved_evidence_revision then return false end
    if not force and self.frame_counter % 60 ~= 0 then return false end
    self.config_module.write_calibration(
        self.model:export_calibration(self.runtime.reader:description()))
    self.saved_evidence_revision = revision
    return true
end

function M.update_health(self)
    local health = self.runtime:read_player_health()
    if type(health) == "number" and type(self.last_health) == "number" then
        self.model:observe_health_comparison()
        if health < self.last_health and self.model:observe_damage(self.last_health - health) then
            self.config_module.write_calibration(self.model:export_calibration(self.runtime.reader:description()))
        end
    end
    self.last_health = health

    if not self.config.diagnostic_safe_mode and self.config.safety_health_lock
        and self.model.context.in_quest and not self.model.context.is_online then
        self.runtime:restore_player_resources()
    end
    if not self.config.diagnostic_safe_mode and self.config.protect_monster_health and self.frame_counter % 6 == 0
        and self.model.context.in_quest and not self.model.context.is_online then
        self.runtime:restore_monster_health()
    end
end

function M.update_slowmo(self)
    local keyboard_edge = pressed(self, "slowmo", self.config.keys.slowmo_hold)
    local gamepad_held = self.input_state and self.input_state.slowmo_down == true
    if keyboard_edge and not gamepad_held then
        self.slowmo_toggled = not self.slowmo_toggled
        if self.input then self.input:mark_keyboard() end
    end
    local held = self.slowmo_toggled or gamepad_held
    local allowed = self.config.enabled
        and self.config.time_control_enabled == true
        and self.model.context.in_quest
        and self.model.context.build_supported ~= false
        and not self.model.context.is_online
        and self.model.context.target_found
        and not reframework:is_drawing_ui()

    if held and allowed then
        local ok, reason = self.runtime:set_time_scale(self.config.slowmo_scale)
        if ok then
            self.slowmo_active = true
        else
            self.model:fail(reason)
        end
    elseif (not held or not allowed) and self.slowmo_active then
        self.runtime:restore_time_scale()
        self.slowmo_active = false
    end
    if not allowed then self.slowmo_toggled = false end
end

function M.request_native_quest_reset(self)
    if not self.model.context.in_quest or self.model.context.is_online
        or self.model.context.build_supported == false then
        self.reset_status = "Reset unavailable: enter the single-player training quest"
        self.model:reset_round(self.reset_status)
        return false
    end
    local restart = self.runtime.quest_restart
    if restart == nil then
        self.reset_status = "Automatic restart unavailable"
        self.model:reset_round(self.reset_status)
        return false
    end
    if restart:is_active() then return false end
    local ok, reason = restart:start(self.model.context)
    if not ok then
        self.reset_status = "Automatic restart failed: " .. tostring(reason)
        self.model:reset_round(self.reset_status)
        return false
    end
    self.native_reset_requested = true
    self.training_completed_rounds = 0
    self.training_target_rounds = 1
    self.training_behavior_tracker = nil
    self.training_last_behavior_path = nil
    M.set_training_state(self, "idle", "任务重开中，已清除指定招式状态")
    self.restart_state = restart.state
    self.reset_status = restart.status
    self.model:reset_round(self.reset_status)
    if self.runtime.record_quest_restart_state then
        self.runtime:record_quest_restart_state(restart, self.model.context)
    end
    return true
end

function M.update_quest_restart(self)
    local restart = self.runtime.quest_restart
    if restart == nil or not restart:is_active() then return end
    restart:update(self.model.context)
    if self.restart_state ~= restart.state then
        self.restart_state = restart.state
        self.reset_status = restart.status
        self.model:reset_round(self.reset_status)
        if self.runtime.record_quest_restart_state then
            self.runtime:record_quest_restart_state(restart, self.model.context)
        end
    end
    if restart.state == "complete" or restart.state == "failed" then
        self.native_reset_requested = false
    end
end

function M.quick_reset(self)
    local keyboard_edge = pressed(self, "reset", self.config.keys.quick_reset)
    local gamepad_edge = self.input_state and self.input_state.reset_pressed == true
    if keyboard_edge and not gamepad_edge and self.input then self.input:mark_keyboard() end
    local edge = keyboard_edge or gamepad_edge
    if not edge then return end
    if reframework:is_drawing_ui() then return end
    if self.model.context.in_quest then M.request_native_quest_reset(self) end
end

function M.capture_reset_anchor(self)
    local keyboard_edge = pressed(self, "capture", self.config.keys.capture_anchor)
    local gamepad_edge = self.input_state and self.input_state.capture_pressed == true
    if not (keyboard_edge or gamepad_edge) or reframework:is_drawing_ui() then return end
    if keyboard_edge and not gamepad_edge and self.input then self.input:mark_keyboard() end
    local ok, reason = self.runtime:capture_anchors()
    self.reset_status = ok and "Reset point recorded" or ("Reset point failed: " .. tostring(reason))
    self.model:reset_round(self.reset_status)
end

function M.experimental_in_place_reset(self)
    local keyboard_edge = pressed(self, "in_place_reset", self.config.keys.in_place_reset)
    if not keyboard_edge or reframework:is_drawing_ui() then return end
    if self.input then self.input:mark_keyboard() end
    local ok, reason = self.runtime:experimental_native_in_place_reset()
    self.reset_status = ok and "Experimental in-place reset completed"
        or ("Experimental in-place reset failed: " .. tostring(reason))
    if ok then self.model:clear_round_runtime(self.reset_status)
    else self.model:reset_round(self.reset_status) end
end

function M.update(self)
    if self.input then self.input_state = self.input:poll(now()) end
    M.update_context(self)
    if self.model.context.in_quest and self.model.context.build_supported ~= false
        and not self.model.context.is_online then M.observe_enemy(self) end
    M.update_training_scenario(self)
    M.update_slowmo(self)
    M.capture_reset_anchor(self)
    M.experimental_in_place_reset(self)
    M.quick_reset(self)
    M.update_quest_restart(self)
    if self.model.context.in_quest and self.model.context.build_supported ~= false
        and not self.model.context.is_online then M.update_health(self) end
    if self.runtime.persist_action_request_trace then self.runtime:persist_action_request_trace() end
    M.persist_runtime_evidence(self, not self.model.context.in_quest)
end

function M.draw_overlay(self)
    self.view:draw(self.model, self.runtime, self.slowmo_active, self.input_state)
end

local function checkbox(label, config, key)
    local changed, value = imgui.checkbox(label, config[key])
    if changed then config[key] = value end
    return changed
end

local function ui_text_wrapped(text)
    if type(imgui.text_wrapped) == "function" then
        imgui.text_wrapped(text)
    else
        imgui.text(text)
    end
end

function M.draw_training_menu(self)
    imgui.separator()
    imgui.text("Specified Move / 指定出招")
    local changed = checkbox("Enable specified-move training / 启用指定出招",
        self.config, "forced_action_training_enabled")
    ui_text_wrapped("先查看派生树，再选择次数并开始训练。")
    ui_text_wrapped("攻击或判定期间自动等待，不强行打断怪物。")
    imgui.text("Repeat / 次数：" .. tostring(self.config.training_repeat_count))
    for index, count in ipairs({ 1, 3, 5, 10 }) do
        if index > 1 then imgui.same_line() end
        if imgui.button(tostring(count) .. " 次##training_repeat_" .. tostring(count)) then
            self.config.training_repeat_count = count
            changed = true
        end
    end
    local catalog = self.model.training_catalog and self.model:training_catalog()
        or { { id = "legacy", name = "精选起手", scenarios = self.model.scenarios or {} } }
    for _, group in ipairs(catalog) do
        imgui.separator()
        imgui.text(group.name)
        for _, scenario in ipairs(group.scenarios or {}) do
            local verified = scenario.verification and scenario.verification.status == "verified"
            local name = tostring(scenario.name_zh or scenario.name or scenario.id)
            if verified then
                if imgui.button("查看派生树：" .. name .. "##branch_" .. tostring(scenario.id)) then
                    M.preview_training_scenario(self, scenario)
                end
                if self.training_preview_scenario_id == tostring(scenario.id) then
                    if scenario.summary_zh then ui_text_wrapped(scenario.summary_zh) end
                    local presentation = M.training_scenario_presentation(self, scenario)
                    imgui.same_line()
                    if imgui.button(presentation.start_label .. "##" .. tostring(scenario.id)) then
                        M.start_training_scenario(self, scenario)
                    end
                    if presentation.repeat_gate_message then
                        ui_text_wrapped(presentation.repeat_gate_message)
                    end
                end
            end
        end
    end
    local function draw_branch(node, depth, relation)
        if type(node) ~= "table" then return end
        local prefix = string.rep("  ", depth) .. (depth == 0 and "起手: " or "-> ")
        local kind = depth == 0 and "" or ("[" .. tostring(relation or node.kind) .. "] ")
        local suffix = node.cycle and "（循环）" or (node.truncated and "（更多…）" or "")
        ui_text_wrapped(prefix .. kind .. tostring(node.name) .. " [Action "
            .. tostring(node.action) .. "]" .. suffix)
        for _, edge in ipairs(node.candidates or {}) do
            draw_branch(edge.node, depth + 1, node.kind)
        end
        if depth == 0 and #(node.candidates or {}) == 0 then
            ui_text_wrapped("  暂无已验证后续派生；当前按独立单招训练。")
        end
    end
    if self.training_preview_tree ~= nil then
        imgui.text("Branch Tree / 派生树")
        draw_branch(self.training_preview_tree, 0, nil)
    end
    if self.training_state == "waiting" or self.training_state == "requested"
        or self.training_state == "running" or self.training_state == "positioning" then
        imgui.same_line()
        if imgui.button("停止训练##stop_training") then
            M.cancel_training_scenario(self)
        end
    end
    ui_text_wrapped("状态：" .. tostring(self.training_status))
    return changed
end

function M.draw_menu_content(self)
    if not imgui.tree_node("Monster Coach / 怪物陪练") then return end

    local changed = false
    changed = checkbox("Enable / 启用", self.config, "enabled") or changed
    changed = checkbox("Overlay / 场上提示", self.config, "overlay_enabled") or changed
    changed = checkbox("Show move / 显示招式", self.config, "show_move") or changed
    changed = checkbox("Show branches / 显示派生", self.config, "show_prediction") or changed
    changed = checkbox("General move advice / 通用招式应对", self.config, "show_advice") or changed
    changed = checkbox("Weapon skill response (optional) / 武器技能应对（可选）",
        self.config, "weapon_response_extension_enabled") or changed
    changed = checkbox("Round review / 单轮复盘", self.config, "show_timeline_review") or changed
    changed = checkbox("Manual slow motion / 手动子弹时间", self.config, "time_control_enabled") or changed
    changed = M.draw_training_menu(self) or changed
    local shapes_changed = checkbox("HitboxViewer debug shapes / 显示判定体",
        self.config, "show_hitboxviewer_debug_shapes")
    if shapes_changed then
        self.runtime:set_hitboxviewer_debug_shapes(self.config.show_hitboxviewer_debug_shapes)
        changed = true
    end
    changed = checkbox("Controller shortcuts (experimental, may conflict)", self.config.controller_input, "enabled") or changed
    changed = checkbox("Player safety lock (offline only)", self.config, "safety_health_lock") or changed
    changed = checkbox("Protect monster HP (offline only)", self.config, "protect_monster_health") or changed

    local scale_changed, scale = imgui.slider_float("Slow-motion scale", self.config.slowmo_scale, 0.05, 1.0, "%.2fx")
    if scale_changed then self.config.slowmo_scale = scale changed = true end

    imgui.separator()
    imgui.text("State: " .. tostring(self.model.state))
    ui_text_wrapped("Status: " .. tostring(self.model.status))
    imgui.text(string.format("Runtime: %s / TDB %s", tostring(self.model.context.game_name or "unknown"), tostring(self.model.context.tdb_version or "unknown")))
    if self.config.diagnostic_safe_mode then
        ui_text_wrapped(self.config.time_control_enabled
            and (self.config.forced_action_training_enabled
                and "SAFE MODE: polling, guarded slow motion/reset and verified manual training scenarios enabled."
                or "SAFE MODE: polling and guarded slow motion/reset enabled; specified moves require explicit opt-in.")
            or "READ-ONLY MODE: Action/Hitbox polling enabled; all gameplay writes disabled.")
    end
    imgui.text("Target: " .. (self.model.context.target_found
        and ("Tigrex / " .. tostring(self.model.context.enemy_id or "unknown")) or "waiting"))
    if self.font then imgui.text(self.font:diagnostic()) end
    local reader = self.runtime.reader:description()
    imgui.text("Reader: " .. tostring(reader and reader.name or "not calibrated"))
    if reader then imgui.text("Observed Action changes: " .. tostring(reader.changes or 0)) end
    if reader and reader.motion_name then ui_text_wrapped("Engine Motion: " .. reader.motion_name) end
    if reader and reader.action_no then
        ui_text_wrapped(string.format("Action parameter: category %s / no %s", tostring(reader.action_category), tostring(reader.action_no)))
    end
    local player_probe = self.runtime:player_state_probe()
    ui_text_wrapped("Player state probe: " .. tostring(player_probe.status))
    if player_probe.player_type then ui_text_wrapped("Player type: " .. tostring(player_probe.player_type)) end
    local hitbox_provider = self.runtime:hitbox_provider_description()
    ui_text_wrapped("Hitbox timing: " .. tostring(hitbox_provider.status))
    local native_stats = hitbox_provider.primary or {}
    ui_text_wrapped(string.format("Native capture: target requests %d | collidables %d | active edges %d | active frames %d",
        native_stats.target_requests_seen or 0, native_stats.collidables_seen or 0,
        native_stats.active_edges or 0, native_stats.active_frames or 0))
    if hitbox_provider.validation then
        ui_text_wrapped(string.format("Hitbox cross-check: %s | native %d / viewer %d",
            hitbox_provider.validation.matches and "match" or "mismatch",
            hitbox_provider.validation.native_active_count,
            hitbox_provider.validation.validator_active_count))
    end
    local validation_stats = hitbox_provider.validation_stats
    if validation_stats and validation_stats.samples > 0 then
        ui_text_wrapped(string.format("Cross-check history: samples %d | mismatches %d | matched active %d | max %d/%d",
            validation_stats.samples, validation_stats.mismatches,
            validation_stats.matched_active, validation_stats.max_native,
            validation_stats.max_validator))
    end
    local window_summary = self.model:hitbox_window_summary()
    ui_text_wrapped(string.format("Automatic hitbox windows: actions %d | observations %d | confirmed %d | variable %d",
        window_summary.actions, window_summary.observations,
        window_summary.confirmed, window_summary.variable))
    if self.input then
        local input = self.input:description()
        ui_text_wrapped(string.format("Controller shortcuts: %s | runtime %s | active %s",
            input.enabled and "enabled" or "disabled",
            input.available and "ready" or "unavailable", tostring(input.device)))
    end
    imgui.text("Observed state changes: " .. tostring(self.model.state_changes))
    ui_text_wrapped("One-key restart: " .. tostring(self.reset_status))
    if self.model.context.outcome_tracking then
        imgui.text(string.format("Rounds %d | Success %d | Hit %d", self.model.rounds, self.model.successes, self.model.failures))
    else
        imgui.text("Outcome: unavailable in read-only mode")
    end

    local training_quest = self.model.profile.training_quest
    if training_quest then
        imgui.separator()
        imgui.text("Training Quest / 陪练任务")
        ui_text_wrapped(training_quest.name_zh .. "  |  Quest ID " .. tostring(training_quest.id))
        imgui.text("Map: " .. training_quest.map_name)
        if self.model.context.in_quest then
            local active = tonumber(self.model.context.quest_no) == training_quest.id
            imgui.text(active and "Active: training quest selected" or ("Active Quest ID: " .. tostring(self.model.context.quest_no or "unknown")))
        else
            ui_text_wrapped("Select at: " .. training_quest.menu_path .. ". RiseQuestLoader is required; restart the game after installing the quest file.")
        end
    end

    local restart = self.runtime.quest_restart
    local f7_label = restart and restart:is_active()
        and ("Restarting: " .. tostring(restart.status)) or "Restart training quest once (F7)"
    if imgui.button(f7_label) then
        if self.model.context.in_quest then M.request_native_quest_reset(self) end
    end
    if imgui.button("Record reset point (F8)") then
        local ok, reason = self.runtime:capture_anchors()
        self.reset_status = ok and "Reset point recorded" or ("Reset point failed: " .. tostring(reason))
        self.model:reset_round(self.reset_status)
    end
    imgui.same_line()
    if imgui.button("In-place reset disabled after crash evidence (F9)") then
        local ok, reason = self.runtime:experimental_native_in_place_reset()
        self.reset_status = ok and "Experimental in-place reset completed"
            or ("Experimental in-place reset failed: " .. tostring(reason))
        if ok then self.model:clear_round_runtime(self.reset_status)
        else self.model:reset_round(self.reset_status) end
    end

    if imgui.button("Export calibration evidence") then
        self.config_module.write_calibration(self.model:export_calibration(self.runtime.reader:description()))
        self.model:reset_round("Calibration evidence exported")
    end
    imgui.same_line()
    if imgui.button("Reload static AI data") then
        local loaded = self.config_module.load_static_ai()
        if self.model:reload_static_ai(loaded) then
            self.model.status = "Static AI data reloaded"
        else
            self.model:fail("Static AI data is invalid")
        end
    end

    if #self.model.scenarios == 0 then
        ui_text_wrapped("Forced moves are locked until a verified Tigrex Action map and safe request method are captured on this game build.")
    end

    if changed then self.config_module.save(self.config) end
    imgui.tree_pop()
end

function M.draw_menu(self)
    local font_pushed = self.font and self.font:push() or false
    local ok, error_message = pcall(M.draw_menu_content, self)
    if self.font then self.font:pop(font_pushed) end
    if not ok then error(error_message) end
end

function M.shutdown(self)
    self.model:finalize_hitbox_observation()
    M.persist_runtime_evidence(self, true)
    self.runtime:shutdown()
    self.slowmo_active = false
    self.slowmo_toggled = false
end

return M
