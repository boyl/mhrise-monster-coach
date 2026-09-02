local profiles = {
    (require("MHRiseMonsterCoach.profile_tigrex")),
    -- Parentheses are intentional: Lua 5.4 require returns loader data as a
    -- second value, and the final array expression would otherwise append it.
    (require("MHRiseMonsterCoach.profile_barioth")),
}

local by_id = {}
for _, profile in ipairs(profiles) do
    assert(type(profile.id) == "string" and profile.id ~= "", "profile id is required")
    assert(by_id[profile.id] == nil, "duplicate profile id: " .. profile.id)
    by_id[profile.id] = profile
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

return M
