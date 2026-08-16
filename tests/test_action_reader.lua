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

local motion_values = { { 100, 40 }, { 100, 40 }, { 100, 41 } }
local motion_index = 0
local layer = {
    current = nil,
    call = function(self, name)
        if name == "get_MotionBankID" then
            motion_index = math.min(motion_index + 1, #motion_values)
            self.current = motion_values[motion_index]
            return self.current[1]
        end
        if name == "get_MotionID" then return self.current[2] end
        return nil
    end,
}
local motion = { call = function(_, name) if string.find(name, "getLayer", 1, true) then return layer end end }
local game_object = { call = function(_, name) if string.find(name, "getComponent", 1, true) then return motion end end }
local motion_type_def = {
    get_full_name = function() return "snow.enemy.Em032_00" end,
    get_method = function() return nil end,
    get_field = function() return nil end,
}
local motion_enemy = {
    get_type_definition = function() return motion_type_def end,
    call = function(_, name) if name == "get_GameObject" then return game_object end end,
}
sdk = { typeof = function(name) return name end }

local motion_reader = ActionReader.new({ action_reader = { kind = "auto", name = "" } })
assert(motion_reader:read(motion_enemy) == "100:40", "motion fallback reads bank and motion ID")
assert(motion_reader:read(motion_enemy) == "100:40", "motion fallback remains stable")
assert(motion_reader:read(motion_enemy) == "100:41", "motion fallback observes animation changes")
assert(motion_reader:description().kind == "motion", "motion fallback is labeled as a proxy")
assert(motion_reader:description().changes == 1, "motion fallback counts changes")

print("test_action_reader.lua: PASS")
