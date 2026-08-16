package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

json = { dump_file = function() end }

local ActionReader = require("MHRiseMonsterCoach.action_reader")

local values = { 10, 10, 11, 11 }
local index = 0
local method = {
    get_num_params = function() return 0 end,
    call = function()
        index = math.min(index + 1, #values)
        return values[index]
    end,
}
local type_def = {
    get_full_name = function() return "snow.enemy.Em032_00" end,
    get_method = function(_, name)
        if name == "get_ActionNo" then return method end
        return nil
    end,
    get_field = function() return nil end,
    get_methods = function() error("full method enumeration is forbidden") end,
    get_fields = function() error("full field enumeration is forbidden") end,
    get_parent_type = function() return nil end,
}
local enemy = { get_type_definition = function() return type_def end }

local reader = ActionReader.new({ action_reader = { kind = "auto", name = "" } })
assert(reader:read(enemy) == "10", "reads first action")
assert(reader:read(enemy) == "10", "stable action")
assert(reader:read(enemy) == "11", "observes transition")
assert(reader:description().name == "get_ActionNo", "reports selected reader")
assert(reader:diagnostics()[1].changes == 1, "counts changes")

print("test_action_reader.lua: PASS")
