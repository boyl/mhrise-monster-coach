local profiles = {
    (require("MHRiseMonsterCoach.profile_tigrex")),
    -- Parentheses are intentional: Lua 5.4 require returns loader data as a
    -- second value, and the final array expression would otherwise append it.
    (require("MHRiseMonsterCoach.profile_barioth")),
}

local by_id = {}
local by_quest_id = {}
for _, profile in ipairs(profiles) do
    assert(type(profile.id) == "string" and profile.id ~= "", "profile id is required")
    assert(by_id[profile.id] == nil, "duplicate profile id: " .. profile.id)
    by_id[profile.id] = profile
    local quest_id = profile.training_quest and tonumber(profile.training_quest.id) or nil
    if quest_id ~= nil then
        assert(by_quest_id[quest_id] == nil, "duplicate training quest id: " .. tostring(quest_id))
        by_quest_id[quest_id] = profile
    end
end

local M = {}

function M.default()
    return profiles[1]
end

function M.get(id)
    return by_id[id]
end

function M.all()
    local result = {}
    for index, profile in ipairs(profiles) do result[index] = profile end
    return result
end

function M.for_quest(quest_id)
    return by_quest_id[tonumber(quest_id)]
end

return M
