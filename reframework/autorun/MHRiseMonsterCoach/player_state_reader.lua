local M = {}
local LongSwordSwitchSkills = require("MHRiseMonsterCoach.long_sword_switch_skills")
local PlayerActionReader = require("MHRiseMonsterCoach.player_action_reader")

local PROBE_PATH = "MHRiseMonsterCoach/runtime_player_state_probe.json"
local STATE_PATH = "MHRiseMonsterCoach/runtime_player_combat_state.json"
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

local primitive_value

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

local function inspect_exact_type(root_type)
    local result = { root_type = type_name(root_type), fields = {}, methods = {} }
    if root_type == nil then return result end
    for _, field in ipairs(safe(function() return root_type:get_fields() end) or {}) do
        local name = safe(function() return field:get_name() end)
        if name then
            local is_literal = safe(function() return field:is_literal() end) == true
            result.fields[#result.fields + 1] = {
                name = name,
                value_type = member_type_name(field, "get_type"),
                literal_value = is_literal and primitive_value(safe(function() return field:get_data(nil) end)) or nil,
            }
        end
    end
    for _, method in ipairs(safe(function() return root_type:get_methods() end) or {}) do
        local name = safe(function() return method:get_name() end)
        local params = safe(function() return method:get_num_params() end)
        if name then
            result.methods[#result.methods + 1] = {
                name = name,
                parameter_count = params,
                return_type = member_type_name(method, "get_return_type"),
            }
        end
    end
    table.sort(result.fields, function(a, b) return a.name < b.name end)
    table.sort(result.methods, function(a, b) return a.name < b.name end)
    return result
end

local function managed_array_values(array, limit)
    if array == nil then return nil end
    local elements = safe(function() return array:get_elements() end)
    local values = {}
    if type(elements) == "table" then
        for index, value in ipairs(elements) do
            if index > limit then break end
            values[#values + 1] = value
        end
        return values
    end
    local array_type = safe(function() return sdk.find_type_definition("System.Array") end)
    local length_method = array_type and safe(function() return array_type:get_method("get_Length") end) or nil
    local value_method = array_type and safe(function() return array_type:get_method("GetValue(System.Int32)") end) or nil
    local length = length_method and safe(function() return length_method:call(array) end) or nil
    if type(length) ~= "number" or value_method == nil then return nil end
    for index = 0, math.min(length, limit) - 1 do
        values[#values + 1] = safe(function() return value_method:call(array, index) end)
    end
    return values
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

primitive_value = function(value)
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return value end
    if value ~= nil then
        local value_type = safe(function() return value:get_type_definition() end)
        local value_field = value_type and find_member(value_type, "get_field", "value__") or nil
        local unboxed = value_field and safe(function() return value_field:get_data(value) end) or nil
        local unboxed_kind = type(unboxed)
        if unboxed_kind == "number" or unboxed_kind == "string" or unboxed_kind == "boolean" then
            return unboxed
        end
    end
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
        action_reader = PlayerActionReader.new(game_name, tdb_version, 128),
    }, { __index = M })
end

function M.suspend(self, reason)
    self.state = nil
    self.status = reason or "player combat state suspended"
    self.action_reader:suspend(reason)
end

function M.capture(self, player, player_data)
    if player == nil then
        self.status = "player unavailable"
        self.action_reader:suspend(self.status)
        return false
    end
    local player_type = safe(function() return player:get_type_definition() end)
    if player_type == nil then self.status = "player type unavailable" return false end
    local player_data_type = player_data and safe(function() return player_data:get_type_definition() end) or nil

    -- These two getters were discovered by the metadata-only first-stage probe and
    -- are now the only approved object traversal points.
    local skill_list = call_exact_getter(player_type, player, "get_PlayerSkillList")
    local weapon_ctrl = call_exact_getter(player_type, player, "get_WeaponMainCtrl")
    local replace_holder = read_exact_field(player_type, player, "_ReplaceAtkMysetHolder")
    local skill_list_type = skill_list and safe(function() return skill_list:get_type_definition() end) or nil
    local weapon_ctrl_type = weapon_ctrl and safe(function() return weapon_ctrl:get_type_definition() end) or nil
    local replace_holder_type = replace_holder and safe(function() return replace_holder:get_type_definition() end) or nil
    local replace_data_type = safe(function() return sdk.find_type_definition("snow.player.ReplaceAtkMysetData") end)
    local replace_attack_type = safe(function() return sdk.find_type_definition("snow.player.PlayerBase.ReplaceAttackType") end)
    local fingerprint = table.concat({
        type_name(player_type) or "nil",
        type_name(player_data_type) or "nil",
        type_name(skill_list_type) or "nil",
        type_name(weapon_ctrl_type) or "nil",
        type_name(replace_holder_type) or "nil",
        type_name(replace_data_type) or "nil",
        type_name(replace_attack_type) or "nil",
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
                replace_attack_holder = inspect_exact_type(replace_holder_type),
                replace_attack_data = inspect_exact_type(replace_data_type),
                replace_attack_enum = inspect_exact_type(replace_attack_type),
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
    local long_sword_gauge = nil
    local long_sword_spirit_level = nil
    if tonumber(weapon_type_raw) == 2 and weapon_ctrl_name == "snow.player.PlayerWeaponCtrlLS_Sword" then
        weapon_type = "long_sword"
        -- Mature REFramework mods read these members from snow.player.LongSword.
        -- Hierarchy lookup keeps the whitelist valid when the runtime object is a subclass.
        long_sword_gauge = primitive_value(read_exact_field(player_type, player, "_LongSwordGauge"))
        long_sword_spirit_level = primitive_value(call_exact_getter(player_type, player, "get_LongSwordGaugeLv"))
        if long_sword_spirit_level == nil then
            long_sword_spirit_level = primitive_value(read_exact_field(player_type, player, "_LongSwordGaugeLv"))
        end
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
            "switch_skills_red", "switch_skills_blue", "quick_sheathe_level",
        },
    }
    local quick_sheathe_level = nil
    if skill_list_type and skill_list then
        local skill_data_array = call_exact_getter(skill_list_type, skill_list, "get_PlayerSkillData")
            or read_exact_field(skill_list_type, skill_list, "_PlayerSkillData")
        if skill_data_array ~= nil then
            quick_sheathe_level = 0
            local skill_data_type = safe(function() return sdk.find_type_definition("snow.player.PlayerSkillData") end)
            for _, skill_data in ipairs(managed_array_values(skill_data_array, 256) or {}) do
                local item_type = safe(function() return skill_data:get_type_definition() end) or skill_data_type
                local skill_id = primitive_value(read_exact_field(item_type, skill_data, "SkillId"))
                if tonumber(skill_id) == 39 then
                    quick_sheathe_level = tonumber(primitive_value(read_exact_field(item_type, skill_data, "SkillLv"))) or 0
                    break
                end
            end
        end
    end
    local selected_replace_index = replace_holder_type and replace_holder
        and primitive_value(call_exact_getter(replace_holder_type, replace_holder, "getSelectedIndex")) or nil
    local replace_sets = {}
    local replace_data_array = replace_holder_type and replace_holder
        and read_exact_field(replace_holder_type, replace_holder, "_ReplaceAtkMysetData") or nil
    for set_index, replace_data in ipairs(managed_array_values(replace_data_array, 2) or {}) do
        local set_type = safe(function() return replace_data:get_type_definition() end) or replace_data_type
        local raw_types = set_type and read_exact_field(set_type, replace_data, "_ReplaceAtkTypes") or nil
        local raw_values = {}
        for _, value in ipairs(managed_array_values(raw_types, 8) or {}) do
            raw_values[#raw_values + 1] = primitive_value(value)
        end
        replace_sets[set_index] = raw_values
    end
    state.active_scroll_index = selected_replace_index
    state.active_scroll = tonumber(selected_replace_index) == 0 and "red"
        or tonumber(selected_replace_index) == 1 and "blue" or "unknown"
    state.switch_skills_raw = { red = replace_sets[1], blue = replace_sets[2] }
    local red_skills = LongSwordSwitchSkills.resolve(replace_sets[1])
    local blue_skills = LongSwordSwitchSkills.resolve(replace_sets[2])
    if red_skills and blue_skills then
        state.switch_skills = { red = red_skills, blue = blue_skills }
        state.unavailable = quick_sheathe_level == nil and { "quick_sheathe_level" } or {}
    end
    state.equipment_skills = { quick_sheathe = quick_sheathe_level }
    state.resources = {
        usable_wirebugs = state.usable_wirebugs,
        spirit_gauge = long_sword_gauge,
        spirit_level = long_sword_spirit_level,
    }
    local action_changed = self.action_reader:capture(player)
    local action_evidence = self.action_reader.state
    state.action_state = {
        weapon_drawn = state.weapon_drawn,
        cancelable = nil,
        current_action = nil,
        evidence = action_evidence,
    }
    local action_tags = {}
    for name, value in pairs(action_evidence and action_evidence.tags or {}) do
        action_tags[#action_tags + 1] = tostring(name) .. "=" .. tostring(value)
    end
    table.sort(action_tags)
    local state_key = table.concat({
        tostring(state.weapon_type_raw), tostring(state.usable_wirebugs), tostring(state.weapon_drawn),
        tostring(long_sword_gauge), tostring(long_sword_spirit_level),
        tostring(selected_replace_index),
        tostring(quick_sheathe_level),
        table.concat(replace_sets[1] or {}, ","), table.concat(replace_sets[2] or {}, ","),
        tostring(action_evidence and action_evidence.availability or "unavailable"),
        tostring(action_evidence and action_evidence.node_id or "unknown"),
        table.concat(action_tags, ","),
    }, "|")
    if state_key ~= self.last_state_key then
        safe(function() json.dump_file(STATE_PATH, state) end)
        self.last_state_key = state_key
    end
    self.state = state

    local player_count = #self.probe.objects.player.fields + #self.probe.objects.player.methods
    local nested_count = #self.probe.objects.player_skill_list.fields + #self.probe.objects.player_skill_list.methods
        + #self.probe.objects.weapon_main_ctrl.fields + #self.probe.objects.weapon_main_ctrl.methods
        + #self.probe.objects.replace_attack_holder.fields + #self.probe.objects.replace_attack_holder.methods
        + #self.probe.objects.replace_attack_data.fields + #self.probe.objects.replace_attack_data.methods
        + #self.probe.objects.replace_attack_enum.fields + #self.probe.objects.replace_attack_enum.methods
    self.status = string.format("weapon=%s; wirebugs=%s; nested candidates=%d",
        tostring(state.weapon_type_raw or "unknown"), tostring(state.usable_wirebugs or "unknown"), nested_count)
    return metadata_changed or action_changed
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
        player_action = self.action_reader:description(),
    }
end

return M
