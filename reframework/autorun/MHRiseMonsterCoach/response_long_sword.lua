local M = {}

local function candidate(action, availability, timing, reason, risk, resources)
    return {
        action = action,
        availability = availability,
        timing = timing,
        reason = reason,
        risk = risk,
        required_resources = resources or {},
        input_action = action,
    }
end

local function active_switch_skills(player)
    local scroll = player.active_scroll
    local books = player.switch_skills or {}
    if scroll ~= "red" and scroll ~= "blue" then return nil end
    return books[scroll]
end

local function has_skill(skills, expected)
    if type(skills) ~= "table" then return nil end
    for _, value in ipairs(skills) do
        if value == expected then return true end
    end
    return false
end

function M.evaluate(monster, player)
    if type(monster) ~= "table" or type(player) ~= "table" then
        return {}, "invalid_context"
    end
    if player.weapon_type ~= "long_sword" then return {}, "unsupported_weapon" end

    local results = {}
    local action_state = player.action_state or {}
    local resources = player.resources or {}
    local skills = active_switch_skills(player)
    local special_sheathe = has_skill(skills, "special_sheathe_combo")
    local sacred_sheathe = has_skill(skills, "sacred_sheathe_combo")

    if action_state.cancelable == true and (resources.spirit_gauge or 0) > 0 then
        results[#results + 1] = candidate("foresight_slash", "available", "before_hit",
            "当前动作可取消且气刃槽可用。", "medium", { spirit_gauge = "positive" })
    elseif action_state.cancelable == false then
        results[#results + 1] = candidate("foresight_slash", "wait", "next_cancel_window",
            "当前动作不可取消。", "high", { spirit_gauge = "positive" })
    end

    if special_sheathe == true then
        results[#results + 1] = candidate("iai_spirit_slash", "available", "during_startup",
            "当前书装备特殊纳刀；需自行确认纳刀准备窗口。", "high")
    elseif special_sheathe == false then
        results[#results + 1] = candidate("iai_spirit_slash", "unavailable", "none",
            "当前书未装备特殊纳刀。", "high")
    else
        results[#results + 1] = candidate("iai_spirit_slash", "unknown", "none",
            "当前交换技书尚不可读。", "unknown")
    end

    if sacred_sheathe == true then
        results[#results + 1] = candidate("sacred_sheathe", "available", "during_startup",
            "当前书装备神威居合；自动反击会消耗一层刃色。", "high",
            { spirit_level = "one_or_more" })
    end

    if monster.phase == "recovery" then
        local wirebugs = tonumber(resources.usable_wirebugs)
        local soaring_kick = has_skill(skills, "soaring_kick")
        local spirit_level = tonumber(resources.spirit_level)
        if soaring_kick == true and wirebugs and wirebugs >= 1 and spirit_level and spirit_level >= 1 then
            results[#results + 1] = candidate("spirit_helmbreaker", "available", "after_recovery",
                "怪物处于收招，飞翔踢、翔虫和刃色条件满足。", "medium",
                { usable_wirebugs = 1, spirit_level = 1 })
        end
    end

    results[#results + 1] = candidate("evade", "available", "before_hit",
        "通用保底应对；方向仍需结合攻击范围。", "low")
    return results, nil
end

return M
