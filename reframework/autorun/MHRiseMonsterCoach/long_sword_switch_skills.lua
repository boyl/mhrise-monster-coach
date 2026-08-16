local M = {}

local DEFAULT = 0
local REPLACE = 1

local function choice(raw, default_skill, replacement_skill)
    if raw == DEFAULT then return default_skill end
    if raw == REPLACE then return replacement_skill end
    return nil
end

function M.resolve(raw)
    if type(raw) ~= "table" or #raw < 6 then return nil, "incomplete_replace_attack_flags" end
    local slot4
    if raw[5] == REPLACE then
        slot4 = "tempered_spirit_blade"
    elseif raw[5] == DEFAULT then
        slot4 = choice(raw[2], "soaring_kick", "silkbind_sakura_slash")
    end
    local result = {
        choice(raw[1], "step_slash", "drawn_double_slash"),
        choice(raw[3], "spirit_roundslash_combo", "spirit_reckoning_combo"),
        choice(raw[4], "special_sheathe_combo", "sacred_sheathe_combo"),
        slot4,
        choice(raw[6], "serene_pose", "harvest_moon"),
    }
    for index = 1, 5 do
        if result[index] == nil then return nil, "unknown_replace_attack_flag_" .. tostring(index) end
    end
    return result, nil
end

return M
