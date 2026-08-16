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
    if #text <= max_chars then return text end
    return string.sub(text, 1, max_chars - 3) .. "..."
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

function M.new(config)
    return setmetatable({ config = config }, { __index = M })
end

function M.draw(self, model, runtime, slowmo_active)
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
        lines[#lines + 1] = { string.format("State key: %s  |  %s", model.current_action, progress), COLORS.muted }
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
    if self.config.show_advice and model.current_move then
        lines[#lines + 1] = { "Response: " .. truncate(model.current_move.advice, 76), COLORS.text }
    end
    if model.context.outcome_tracking and model.last_result then
        lines[#lines + 1] = { "Last: " .. truncate(model.last_result, 82), result_color(model.state) }
    end

    local controls
    if model.context.safe_mode then
        controls = "READ-ONLY: Action polling on; time/health/position writes off"
    elseif model.context.build_supported == false then
        controls = string.format("Read-only runtime: %s / TDB %s", tostring(model.context.game_name), tostring(model.context.tdb_version))
    elseif model.context.is_online then
        controls = "Multiplayer detected: all gameplay controls disabled"
    elseif slowmo_active then
        controls = string.format("F6 release: 1.00x  |  ACTIVE %.2fx", self.config.slowmo_scale)
    else
        controls = "Hold F6: slow time  |  F7: reset round  |  F8: capture anchors"
    end
    lines[#lines + 1] = { controls, slowmo_active and COLORS.warning or COLORS.muted }

    local line_height = 19
    local padding = 12
    local height = padding * 2 + line_height * #lines
    draw.filled_rect(x, y, width, height, COLORS.panel)
    draw.outline_rect(x, y, width, height, COLORS.border)
    for index, line in ipairs(lines) do
        draw.text(line[1], x + padding, y + padding + (index - 1) * line_height, line[2])
    end
end

return M
