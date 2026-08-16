local M = {}

local PROBE_PATH = "MHRiseMonsterCoach/runtime_player_state_probe.json"
local KEYWORDS = {
    "weapon", "skill", "swap", "scroll", "wire", "gauge", "spirit",
    "longsword", "long_sword", "tachi", "sheathe",
}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function contains_keyword(name)
    local lower = string.lower(tostring(name or ""))
    for _, keyword in ipairs(KEYWORDS) do
        if string.find(lower, keyword, 1, true) then return true end
    end
    return false
end

local function type_name(type_def)
    return type_def and safe(function() return type_def:get_full_name() end) or nil
end

local function member_type_name(member, accessor)
    local member_type = safe(function() return member[accessor](member) end)
    return type_name(member_type) or tostring(member_type or "unknown")
end

local function inspect_hierarchy(root_type)
    local result = { root_type = type_name(root_type), hierarchy = {}, fields = {}, methods = {} }
    local current = root_type
    local visited = {}
    local field_names = {}
    local method_names = {}
    local depth = 0
    while current ~= nil and depth < 12 do
        local current_name = type_name(current) or tostring(current)
        if visited[current_name] then break end
        visited[current_name] = true
        result.hierarchy[#result.hierarchy + 1] = current_name

        for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            if name and contains_keyword(name) and not field_names[name] then
                field_names[name] = true
                result.fields[#result.fields + 1] = {
                    declaring_type = current_name,
                    name = name,
                    value_type = member_type_name(field, "get_type"),
                }
            end
        end

        for _, method in ipairs(safe(function() return current:get_methods() end) or {}) do
            local name = safe(function() return method:get_name() end)
            local params = safe(function() return method:get_num_params() end)
            if name and params == 0 and contains_keyword(name) and not method_names[name] then
                method_names[name] = true
                result.methods[#result.methods + 1] = {
                    declaring_type = current_name,
                    name = name,
                    return_type = member_type_name(method, "get_return_type"),
                }
            end
        end

        current = safe(function() return current:get_parent_type() end)
        depth = depth + 1
    end
    table.sort(result.fields, function(a, b) return a.name < b.name end)
    table.sort(result.methods, function(a, b) return a.name < b.name end)
    return result
end

function M.new(game_name, tdb_version)
    return setmetatable({
        game_name = game_name,
        tdb_version = tdb_version,
        captured = false,
        status = "waiting for player",
        probe = nil,
    }, { __index = M })
end

function M.capture(self, player, player_data)
    if self.captured then return false end
    if player == nil then self.status = "player unavailable" return false end
    local player_type = safe(function() return player:get_type_definition() end)
    if player_type == nil then self.status = "player type unavailable" return false end
    local player_data_type = player_data and safe(function() return player_data:get_type_definition() end) or nil

    self.probe = {
        schema_version = 1,
        policy = "metadata_only_no_unknown_method_calls",
        runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
        objects = {
            player = inspect_hierarchy(player_type),
            player_data = inspect_hierarchy(player_data_type),
        },
    }
    local ok = safe(function() json.dump_file(PROBE_PATH, self.probe) return true end) == true
    if not ok then self.status = "probe file write failed" return false end
    self.captured = true
    local player_count = #self.probe.objects.player.fields + #self.probe.objects.player.methods
    local data_count = #self.probe.objects.player_data.fields + #self.probe.objects.player_data.methods
    self.status = string.format("captured %d player + %d player-data candidates", player_count, data_count)
    return true
end

function M.description(self)
    return {
        captured = self.captured,
        status = self.status,
        path = PROBE_PATH,
        player_type = self.probe and self.probe.objects.player.root_type or nil,
        player_data_type = self.probe and self.probe.objects.player_data.root_type or nil,
    }
end

return M
