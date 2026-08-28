local device_type = {}
function device_type:get_full_name() return "via.hid.MergedGamePadDevice" end
function device_type:get_method(name)
    if name == "get_AxisL" or name == "set_AxisL(via.vec2)" then return { name = name } end
    return nil
end
local device = {}
function device:get_type_definition() return device_type end
function device:call(name)
    if name == "get_AxisL" then return { x = 0.25, y = -0.5 } end
end
local stm = {}
local stm_type = {}
function stm_type:get_full_name() return "snow.StmInputManager" end
function stm_type:get_parent_type() return nil end
function stm_type:get_fields()
    return {{
        get_name = function() return "_KeyboardConfig" end,
        get_type = function()
            return { get_full_name = function() return "snow.KeyboardConfig" end }
        end,
        get_data = function() return 4 end,
        is_static = function() return false end,
    }}
end
function stm_type:get_methods()
    return {{
        get_name = function() return "get_ActiveInputDevice" end,
        get_return_type = function()
            return { get_full_name = function() return "snow.InputDevice" end }
        end,
        get_param_types = function() return {} end,
    }}
end
function stm:get_type_definition()
    return stm_type
end
function stm:get_field(name)
    if name == "_ActiveDevice" then
        return { get_field = function(_, nested) return nested == "_ActiveDevice" and 1 or nil end }
    end
end
local button_type = {}
function button_type:get_field(name)
    if name == "EmuLup" then return { get_data = function() return 8 end } end
end
local function named_type(name)
    return { get_full_name = function() return name end }
end
local function enum_field(name, value)
    return {
        get_name = function() return name end,
        get_type = function() return named_type("System.UInt32") end,
        get_data = function(_, instance)
            assert(instance == nil, "enum metadata must read static fields without an instance")
            return value
        end,
        is_static = function() return true end,
    }
end
local function enum_type(name, values)
    return {
        get_full_name = function() return name end,
        get_fields = function() return values end,
    }
end
local command_enum = enum_type("snow.player.PlayerInput.CommandButton2", {
    enum_field("Evade", 32),
    enum_field("Attack", 4),
})
local active_device_enum = enum_type("snow.StmInputManager.ActiveGameDevice", {
    enum_field("GamePad", 3),
    enum_field("Keyboard", 1),
})
local key_config_enum = enum_type("snow.StmInputConfig.KeyConfigType", {
    enum_field("Player", 0),
})
local player_input_data_type = {
    get_full_name = function() return "snow.StmPlInputData" end,
    get_fields = function()
        return {{
            get_name = function() return "_CommandButton" end,
            get_type = function() return named_type("snow.player.PlayerInput.CommandButton2") end,
            get_data = function(_, instance) assert(instance == "player-input-data") end,
            is_static = function() return false end,
        }}
    end,
    get_methods = function()
        return {{
            get_name = function() return "isCommandTrg" end,
            get_return_type = function() return named_type("System.Boolean") end,
            get_param_types = function()
                return { named_type("snow.player.PlayerInput.CommandButton2") }
            end,
        }}
    end,
}
local input_config_type = {
    get_full_name = function() return "snow.StmInputConfig" end,
    get_fields = function() return {} end,
    get_methods = function()
        return {{
            get_name = function() return "getPlayerKeyConfig" end,
            get_return_type = function() return named_type("snow.StmInputConfig.KeyConfigType") end,
            get_param_types = function() return {} end,
        }}
    end,
}
local original_stm_get_field = stm.get_field
function stm:get_field(name)
    if name == "plParam" then return "player-input-data" end
    return original_stm_get_field(self, name)
end
sdk = {
    find_type_definition = function(name)
        if name == "via.hid.GamePad" then return {} end
        if name == "via.hid.GamePadButton" then return button_type end
        if name == "snow.player.PlayerInput.CommandButton2" then return command_enum end
        if name == "snow.StmInputManager.ActiveGameDevice" then return active_device_enum end
        if name == "snow.StmInputConfig.KeyConfigType" then return key_config_enum end
        if name == "snow.StmPlInputData" then return player_input_data_type end
        if name == "snow.StmInputConfig" then return input_config_type end
    end,
    get_native_singleton = function() return {} end,
    call_native_func = function(_, _, name)
        if name == "get_LastInputDevice" then return device end
    end,
    get_managed_singleton = function(name) return name == "snow.StmInputManager" and stm or nil end,
}
Vector2f = { new = function(x, y) return { x = x, y = y } end }

local Adapter = require("MHRiseMonsterCoach.input_motion_adapter")
local diagnostics = Adapter.new():diagnostics()
assert(diagnostics.schema_version == 2)
assert(diagnostics.policy == "read_only_known_hid_contract_probe")
assert(diagnostics.device_available and diagnostics.device_source == "get_LastInputDevice")
assert(diagnostics.device_type == "via.hid.MergedGamePadDevice")
assert(diagnostics.axis_l.x == 0.25 and diagnostics.axis_l.y == -0.5)
assert(diagnostics.methods.get_axis_l.available)
assert(diagnostics.methods.set_axis_l.available)
assert(not diagnostics.methods.set_button.available)
assert(diagnostics.stm_input_manager_available)
assert(diagnostics.stm_active_device == 1 and diagnostics.emu_left_up_available)
assert(#diagnostics.stm_input_contract == 1)
assert(diagnostics.stm_input_contract[1].fields[1].name == "_KeyboardConfig")
assert(diagnostics.stm_input_contract[1].fields[1].primitive_value == 4)
assert(diagnostics.stm_input_contract[1].methods[1].name == "get_ActiveInputDevice")
assert(diagnostics.semantic_command_enum.available)
assert(#diagnostics.semantic_command_enum.values == 2)
assert(diagnostics.semantic_command_enum.values[1].name == "Attack")
assert(diagnostics.semantic_command_enum.values[1].value == 4)
assert(diagnostics.semantic_command_enum.values[2].name == "Evade")
assert(#diagnostics.input_enum_contracts == 9)
assert(diagnostics.input_enum_contracts[1].values[2].name == "GamePad")
assert(diagnostics.input_enum_contracts[2].available == false)
assert(#diagnostics.input_enum_contracts[2].values == 0)
assert(diagnostics.known_type_contracts[1].available)
assert(diagnostics.known_type_contracts[1].fields[1].name == "_CommandButton")
assert(diagnostics.known_type_contracts[1].methods[1].name == "isCommandTrg")
assert(diagnostics.known_type_contracts[2].methods[1].name == "getPlayerKeyConfig")
assert(diagnostics.known_type_hierarchies[1].available)
assert(#diagnostics.known_type_hierarchies[1].levels == 1)
assert(diagnostics.known_type_hierarchies[1].levels[1].type == "snow.StmPlInputData")
local adapter = Adapter.new()
assert(adapter:write_axis(0, 1))
assert(adapter:diagnostics().owned and adapter:diagnostics().request_count == 1)
assert(adapter:flush() and adapter:diagnostics().write_count == 1)
assert(adapter:release())
assert(adapter:diagnostics().owned, "release remains owned until zero-axis flush")
assert(adapter:flush())
assert(not adapter:diagnostics().owned and adapter:diagnostics().write_count == 2)
print("test_input_motion_adapter.lua: PASS")
