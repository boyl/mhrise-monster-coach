package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local dumped = {}
json = { dump_file = function(path, value) dumped[path] = value end }

local function type_def(name, fields, methods, parent)
    return {
        get_full_name = function() return name end,
        get_fields = function() return fields or {} end,
        get_methods = function() return methods or {} end,
        get_parent_type = function() return parent end,
    }
end

local number_type = type_def("System.Single")
local weapon_field = {
    get_name = function() return "_WeaponType" end,
    get_type = function() return number_type end,
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
local unsafe_method = {
    get_name = function() return "set_SpiritGauge" end,
    get_num_params = function() return 1 end,
    get_return_type = function() return number_type end,
}
local player_type = type_def("snow.player.LongSwordPlayer", { weapon_field, unrelated_field }, { gauge_method, unsafe_method })
local data_type = type_def("snow.player.PlayerData", {}, {})
local player = { get_type_definition = function() return player_type end }
local player_data = { get_type_definition = function() return data_type end }

local Reader = require("MHRiseMonsterCoach.player_state_reader")
local reader = Reader.new("mhrise", 71)
assert(reader:capture(player, player_data), "first player capture writes metadata probe")
assert(not reader:capture(player, player_data), "repeated capture is idempotent")
local probe = dumped["MHRiseMonsterCoach/runtime_player_state_probe.json"]
assert(probe.policy == "metadata_only_no_unknown_method_calls")
assert(#probe.objects.player.fields == 1 and probe.objects.player.fields[1].name == "_WeaponType")
assert(#probe.objects.player.methods == 1 and probe.objects.player.methods[1].name == "get_SpiritGauge")
assert(reader:description().captured == true)

print("test_player_state_reader.lua: PASS")
