local M = {}
local TimelinePresenter = require("MHRiseMonsterCoach.timeline_presenter")

local COLORS = {
    panel = 0xE61B1E20,
    panel_detail = 0xD9111417,
    border = 0xFFB7A47A,
    coach = 0xFF76D7E8,
    title = 0xFFF4ECD8,
    text = 0xFFEAE4D5,
    muted = 0xFFA9A69D,
    success = 0xFF72D99B,
    failure = 0xFF719DFF,
    warning = 0xFF70D6FF,
}

local PRIORITY = {
    always = 0,
    core = 10,
    result = 20,
    detail = 30,
}

local function truncate(text, max_chars)
    text = tostring(text or "")
    local offsets = {}
    for offset in string.gmatch(text, "()[\0-\127\194-\244]") do offsets[#offsets + 1] = offset end
    if #offsets <= max_chars then return text end
    return string.sub(text, 1, offsets[max_chars - 2] - 1) .. "..."
end

local function measured_width(text)
    if type(imgui) ~= "table" or type(imgui.calc_text_size) ~= "function" then return nil end
    local ok, size = pcall(imgui.calc_text_size, text)
    if not ok or size == nil then return nil end
    local value_ok, width = pcall(function() return size.x end)
    if value_ok and type(width) == "number" then return width end
    if type(size) == "table" and type(size[1]) == "number" then return size[1] end
    return nil
end

local function fit_text(text, max_width)
    text = tostring(text or "")
    local width = measured_width(text)
    if width == nil or width <= max_width then return text end
    local offsets = {}
    for offset in string.gmatch(text, "()[\0-\127\194-\244]") do offsets[#offsets + 1] = offset end
    local low, high, best = 4, #offsets, "..."
    while low <= high do
        local middle = math.floor((low + high) / 2)
        local candidate = truncate(text, middle)
        local candidate_width = measured_width(candidate)
        if candidate_width ~= nil and candidate_width <= max_width then
            best = candidate
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return best
end

local function result_color(state)
    if state == "success" then return COLORS.success end
    if state == "failure" or state == "error" then return COLORS.failure end
    if state == "disabled" then return COLORS.disabled end
    return COLORS.warning
end

local function prediction_text(prediction)
    if prediction == nil or #prediction.candidates == 0 then return nil end
    local pieces = {}
    for index = 1, math.min(3, #prediction.candidates) do
        local item = prediction.candidates[index]
        local suffix = ""
        if item.condition then suffix = " if " .. tostring(item.condition) end
        if item.probability then suffix = string.format(" %.0f%%", item.probability * 100) end
        pieces[#pieces + 1] = tostring(item.name) .. suffix
    end
    local prefixes = {
        fixed = "固定派生：",
        conditional = "条件派生：",
        random = "随机候选：",
        observed = "观测候选：",
        observed_single = "观测候选：",
        observed_candidates = "观测候选：",
        unresolved = "待确认派生：",
    }
    local prefix = prefixes[prediction.kind] or "待确认派生："
    return prefix .. table.concat(pieces, " / ")
end

local function response_text(model)
    for _, item in ipairs(model.response_candidates or {}) do
        if item.availability == "available" then
            return string.format("武器应对：%s", tostring(item.name))
        end
    end
    if model.response_error == "unsupported_weapon" then return nil end
    return "武器应对：当前武器状态尚未完整识别"
end

local PHASE_NAMES = {
    startup = "前摇",
    active = "判定中",
    recovery = "收招",
    unknown = "阶段未知",
}

function M.new(config, font)
    return setmetatable({
        config = config,
        font = font,
        timeline_revision = -1,
        timeline_review = nil,
        last_layout = nil,
    }, { __index = M })
end

local function fit_line_budget(lines, max_lines)
    if #lines <= max_lines then return lines end
    local ranked = {}
    for index, line in ipairs(lines) do
        ranked[#ranked + 1] = { index = index, priority = tonumber(line[3]) or PRIORITY.detail }
    end
    table.sort(ranked, function(left, right)
        if left.priority == right.priority then return left.index < right.index end
        return left.priority < right.priority
    end)
    local selected = {}
    for index = 1, max_lines do selected[ranked[index].index] = true end
    local result = {}
    for index, line in ipairs(lines) do
        if selected[index] then result[#result + 1] = line end
    end
    return result
end

function M.layout_snapshot(self)
    return self.last_layout
end

local function latest_timeline_review(self, model)
    if type(model.training_timeline_revision) ~= "function"
        or type(model.training_timeline_snapshot) ~= "function" then return nil end
    local revision = model:training_timeline_revision()
    if revision ~= self.timeline_revision then
        self.timeline_revision = revision
        local snapshot = model:training_timeline_snapshot()
        self.timeline_review = TimelinePresenter.summarize(snapshot and snapshot.last_round or nil)
    end
    return self.timeline_review
end

function M.draw(self, model, runtime, slowmo_active, input_state)
    if not self.config.overlay_enabled then return end
    if not model.context.in_quest and model.state ~= "error" then return end

    local screen_width, screen_height = runtime:screen_size()
    local width = math.floor(math.max(360, math.min(660, screen_width * 0.52)))
    local x = math.floor((screen_width - width) / 2)
    local y = math.floor(math.max(22, screen_height * 0.065))
    local padding, accent_width = 14, 5
    local body_height = self.font and self.font.line_height or 19
    local cue_height = self.font and self.font.cue_line_height or 28
    local content_width = width - padding * 2 - accent_width
    local rendered_text, rendered_widths = {}, {}
    local horizontal_overflow = false

    local phase_name, phase = nil, "unknown"
    if model.current_action then
        local state = model:coaching_state()
        phase = state.phase or "unknown"
        phase_name = PHASE_NAMES[phase] or tostring(phase)
    end
    -- The move cue is the overlay's primary purpose. Keep reading legacy show_move
    -- config files, but do not let a removed toggle leave the core cue invisible.
    local cue_visible = model.current_move ~= nil
    local cue_panel_height = 0
    if cue_visible then
        cue_panel_height = padding * 2 + body_height + cue_height + 4
        draw.filled_rect(x, y, width, cue_panel_height, COLORS.panel)
        draw.filled_rect(x, y, accent_width, cue_panel_height, COLORS.coach)
        draw.outline_rect(x, y, width, cue_panel_height, COLORS.border)
        local body_pushed = self.font and self.font:push() or false
        local label = "陪练预警  ·  " .. tostring(model.profile.name or "目标怪物")
        label = fit_text(label, content_width)
        draw.text(label, x + padding + accent_width, y + padding,
            COLORS.coach)
        if phase_name then
            local phase_label = "[" .. phase_name .. "]"
            local phase_width = measured_width(phase_label) or 0
            draw.text(phase_label, x + width - padding - phase_width, y + padding,
                phase == "active" and COLORS.warning
                    or (phase == "recovery" and COLORS.success or COLORS.muted))
        end
        rendered_text[#rendered_text + 1] = label
        rendered_widths[#rendered_widths + 1] = measured_width(label)
        if self.font then self.font:pop(body_pushed) end
        local cue_pushed = self.font and self.font:push("cue") or false
        local move_name = fit_text(tostring(model.current_move.name or "未收录动作"), content_width)
        draw.text(move_name, x + padding + accent_width, y + padding + body_height + 4,
            COLORS.title)
        rendered_text[#rendered_text + 1] = move_name
        rendered_widths[#rendered_widths + 1] = measured_width(move_name)
        if self.font then self.font:pop(cue_pushed) end
    end

    local lines = {}
    if self.config.show_prediction and model.current_action and model.prediction
        and #(model.prediction.candidates or {}) > 0 then
        lines[#lines + 1] = { truncate(prediction_text(model.prediction), 88), COLORS.text,
            PRIORITY.core }
    end
    if self.config.show_advice and model.current_move and model.current_move.advice then
        lines[#lines + 1] = { "应对：" .. truncate(model.current_move.advice, 76), COLORS.text,
            PRIORITY.result }
        if self.config.weapon_response_extension_enabled == true then
            local weapon_response = response_text(model)
            if weapon_response then lines[#lines + 1] = {
                truncate(weapon_response, 88), COLORS.coach, PRIORITY.detail } end
        end
    end
    if self.config.show_timeline_review then
        local review = latest_timeline_review(self, model)
        if review then lines[#lines + 1] = { review.text, COLORS[review.tone] or COLORS.muted,
            PRIORITY.result } end
    end
    local training = model.training_scenario
    if type(training) == "table" and training.state ~= "idle" then
        local label = training.name and ("训练 · " .. tostring(training.name) .. "：") or "训练："
        local round_text = type(training.completed_rounds) == "number" and type(training.target_rounds) == "number"
            and string.format("%d/%d", training.completed_rounds, training.target_rounds) or nil
        local progress = round_text and not string.find(tostring(training.status or ""), round_text, 1, true)
            and (" [" .. round_text .. "]") or ""
        lines[#lines + 1] = { truncate(label .. tostring(training.status or training.state) .. progress, 88),
            result_color(training.state == "completed" and "success"
                or (training.state == "failed" and "failure" or "running")), PRIORITY.core }
    end
    if slowmo_active then
        lines[#lines + 1] = { string.format("子弹时间  %.2fx", self.config.slowmo_scale),
            COLORS.warning, PRIORITY.always }
    end

    local detail_y = y + cue_panel_height + (cue_visible and 6 or 0)
    local bottom_margin = 18
    local available_height = math.max(body_height + padding * 2,
        screen_height - detail_y - bottom_margin)
    local max_lines = math.max(1, math.floor((available_height - padding * 2) / body_height))
    local raw_line_count = #lines
    lines = fit_line_budget(lines, max_lines)
    local detail_height = #lines > 0 and (padding * 2 + body_height * #lines) or 0
    local font_pushed = self.font and self.font:push() or false
    for index, line in ipairs(lines) do
        local text = fit_text(line[1], width - padding * 2)
        rendered_text[#rendered_text + 1] = text
        local measured = measured_width(text)
        rendered_widths[#rendered_widths + 1] = measured
        if type(measured) == "number" and measured > width - padding * 2 then
            horizontal_overflow = true
        end
    end
    if #lines > 0 then
        draw.filled_rect(x, detail_y, width, detail_height, COLORS.panel_detail)
        draw.outline_rect(x, detail_y, width, detail_height, COLORS.border)
        for index, line in ipairs(lines) do
            draw.text(rendered_text[(cue_visible and 2 or 0) + index],
                x + padding, detail_y + padding + (index - 1) * body_height, line[2])
        end
    end
    if self.font then self.font:pop(font_pushed) end
    local total_height = cue_panel_height + (cue_visible and #lines > 0 and 6 or 0) + detail_height
    self.last_layout = {
        screen_width = screen_width,
        screen_height = screen_height,
        x = x,
        y = y,
        width = width,
        height = total_height,
        bottom = y + total_height,
        bottom_margin = bottom_margin,
        content_width = content_width,
        line_height = body_height,
        cue_line_height = cue_height,
        cue_visible = cue_visible,
        detail_line_count = #lines,
        line_count = #rendered_text,
        raw_line_count = raw_line_count + (cue_visible and 2 or 0),
        clipped_line_count = raw_line_count - #lines,
        max_lines = max_lines,
        text = rendered_text,
        text_widths = rendered_widths,
        horizontal_overflow = horizontal_overflow,
        vertical_overflow = y + total_height > screen_height - bottom_margin,
        font = {
            ready = self.font and self.font.ready == true or false,
            path = self.font and self.font.path or nil,
            sample_width = self.font and self.font.sample_width or nil,
            diagnostic = self.font and self.font:diagnostic() or "default font",
        },
    }
end

return M
