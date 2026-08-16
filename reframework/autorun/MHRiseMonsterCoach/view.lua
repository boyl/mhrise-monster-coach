local M = {}

local COLORS = {
    panel = 0xDC10141A,
    border = 0xFF8A9AAA,
    title = 0xFFFFFFFF,
    text = 0xFFE2E8F0,
    muted = 0xFF9AA7B5,
    success = 0xFF72D99B,
    failure = 0xFF719DFF,
    warning = 0xFF70D6FF,
    disabled = 0xFF808080,
}

local function truncate(text, max_chars)
    text = tostring(text or "")
    local offsets = {}
    for offset in string.gmatch(text, "()[\0-\127\194-\244]") do offsets[#offsets + 1] = offset end
    if #offsets <= max_chars then return text end
    return string.sub(text, 1, offsets[max_chars - 2] - 1) .. "..."
end

local function result_color(state)
    if state == "success" then return COLORS.success end
    if state == "failure" or state == "error" then return COLORS.failure end
    if state == "disabled" then return COLORS.disabled end
    return COLORS.warning
end

local function prediction_text(prediction)
    if prediction == nil or #prediction.candidates == 0 then return "Next: collecting branch samples" end
    local pieces = {}
    for index = 1, math.min(3, #prediction.candidates) do
        local item = prediction.candidates[index]
        local suffix = ""
        if item.condition then suffix = " if " .. tostring(item.condition) end
        if item.probability then suffix = string.format(" %.0f%%", item.probability * 100) end
        pieces[#pieces + 1] = tostring(item.name) .. suffix
    end
    local prefix = prediction.kind == "fixed" and "Next (fixed): " or "Next (candidate): "
    return prefix .. table.concat(pieces, " / ")
end

local function response_text(model)
    for _, item in ipairs(model.response_candidates or {}) do
        if item.availability == "available" then
            return string.format("Weapon response: %s", tostring(item.name))
        end
    end
    if model.response_error == "unsupported_weapon" then return nil end
    return "Weapon response: current weapon state is incomplete"
end

local function loadout_text(model)
    local state = model.player_combat_state
    if not state or state.weapon_type ~= "long_sword" then return nil end
    local scroll = state.active_scroll
    local skills = state.switch_skills and state.switch_skills[scroll]
    if scroll ~= "red" and scroll ~= "blue" then return "Long Sword loadout: active scroll unknown" end
    if type(skills) ~= "table" or #skills ~= 5 then
        return string.format("Long Sword loadout: %s scroll | unresolved", scroll)
    end
    return string.format("Long Sword loadout: %s scroll | 5/5 skills resolved", scroll)
end

local PHASE_NAMES = {
    startup = "前摇",
    active = "判定中",
    recovery = "收招",
    unknown = "阶段未知",
}

local function phase_text(model)
    local state = model:coaching_state()
    local text = "Phase / 阶段: " .. (PHASE_NAMES[state.phase] or tostring(state.phase))
    if state.frames_to_next_active then
        text = text .. string.format("  |  距下一判定 %.1f 帧", state.frames_to_next_active)
    elseif state.phase == "recovery" and state.frames_from_final_active then
        text = text .. string.format("  |  判定结束 %.1f 帧", math.max(0, state.frames_from_final_active))
    end
    return text, state.phase
end

function M.new(config, font)
    return setmetatable({ config = config, font = font }, { __index = M })
end

function M.draw(self, model, runtime, slowmo_active, input_state)
    if not self.config.overlay_enabled then return end
    if not model.context.in_quest and model.state ~= "error" then return end

    local screen_width, screen_height = runtime:screen_size()
    local width = math.floor(math.max(360, math.min(720, screen_width * 0.42)))
    local x = math.floor((screen_width - width) / 2)
    local y = math.floor(math.max(18, screen_height * 0.025))

    local lines = {}
    lines[#lines + 1] = { "MONSTER COACH  |  " .. model.profile.name, COLORS.title }
    lines[#lines + 1] = { truncate(model.status, 88), result_color(model.state) }
    if model.context.in_quest then
        local target = model.context.target_found
            and ("Target: Tigrex detected  |  Enemy ID " .. tostring(model.context.enemy_id or "unknown"))
            or "Target: waiting for Tigrex"
        lines[#lines + 1] = { target, model.context.target_found and COLORS.success or COLORS.muted }
    end

    if self.config.show_move and model.current_move then
        lines[#lines + 1] = { "Move: " .. truncate(model.current_move.name, 74), COLORS.text }
        local progress = model.context.outcome_tracking
            and string.format("Round %d  |  Streak %d", model.rounds + 1, model.streak)
            or string.format("Observed changes %d", model.state_changes)
        lines[#lines + 1] = { string.format("State key: %s  |  %s", model.current_state_key or model.current_action, progress), COLORS.muted }
        local metadata = model.current_metadata
        if metadata and type(metadata.current_frame) == "number" and type(metadata.end_frame) == "number"
            and metadata.end_frame > 0 then
            lines[#lines + 1] = {
                string.format("Animation: %.1f / %.1f  |  %.0f%%", metadata.current_frame, metadata.end_frame, (metadata.motion_progress or 0) * 100),
                COLORS.muted,
            }
        end
    end
    if self.config.show_prediction and model.current_action then
        lines[#lines + 1] = { truncate(prediction_text(model.prediction), 88), COLORS.text }
    end
    if model.current_action then
        local phase_line, phase = phase_text(model)
        lines[#lines + 1] = { phase_line, phase == "active" and COLORS.warning
            or (phase == "recovery" and COLORS.success or COLORS.text) }
    end
    if self.config.show_advice and model.current_move then
        local threat = model.current_move.threat
        if threat then
            lines[#lines + 1] = { "Threat / 威胁: " .. truncate(threat.direction, 30)
                .. "  →  " .. truncate(threat.response, 42), COLORS.warning }
        end
        lines[#lines + 1] = { "Response: " .. truncate(model.current_move.advice, 76), COLORS.text }
        local weapon_response = response_text(model)
        if weapon_response then lines[#lines + 1] = { truncate(weapon_response, 88), COLORS.text } end
    end
    local loadout = loadout_text(model)
    if loadout then lines[#lines + 1] = { loadout, COLORS.muted } end
    if model.context.outcome_tracking and model.last_result then
        lines[#lines + 1] = { "Last: " .. truncate(model.last_result, 82), result_color(model.state) }
    end

    local controls
    if model.context.build_supported == false then
        controls = string.format("Read-only runtime: %s / TDB %s", tostring(model.context.game_name), tostring(model.context.tdb_version))
    elseif model.context.is_online then
        controls = "Multiplayer detected: all gameplay controls disabled"
    elseif slowmo_active then
        controls = input_state and input_state.device == "gamepad"
            and string.format("Release shoulder buttons: 1.00x | ACTIVE %.2fx", self.config.slowmo_scale)
            or string.format("Press F6: 1.00x  |  ACTIVE %.2fx", self.config.slowmo_scale)
    elseif not self.config.time_control_enabled then
        controls = model.context.safe_mode
            and "READ-ONLY: Action/Hitbox polling on; gameplay writes off"
            or "Manual slow motion disabled in Monster Coach menu"
    elseif input_state and input_state.available and input_state.device == "gamepad" then
        controls = "Hold LB+RB/L1+R1: slow | L3+R3 tap: anchors | hold: reset"
    elseif model.context.safe_mode then
        controls = "Press F6: toggle slow time | health/position/forced actions locked"
    else
        controls = "Press F6: toggle slow time  |  F7: reset round  |  F8: capture anchors"
    end
    lines[#lines + 1] = { controls, slowmo_active and COLORS.warning or COLORS.muted }

    local font_pushed = self.font and self.font:push() or false
    local line_height = self.font and self.font.line_height or 19
    local padding = 12
    local height = padding * 2 + line_height * #lines
    draw.filled_rect(x, y, width, height, COLORS.panel)
    draw.outline_rect(x, y, width, height, COLORS.border)
    for index, line in ipairs(lines) do
        draw.text(line[1], x + padding, y + padding + (index - 1) * line_height, line[2])
    end
    if self.font then self.font:pop(font_pushed) end
end

return M
