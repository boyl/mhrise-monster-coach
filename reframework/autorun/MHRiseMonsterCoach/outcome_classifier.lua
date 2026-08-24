local M = {}

local VERIFIED_MAPPING = {
    verified = true,
    verified_runtime = true,
    product_verified = true,
}

local function latest_response(events)
    local attempt, success = nil, nil
    for _, event in ipairs(events) do
        if type(event) == "table" and event.kind == "player_action" then
            local data = type(event.data) == "table" and event.data or {}
            if data.role == "success" then success = data
            elseif data.role == "attempt" then attempt = data end
        end
    end
    return success or attempt
end

local function has_damage(events, explicit_damage)
    if tonumber(explicit_damage) and tonumber(explicit_damage) > 0 then return true end
    for _, event in ipairs(events) do
        if type(event) == "table" and event.kind == "damage" then return true end
    end
    return false
end

local function response_label(response)
    return tostring(response and (response.name or response.semantic) or "猎人应对")
end

function M.classify(events, options)
    options = options or {}
    if type(events) ~= "table" then
        return {
            outcome = "unclassified",
            score = "unclassified",
            label = "结果待分类",
            tone = "muted",
            reason = "invalid_events",
        }
    end

    local response = latest_response(events)
    local result = {
        outcome = "unclassified",
        score = "unclassified",
        label = "结果待分类",
        tone = "muted",
        evidence = response,
    }

    if options.interrupted == true then
        result.outcome = "interrupted"
        result.label = "动作中断"
        result.reason = "round_interrupted"
        return result
    end

    if has_damage(events, options.damage) then
        result.outcome = options.outcome_tracking == true and "hit" or "observed_hit"
        result.score = options.outcome_tracking == true and "failure" or "unclassified"
        result.label = options.outcome_tracking == true and "受击" or "观察到受击"
        result.tone = "failure"
        result.reason = "damage_observed"
        return result
    end

    if response and response.role == "success" and VERIFIED_MAPPING[response.mapping_status] then
        result.outcome = "counter_success"
        result.score = "success"
        result.label = response_label(response) .. "成功"
        result.tone = "success"
        result.reason = "verified_success_node"
        return result
    end

    if options.outcome_tracking == true then
        result.outcome = "no_damage"
        result.score = "success"
        result.tone = "success"
        result.reason = "health_tracked_without_damage"
        if response and response.role == "success" then
            result.label = "无伤；" .. response_label(response) .. "成功节点待验证"
        else
            result.label = "无伤（应对方式待确认）"
        end
        return result
    end

    if response and response.role == "success" then
        result.outcome = "response_success_candidate"
        result.label = "观察到" .. response_label(response) .. "成功候选节点"
        result.reason = "unverified_success_node"
        return result
    end

    if response and response.role == "attempt" then
        result.outcome = "response_attempt"
        result.label = "已尝试" .. response_label(response) .. "，结果待确认"
        result.reason = "attempt_without_success_evidence"
        return result
    end

    return result
end

return M
