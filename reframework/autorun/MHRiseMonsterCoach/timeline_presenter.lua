local M = {}

local OUTCOMES = {
    hit = { label = "受击", tone = "failure" },
    observed_hit = { label = "观察到受击", tone = "failure" },
    no_damage = { label = "无伤", tone = "success" },
    unclassified = { label = "结果待分类", tone = "muted" },
    interrupted = { label = "动作中断", tone = "muted" },
}

local function frame_text(value)
    value = tonumber(value)
    if value == nil then return "?" end
    if value == math.floor(value) then return tostring(math.floor(value)) end
    return string.format("%.1f", value)
end

local function hitbox_windows(events)
    local windows, opened = {}, nil
    for _, event in ipairs(events or {}) do
        local data = event.data or {}
        if event.kind == "hitbox_open" then
            opened = tonumber(data.motion_frame)
        elseif event.kind == "hitbox_close" then
            local first = opened
            local last = tonumber(data.last_active_frame) or tonumber(data.motion_frame)
            if first ~= nil or last ~= nil then
                windows[#windows + 1] = { first = first, last = last }
            end
            opened = nil
        end
    end
    if opened ~= nil then windows[#windows + 1] = { first = opened, last = nil } end
    return windows
end

local function windows_text(windows)
    if #windows == 0 then return "判定未采集" end
    local parts = {}
    for index = 1, math.min(2, #windows) do
        local window = windows[index]
        parts[#parts + 1] = frame_text(window.first) .. "–" .. frame_text(window.last) .. "帧"
    end
    if #windows > 2 then parts[#parts + 1] = "+" .. tostring(#windows - 2) .. "段" end
    return "判定 " .. table.concat(parts, "/")
end

local function player_action_text(events)
    local latest_attempt, latest_success = nil, nil
    local latest_status = nil
    for _, event in ipairs(events or {}) do
        if event.kind == "player_action" then
            local data = event.data or {}
            if data.role == "success" then latest_success = data
            elseif data.role == "attempt" then latest_attempt = data end
        elseif event.kind == "player_status" then
            local data = event.data or {}
            if data.guard == true then latest_status = "防御(动作状态)"
            elseif data.escape == true then latest_status = "回避(动作状态)" end
        end
    end
    local action = latest_success or latest_attempt
    if action == nil then return latest_status end
    local suffix = latest_success and "成功节点" or "尝试节点"
    return tostring(action.name or action.semantic or "猎人动作") .. "(" .. suffix .. ")"
end

function M.summarize(round)
    if type(round) ~= "table" or type(round.events) ~= "table" then return nil end
    local action_name, action = nil, nil
    for _, event in ipairs(round.events) do
        if event.kind == "action_start" then
            local data = event.data or {}
            action_name = data.move_name
            action = data.action
            break
        end
    end
    local move = action_name or (action and ("Action " .. tostring(action))) or "未知招式"
    local classification = type(round.classification) == "table" and round.classification or nil
    local outcome = classification or OUTCOMES[round.outcome]
        or { label = tostring(round.outcome or "结果待分类"), tone = "muted" }
    local text = "复盘: " .. tostring(move) .. " | "
        .. windows_text(hitbox_windows(round.events)) .. " | " .. outcome.label
    if classification and type(classification.timing) == "table" and classification.timing.label then
        text = text .. " | 时机 " .. tostring(classification.timing.label)
        if classification.timing.assessment == "possibly_late" then text = text .. "（可能偏晚）" end
    end
    local player_action = player_action_text(round.events)
    if player_action ~= nil then text = text .. " | 应对 " .. player_action end
    if tonumber(round.dropped_events) and tonumber(round.dropped_events) > 0 then
        text = text .. " | 事件不完整"
    end
    return { text = text, tone = outcome.tone, round_id = round.round_id }
end

return M
