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
    }, { __index = M })
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
        self.model:set_context(self.runtime:context())
        self.model:update_player_combat_state(self.runtime:player_combat_state())
    end
end

function M.observe_enemy(self)
    local action, metadata = self.runtime:read_action()
    if action ~= nil then self.model:observe_action(action, now(), metadata) end
    local hitboxes = self.runtime:read_hitboxes()
    if hitboxes ~= nil then self.model:observe_hitboxes(hitboxes) end
    self.model:update_player_combat_state(self.runtime:player_combat_state())
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
    if type(health) == "number" and type(self.last_health) == "number" and health < self.last_health then
        if self.model:observe_damage(self.last_health - health) then
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
    M.update_slowmo(self)
    M.capture_reset_anchor(self)
    M.experimental_in_place_reset(self)
    M.quick_reset(self)
    M.update_quest_restart(self)
    if self.model.context.in_quest and self.model.context.build_supported ~= false
        and not self.model.context.is_online then M.update_health(self) end
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

function M.draw_menu_content(self)
    if not imgui.tree_node("Monster Coach / 怪物陪练") then return end

    local changed = false
    changed = checkbox("Enable / 启用", self.config, "enabled") or changed
    changed = checkbox("Overlay / 场上提示", self.config, "overlay_enabled") or changed
    changed = checkbox("Show move / 显示招式", self.config, "show_move") or changed
    changed = checkbox("Show branches / 显示派生", self.config, "show_prediction") or changed
    changed = checkbox("Show response / 显示应对", self.config, "show_advice") or changed
    changed = checkbox("Manual slow motion / 手动子弹时间", self.config, "time_control_enabled") or changed
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
            and "SAFE MODE: polling, guarded slow motion and manual quick reset enabled; continuous writes and forced actions remain locked."
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
    if imgui.button("Experimental in-place reset (F9)") then
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
