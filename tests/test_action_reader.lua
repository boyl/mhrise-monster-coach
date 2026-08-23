package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local dumped = {}
json = { dump_file = function(path, value) dumped[path] = value end }

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
local motion = { resolve = true, call = function(self, name, bank, motion_id, info)
    if string.find(name, "getLayer", 1, true) then return layer end
    if string.find(name, "getMotionInfo", 1, true) then
        if self.resolve == false then return false end
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
    get_address = function(self) return self.address end,
    address = 1001,
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
motion_enemy.address = 1002
motion_reader:read(motion_enemy)
assert(motion_reader.target_address == "1002" and motion_reader.samples == 1,
    "same-type replacement enemy rebuilds instance-bound Motion candidates")
motion.resolve = false
motion_enemy.address = 1003
motion_info.values = { name = "em042_stale", end_frame = 380.0 }
local _, unresolved_metadata = motion_reader:read(motion_enemy)
assert(unresolved_metadata.motion_name == nil and unresolved_metadata.end_frame == nil,
    "failed MotionInfo lookup cannot leak a stale animation name")
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
local motion_frame_method = {
    get_num_params = function() return 1 end,
    call = function() return 12.0 end,
}
local nested_enemy_parent_type = {
    get_full_name = function() return "snow.enemy.EnemyCharacterBase" end,
    get_method = function(_, name)
        if name == "get_ActionParam" then return action_param_accessor end
        if name == "getMotionNowFrame_Layer" then return motion_frame_method end
        return nil
    end,
    get_field = function() return nil end,
    get_parent_type = function() return nil end,
}
local nested_enemy_type = {
    get_full_name = function() return "snow.enemy.em032.Em032_00Character" end,
    get_method = function() return nil end,
    get_field = function() return nil end,
    get_parent_type = function() return nested_enemy_parent_type end,
}
local nested_enemy = {
    get_type_definition = function() return nested_enemy_type end,
    call = function(_, name) if name == "get_GameObject" then return game_object end end,
}
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

local action_param_method_values = { 6, 10 }
local action_param_method_index = 0
local action_no_method = {
    get_name = function() return "get_ActionNo" end,
    get_num_params = function() return 0 end,
    call = function()
        action_param_method_index = math.min(action_param_method_index + 1, #action_param_method_values)
        return action_param_method_values[action_param_method_index]
    end,
}
local action_category_method = {
    get_name = function() return "get_ActionCategory" end,
    get_num_params = function() return 0 end,
    call = function() return 4 end,
}
local method_param_type = {
    get_full_name = function() return "snow.enemy.EnemyActionParam" end,
    get_fields = function() return {} end,
    get_methods = function() return { action_no_method, action_category_method } end,
    get_method = function(_, name)
        if name == "get_ActionNo" then return action_no_method end
        if name == "get_ActionCategory" then return action_category_method end
    end,
    get_parent_type = function() return nil end,
}
sdk.find_type_definition = function(name)
    if name == "snow.enemy.EnemyActionParam" then return method_param_type end
    return nil
end
motion.resolve = true
local method_reader = ActionReader.new({ diagnostic_safe_mode = true, action_reader = { kind = "auto", name = "" } })
local method_action, method_metadata = method_reader:read(nested_enemy)
assert(method_action == "6", "reads ActionNo getter through EnemyActionParam")
assert(method_metadata.action_no == 6 and method_metadata.action_category == 4, "captures Action category metadata")
assert(method_metadata.motion_name == "em032_attack_41", "enriches ActionNo with simultaneous Motion metadata")
assert(method_metadata.current_frame == 12.0, "captures current animation frame")
assert(method_metadata.motion_progress == 0.25, "calculates bounded animation progress")
assert(dumped["MHRiseMonsterCoach/runtime_action_state.json"].schema_version == 2, "writes versioned automatic evidence")
assert(#dumped["MHRiseMonsterCoach/runtime_action_state.json"].history == 1, "automatic evidence starts bounded history")
assert(method_reader:read(nested_enemy) == "10", "nested ActionNo getter observes transition")
assert(method_reader:description().kind == "action_param_method", "nested getter is identified")

print("test_action_reader.lua: PASS")
