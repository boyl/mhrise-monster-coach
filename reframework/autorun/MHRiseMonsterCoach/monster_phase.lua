local M = {}

local function finite_number(value)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
end

function M.resolve(move, metadata)
    if type(move) ~= "table" or type(metadata) ~= "table" then return "unknown", "missing_context" end
    local timing = move.timing
    if type(timing) ~= "table" or timing.status ~= "confirmed" then
        return "unknown", "timing_unconfirmed"
    end
    if timing.motion_name and timing.motion_name ~= metadata.motion_name then
        return "unknown", "motion_mismatch"
    end
    if type(timing.active_windows) ~= "table" or #timing.active_windows == 0 then
        return "unknown", "active_windows_missing"
    end

    local unit = timing.unit or "frame"
    local current = unit == "progress" and finite_number(metadata.motion_progress)
        or finite_number(metadata.current_frame)
    if current == nil then return "unknown", "position_unavailable" end

    local first_start, last_end = nil, nil
    for _, window in ipairs(timing.active_windows) do
        local start_value = finite_number(window.start_value or window.start_frame or window.start_progress)
        local end_value = finite_number(window.end_value or window.end_frame or window.end_progress)
        if start_value == nil or end_value == nil or end_value < start_value then
            return "unknown", "invalid_active_window"
        end
        first_start = first_start and math.min(first_start, start_value) or start_value
        last_end = last_end and math.max(last_end, end_value) or end_value
    end

    if current < first_start then return "startup", "confirmed_timing" end
    if current <= last_end then return "active", "confirmed_timing" end
    return "recovery", "confirmed_timing"
end

return M
