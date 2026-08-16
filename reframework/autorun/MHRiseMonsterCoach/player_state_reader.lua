local M = {}

local PROBE_PATH = "MHRiseMonsterCoach/runtime_player_state_probe.json"
local STATE_PATH = "MHRiseMonsterCoach/runtime_player_combat_state.json"
local KEYWORDS = {
    "weapon", "skill", "swap", "scroll", "wire", "gauge", "spirit",
    "longsword", "long_sword", "tachi", "sheathe", "actionset", "action_set",
    "replace", "change", "red", "blue",
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

local function inspect_all_hierarchy(root_type)
    local result = { root_type = type_name(root_type), hierarchy = {}, fields = {}, methods = {} }
    local current = root_type
    local visited = {}
    local depth = 0
    while current ~= nil and depth < 8 do
        local current_name = type_name(current) or tostring(current)
        if visited[current_name] then break end
        visited[current_name] = true
        result.hierarchy[#result.hierarchy + 1] = current_name
        for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            if name then
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
            if name and params == 0 then
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

local function find_member(root_type, accessor, name)
    local current = root_type
    local visited = {}
    local depth = 0
    while current ~= nil and depth < 12 do
        local current_name = type_name(current) or tostring(current)
        if visited[current_name] then return nil end
        visited[current_name] = true
        local member = safe(function() return current[accessor](current, name) end)
        if member ~= nil then return member end
        current = safe(function() return current:get_parent_type() end)
        depth = depth + 1
    end
    return nil
end

local function call_exact_getter(root_type, instance, name)
    local method = find_member(root_type, "get_method", name)
    if method == nil or safe(function() return method:get_num_params() end) ~= 0 then return nil end
    return safe(function() return method:call(instance) end)
end

local function read_exact_field(root_type, instance, name)
    local field = find_member(root_type, "get_field", name)
    return field and safe(function() return field:get_data(instance) end) or nil
end

local function primitive_value(value)
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return value end
    return value ~= nil and tostring(value) or nil
end

function M.new(game_name, tdb_version)
    return setmetatable({
        game_name = game_name,
        tdb_version = tdb_version,
        captured = false,
        fingerprint = nil,
        last_state_key = nil,
        status = "waiting for player",
        probe = nil,
        state = nil,
    }, { __index = M })
end

function M.capture(self, player, player_data)
    if player == nil then self.status = "player unavailable" return false end
    local player_type = safe(function() return player:get_type_definition() end)
    if player_type == nil then self.status = "player type unavailable" return false end
    local player_data_type = player_data and safe(function() return player_data:get_type_definition() end) or nil

    -- These two getters were discovered by the metadata-only first-stage probe and
    -- are now the only approved object traversal points.
    local skill_list = call_exact_getter(player_type, player, "get_PlayerSkillList")
    local weapon_ctrl = call_exact_getter(player_type, player, "get_WeaponMainCtrl")
    local skill_list_type = skill_list and safe(function() return skill_list:get_type_definition() end) or nil
    local weapon_ctrl_type = weapon_ctrl and safe(function() return weapon_ctrl:get_type_definition() end) or nil
    local player_skill_data_type = safe(function() return sdk.find_type_definition("snow.player.PlayerSkillData") end)
    local fingerprint = table.concat({
        type_name(player_type) or "nil",
        type_name(player_data_type) or "nil",
        type_name(skill_list_type) or "nil",
        type_name(weapon_ctrl_type) or "nil",
        type_name(player_skill_data_type) or "nil",
    }, "|")

    local metadata_changed = fingerprint ~= self.fingerprint
    if metadata_changed then
        self.probe = {
            schema_version = 2,
            policy = "metadata_only_plus_exact_whitelisted_getters",
            runtime = { game_name = self.game_name, tdb_version = self.tdb_version },
            fingerprint = fingerprint,
            objects = {
                player = inspect_hierarchy(player_type),
                player_data = inspect_hierarchy(player_data_type),
                player_skill_list = inspect_hierarchy(skill_list_type),
                weapon_main_ctrl = inspect_hierarchy(weapon_ctrl_type),
                player_skill_data = inspect_all_hierarchy(player_skill_data_type),
            },
        }
        local ok = safe(function() json.dump_file(PROBE_PATH, self.probe) return true end) == true
        if not ok then self.status = "probe file write failed" return false end
        self.fingerprint = fingerprint
        self.captured = true
    end

    local weapon_type_raw = primitive_value(read_exact_field(player_type, player, "_playerWeaponType"))
    local weapon_ctrl_name = type_name(weapon_ctrl_type)
    local weapon_type = nil
    if tonumber(weapon_type_raw) == 2 and weapon_ctrl_name == "snow.player.PlayerWeaponCtrlLS_Sword" then
        weapon_type = "long_sword"
    end
    local state = {
        schema_version = 1,
        availability = "partial",
        weapon_type = weapon_type,
        weapon_type_raw = weapon_type_raw,
        weapon_controller_type = weapon_ctrl_name,
        usable_wirebugs = primitive_value(call_exact_getter(player_type, player, "getUsableHunterWireNum")),
        weapon_drawn = primitive_value(call_exact_getter(player_type, player, "isWeaponOn")),
        unavailable = {
            "active_scroll", "switch_skills_red", "switch_skills_blue",
            "long_sword_gauge", "long_sword_spirit_level", "quick_sheathe_level",
        },
    }
    local state_key = table.concat({
        tostring(state.weapon_type_raw), tostring(state.usable_wirebugs), tostring(state.weapon_drawn),
    }, "|")
    if state_key ~= self.last_state_key then
        safe(function() json.dump_file(STATE_PATH, state) end)
        self.last_state_key = state_key
    end
    self.state = state

    local player_count = #self.probe.objects.player.fields + #self.probe.objects.player.methods
    local nested_count = #self.probe.objects.player_skill_list.fields + #self.probe.objects.player_skill_list.methods
        + #self.probe.objects.weapon_main_ctrl.fields + #self.probe.objects.weapon_main_ctrl.methods
        + #self.probe.objects.player_skill_data.fields + #self.probe.objects.player_skill_data.methods
    self.status = string.format("weapon=%s; wirebugs=%s; nested candidates=%d",
        tostring(state.weapon_type_raw or "unknown"), tostring(state.usable_wirebugs or "unknown"), nested_count)
    return metadata_changed
end

function M.description(self)
    return {
        captured = self.captured,
        status = self.status,
        path = PROBE_PATH,
        state_path = STATE_PATH,
        player_type = self.probe and self.probe.objects.player.root_type or nil,
        player_data_type = self.probe and self.probe.objects.player_data.root_type or nil,
        weapon_type_raw = self.state and self.state.weapon_type_raw or nil,
        weapon_type = self.state and self.state.weapon_type or nil,
        usable_wirebugs = self.state and self.state.usable_wirebugs or nil,
        weapon_drawn = self.state and self.state.weapon_drawn or nil,
    }
end

return M
