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
        last_health = nil,
        last_error = nil,
        frame_counter = 0,
        input = input_adapter,
        input_state = { available = false, device = "keyboard" },
    }, { __index = M })
end

function M.guard(self, label, fn)
    local ok, error_message = pcall(fn)
    if ok then return true end
    self.runtime:restore_time_scale()
    self.slowmo_active = false
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

local function writes_allowed(self)
    return self.model.context.in_quest
        and not self.config.diagnostic_safe_mode
        and self.model.context.build_supported ~= false
        and not self.model.context.is_online
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
    self.model:update_player_combat_state(self.runtime:player_combat_state())
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
    local _, keyboard_held = pressed(self, "slowmo", self.config.keys.slowmo_hold)
    local gamepad_held = self.input_state and self.input_state.slowmo_down == true
    if keyboard_held and not gamepad_held and self.input then self.input:mark_keyboard() end
    local held = keyboard_held or gamepad_held
    local allowed = self.config.enabled
        and not self.config.diagnostic_safe_mode
        and self.model.context.in_quest
        and self.model.context.build_supported ~= false
        and not self.model.context.is_online
        and self.model.context.target_found
        and not reframework:is_drawing_ui()

    if held and allowed and not self.slowmo_active then
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
end

function M.capture_anchors(self)
    local keyboard_edge = pressed(self, "capture", self.config.keys.capture_anchor)
    local gamepad_edge = self.input_state and self.input_state.capture_pressed == true
    if keyboard_edge and not gamepad_edge and self.input then self.input:mark_keyboard() end
    local edge = keyboard_edge or gamepad_edge
    if not edge then return end
    if reframework:is_drawing_ui() then return end
    if not writes_allowed(self) then return end
    local ok, reason = self.runtime:capture_anchors()
    self.model:reset_round(ok and "Reset anchors captured" or reason)
end

function M.quick_reset(self)
    local keyboard_edge = pressed(self, "reset", self.config.keys.quick_reset)
    local gamepad_edge = self.input_state and self.input_state.reset_pressed == true
    if keyboard_edge and not gamepad_edge and self.input then self.input:mark_keyboard() end
    local edge = keyboard_edge or gamepad_edge
    if not edge then return end
    if reframework:is_drawing_ui() then return end
    if not writes_allowed(self) then return end
    local ok, reason = self.runtime:quick_reset()
    self.slowmo_active = false
    self.model:reset_round(ok and "Round reset in place" or reason)
end

function M.update(self)
    if self.input then self.input_state = self.input:poll(now()) end
    M.update_context(self)
    if self.model.context.in_quest and self.model.context.build_supported ~= false
        and not self.model.context.is_online then M.observe_enemy(self) end
    M.update_slowmo(self)
    M.capture_anchors(self)
    M.quick_reset(self)
    if self.model.context.in_quest and self.model.context.build_supported ~= false
        and not self.model.context.is_online then M.update_health(self) end
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
        ui_text_wrapped("READ-ONLY MODE: polling can identify Tigrex and read whitelisted Action members; time, health and position writes remain disabled.")
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
    if self.input then
        local input = self.input:description()
        ui_text_wrapped(string.format("Controller shortcuts: %s | runtime %s | active %s",
            input.enabled and "enabled" or "disabled",
            input.available and "ready" or "unavailable", tostring(input.device)))
    end
    imgui.text("Observed state changes: " .. tostring(self.model.state_changes))
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

    if imgui.button("Capture reset anchors (F8)") then
        if writes_allowed(self) then
            local ok, reason = self.runtime:capture_anchors()
            self.model:reset_round(ok and "Reset anchors captured" or reason)
        else
            self.model:reset_round("Unavailable: requires a supported single-player quest")
        end
    end
    imgui.same_line()
    if imgui.button("Reset round now (F7)") then
        if writes_allowed(self) then
            local ok, reason = self.runtime:quick_reset()
            self.model:reset_round(ok and "Round reset in place" or reason)
        else
            self.model:reset_round("Unavailable: requires a supported single-player quest")
        end
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
    self.runtime:shutdown()
    self.slowmo_active = false
end

return M
