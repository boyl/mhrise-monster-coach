package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local dumped = {}
json = { dump_file = function(path, value) dumped[path] = value end }
sdk = { find_type_definition = function() return nil end }

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
local player_type = type_def("snow.player.LongSwordPlayer", { weapon_field, unrelated_field }, {
    gauge_method, wirebug_method, weapon_drawn_method, weapon_ctrl_method, unsafe_method,
})
local data_type = type_def("snow.player.PlayerData", {}, {})
local player = { get_type_definition = function() return player_type end }
local player_data = { get_type_definition = function() return data_type end }

local Reader = require("MHRiseMonsterCoach.player_state_reader")
local reader = Reader.new("mhrise", 71)
assert(reader:capture(player, player_data), "first player capture writes metadata probe")
assert(not reader:capture(player, player_data), "same object types do not rewrite metadata")
local probe = dumped["MHRiseMonsterCoach/runtime_player_state_probe.json"]
assert(probe.policy == "metadata_only_plus_exact_whitelisted_getters")
assert(#probe.objects.player.fields == 1 and probe.objects.player.fields[1].name == "_playerWeaponType")
assert(#probe.objects.player.methods == 4)
local state = dumped["MHRiseMonsterCoach/runtime_player_combat_state.json"]
assert(state.weapon_type_raw == 2, "exact runtime weapon field is read")
assert(state.weapon_type == "long_sword", "raw value plus LS controller resolves stable semantic")
assert(state.usable_wirebugs == 2 and state.weapon_drawn == true)
assert(reader:description().captured == true)

weapon_raw = 3
local mismatch = Reader.new("mhrise", 71)
mismatch:capture(player, player_data)
assert(mismatch:description().weapon_type == nil, "raw value mismatch remains unknown even with LS controller")

print("test_player_state_reader.lua: PASS")
