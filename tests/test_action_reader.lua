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
local motion_info = {
    values = {},
    add_ref = function() end,
    release = function() end,
    call = function(self, name)
        if name == "get_MotionName" then return self.values.name end
        if name == "get_MotionEndFrame" then return self.values.end_frame end
    end,
}
local motion = { call = function(_, name, bank, motion_id, info)
    if string.find(name, "getLayer", 1, true) then return layer end
    if string.find(name, "getMotionInfo", 1, true) then
        info.values = { name = "em032_attack_" .. tostring(motion_id), end_frame = 48.0 }
        return true
    end
end }
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
sdk = {
    typeof = function(name) return name end,
    create_instance = function(name)
        assert(name == "via.motion.MotionInfo", "only bounded MotionInfo creation is allowed")
        return motion_info
    end,
}

local motion_reader = ActionReader.new({ action_reader = { kind = "auto", name = "" } })
assert(motion_reader:read(motion_enemy) == "100:40", "motion fallback reads bank and motion ID")
assert(motion_reader:read(motion_enemy) == "100:40", "motion fallback remains stable")
assert(motion_reader:read(motion_enemy) == "100:41", "motion fallback observes animation changes")
assert(motion_reader:description().kind == "motion", "motion fallback is labeled as a proxy")
assert(motion_reader:description().changes == 1, "motion fallback counts changes")
assert(motion_reader:description().motion_name == "em032_attack_41", "motion fallback resolves engine motion name")
local _, metadata = motion_reader:read(motion_enemy)
assert(metadata.motion_name == "em032_attack_41", "motion metadata is returned with state key")
assert(metadata.end_frame == 48.0, "motion metadata includes animation end frame")
motion_reader:shutdown()

local action_param_values = { 2, 2, 10 }
local action_param_index = 0
local action_param = {}
local action_param_field = {
    get_name = function() return "_ActionNo" end,
    get_data = function()
        action_param_index = math.min(action_param_index + 1, #action_param_values)
        return action_param_values[action_param_index]
    end,
}
local action_param_type = {
    get_full_name = function() return "snow.enemy.EnemyActionParam" end,
    get_fields = function() return { action_param_field } end,
    get_parent_type = function() return nil end,
}
local action_param_accessor = {
    get_num_params = function() return 0 end,
    call = function() return action_param end,
}
local nested_enemy_type = {
    get_full_name = function() return "snow.enemy.em032.Em032_00Character" end,
    get_method = function(_, name)
        if name == "get_ActionParam" then return action_param_accessor end
        return nil
    end,
    get_field = function() return nil end,
}
local nested_enemy = { get_type_definition = function() return nested_enemy_type end }
sdk.find_type_definition = function(name)
    if name == "snow.enemy.EnemyActionParam" then return action_param_type end
    return nil
end

local nested_reader = ActionReader.new({ action_reader = { kind = "auto", name = "" } })
assert(nested_reader:read(nested_enemy) == "2", "reads ActionNo through EnemyActionParam")
assert(nested_reader:read(nested_enemy) == "2", "nested ActionNo remains stable")
assert(nested_reader:read(nested_enemy) == "10", "nested ActionNo observes transition")
assert(nested_reader:description().kind == "action_param_field", "nested reader is identified")
assert(nested_reader:description().name == "get_ActionParam()._ActionNo", "nested field is reported")

print("test_action_reader.lua: PASS")
