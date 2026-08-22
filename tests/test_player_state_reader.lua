package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local dumped = {}
json = { dump_file = function(path, value) dumped[path] = value end }
local replace_data_type
local replace_attack_type
local player_skill_data_type
local system_array_type
sdk = { find_type_definition = function(name)
    if name == "snow.player.ReplaceAtkMysetData" then return replace_data_type end
    if name == "snow.player.PlayerBase.ReplaceAttackType" then return replace_attack_type end
    if name == "System.Array" then return system_array_type end
    if name == "snow.player.PlayerSkillData" then return player_skill_data_type end
end }

local function type_def(name, fields, methods, parent)
    return {
        get_full_name = function() return name end,
        get_fields = function() return fields or {} end,
        get_methods = function() return methods or {} end,
        get_parent_type = function() return parent end,
        get_field = function(_, wanted)
            for _, field in ipairs(fields or {}) do if field:get_name() == wanted then return field end end
        end,
        get_method = function(_, wanted)
            for _, method in ipairs(methods or {}) do if method:get_name() == wanted then return method end end
        end,
    }
end

local number_type = type_def("System.Single")
local weapon_raw = 2
local weapon_field = {
    get_name = function() return "_playerWeaponType" end,
    get_type = function() return number_type end,
    get_data = function() return weapon_raw end,
}
local spirit_gauge_field = {
    get_name = function() return "_LongSwordGauge" end,
    get_type = function() return number_type end,
    get_data = function() return 64 end,
}
local spirit_level_field = {
    get_name = function() return "_LongSwordGaugeLv" end,
    get_type = function() return number_type end,
    get_data = function() return 2 end,
}
local unrelated_field = {
    get_name = function() return "_Health" end,
    get_type = function() return number_type end,
}
local gauge_method = {
    get_name = function() return "get_SpiritGauge" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return number_type end,
}
local wirebug_method = {
    get_name = function() return "getUsableHunterWireNum" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return number_type end,
    call = function() return 2 end,
}
local weapon_drawn_method = {
    get_name = function() return "isWeaponOn" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return number_type end,
    call = function() return true end,
}
local weapon_ctrl_type = type_def("snow.player.PlayerWeaponCtrlLS_Sword", {}, {})
local weapon_ctrl = { get_type_definition = function() return weapon_ctrl_type end }
local weapon_ctrl_method = {
    get_name = function() return "get_WeaponMainCtrl" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return weapon_ctrl_type end,
    call = function() return weapon_ctrl end,
}
local unsafe_method = {
    get_name = function() return "set_SpiritGauge" end,
    get_num_params = function() return 1 end,
    get_return_type = function() return number_type end,
}
local function managed_array(values)
    return { get_elements = function() return values end }
end
local fallback_array_values = { 1, 0, 1, 1, 1, 0 }
local fallback_array = {}
local array_length_method = {
    get_name = function() return "get_Length" end,
    call = function(_, instance) return #fallback_array_values end,
}
local array_value_method = {
    get_name = function() return "GetValue(System.Int32)" end,
    call = function(_, instance, index) return fallback_array_values[index + 1] end,
}
system_array_type = type_def("System.Array", {}, { array_length_method, array_value_method })
local replace_types_a = managed_array({ 0, 1, 0, 0, 0, 1 })
local boxed_value_field = {
    get_name = function() return "value__" end,
    get_type = function() return number_type end,
    get_data = function(_, instance) return instance.raw end,
}
local boxed_enum_type = type_def("snow.player.PlayerBase.ReplaceAttackType", { boxed_value_field }, {})
fallback_array_values[5] = { raw = 1, get_type_definition = function() return boxed_enum_type end }
local replace_types_b = fallback_array
local replace_types_field = {
    get_name = function() return "_ReplaceAtkTypes" end,
    get_type = function() return number_type end,
    get_data = function(_, instance) return instance.types end,
}
replace_data_type = type_def("snow.player.ReplaceAtkMysetData", { replace_types_field }, {})
replace_attack_type = type_def("snow.player.PlayerBase.ReplaceAttackType", {}, {})
local replace_data_a = { types = replace_types_a, get_type_definition = function() return replace_data_type end }
local replace_data_b = { types = replace_types_b, get_type_definition = function() return replace_data_type end }
local replace_data_array = managed_array({ replace_data_a, replace_data_b })
local replace_data_array_field = {
    get_name = function() return "_ReplaceAtkMysetData" end,
    get_type = function() return number_type end,
    get_data = function() return replace_data_array end,
}
local selected_index_method = {
    get_name = function() return "getSelectedIndex" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return number_type end,
    call = function() return 1 end,
}
local replace_holder_type = type_def("snow.player.PlayerReplaceAtkMysetHolder", { replace_data_array_field }, { selected_index_method })
local replace_holder = { get_type_definition = function() return replace_holder_type end }
local replace_holder_field = {
    get_name = function() return "_ReplaceAtkMysetHolder" end,
    get_type = function() return replace_holder_type end,
    get_data = function() return replace_holder end,
}
local skill_id_field = {
    get_name = function() return "SkillId" end,
    get_type = function() return number_type end,
    get_data = function(_, instance) return instance.id end,
}
local skill_level_field = {
    get_name = function() return "SkillLv" end,
    get_type = function() return number_type end,
    get_data = function(_, instance) return instance.level end,
}
player_skill_data_type = type_def("snow.player.PlayerSkillData", { skill_id_field, skill_level_field }, {})
local function skill_data(id, level)
    return { id = id, level = level, get_type_definition = function() return player_skill_data_type end }
end
local player_skill_array = managed_array({ skill_data(7, 1), skill_data(39, 3) })
local player_skill_array_field = {
    get_name = function() return "_PlayerSkillData" end,
    get_type = function() return number_type end,
    get_data = function() return player_skill_array end,
}
local skill_list_type = type_def("snow.player.PlayerSkillList", { player_skill_array_field }, {})
local skill_list = { get_type_definition = function() return skill_list_type end }
local skill_list_method = {
    get_name = function() return "get_PlayerSkillList" end,
    get_num_params = function() return 0 end,
    get_return_type = function() return skill_list_type end,
    call = function() return skill_list end,
}
local player_type = type_def("snow.player.LongSwordPlayer", {
    weapon_field, spirit_gauge_field, spirit_level_field, replace_holder_field, unrelated_field,
}, {
    gauge_method, wirebug_method, weapon_drawn_method, weapon_ctrl_method, skill_list_method, unsafe_method,
})
local data_type = type_def("snow.player.PlayerData", {}, {})
local player = { get_type_definition = function() return player_type end }
local player_data = { get_type_definition = function() return data_type end }

local Reader = require("MHRiseMonsterCoach.player_state_reader")
local reader = Reader.new("mhrise", 71)
reader.state = { weapon_type = "long_sword" }
reader:suspend("scene transition")
assert(reader.state == nil and reader.status == "scene transition",
    "scene transitions clear stale player combat state without touching managed objects")
assert(reader:capture(player, player_data), "first player capture writes metadata probe")
assert(not reader:capture(player, player_data), "same object types do not rewrite metadata")
local probe = dumped["MHRiseMonsterCoach/runtime_player_state_probe.json"]
assert(probe.policy == "metadata_only_plus_exact_whitelisted_getters")
assert(#probe.objects.player.fields == 3, "general probe remains keyword-bounded")
assert(#probe.objects.player.methods == 5)
assert(probe.objects.replace_attack_holder.root_type == "snow.player.PlayerReplaceAtkMysetHolder")
assert(probe.objects.replace_attack_data.root_type == "snow.player.ReplaceAtkMysetData")
local state = dumped["MHRiseMonsterCoach/runtime_player_combat_state.json"]
assert(state.weapon_type_raw == 2, "exact runtime weapon field is read")
assert(state.weapon_type == "long_sword", "raw value plus LS controller resolves stable semantic")
assert(state.resources.usable_wirebugs == 2, "runtime resource is exposed through the semantic contract")
assert(state.resources.spirit_gauge == 64, "verified long sword gauge field is read")
assert(state.resources.spirit_level == 2, "verified long sword level field fallback is read")
assert(state.active_scroll_index == 1 and state.active_scroll == "blue")
assert(#state.switch_skills_raw.red == 6 and state.switch_skills_raw.red[1] == 0,
    "red raw set count=" .. tostring(#state.switch_skills_raw.red))
assert(#state.switch_skills_raw.blue == 6 and state.switch_skills_raw.blue[5] == 1,
    "blue raw set count=" .. tostring(#state.switch_skills_raw.blue))
assert(state.switch_skills.red[1] == "step_slash")
assert(state.switch_skills.red[5] == "harvest_moon")
assert(state.switch_skills.blue[3] == "sacred_sheathe_combo")
assert(state.switch_skills.blue[4] == "tempered_spirit_blade", "boxed enum is unboxed and mapped")
assert(state.equipment_skills.quick_sheathe == 3, "Quick Sheathe uses stable skill id 39")
assert(#state.unavailable == 0)
assert(state.action_state.weapon_drawn == true, "action state retains the verified draw state")
assert(state.usable_wirebugs == 2 and state.weapon_drawn == true)
assert(reader:description().captured == true)

weapon_raw = 3
local mismatch = Reader.new("mhrise", 71)
mismatch:capture(player, player_data)
assert(mismatch:description().weapon_type == nil, "raw value mismatch remains unknown even with LS controller")

print("test_player_state_reader.lua: PASS")
