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
local function named_type(name, is_by_ref)
    return {
        get_full_name = function() return name end,
        is_by_ref = function() return is_by_ref == true end,
    }
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
local player_input_enum = enum_type("snow.StmInputManager.PL_INPUT", {
    enum_field("ACTION_ESCAPE", 8),
    enum_field("ACTION_X_ATTACK", 13),
    enum_field("ACTION_A_ATTACK", 14),
    enum_field("ACTION_EX_GUARD_FIRE", 15),
})
local keyboard_enum = enum_type("snow.StmInputManager.InGameMouseKeyBoardKey", {
    enum_field("None", 0),
    enum_field("FaultyKey", 5),
    enum_field("KeyEscape", 10),
    enum_field("MouseLeft", 20),
    enum_field("MouseRight", 30),
    enum_field("MouseSide", 40),
})
local pad_enum = enum_type("snow.Pad.Button", {
    enum_field("NONE", 0),
    enum_field("PadB", 1),
    enum_field("PadX", 2),
    enum_field("PadA", 4),
    enum_field("PadR", 8),
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
local dictionary_method_calls = 0
local semantic_method_calls = 0
local semantic_read_calls = 0
local bitset_mutator_calls = 0
local input_config_instance = {}
local function metadata_method(name, return_type, param_types, is_static, call_handler)
    return {
        get_name = function() return name end,
        get_return_type = function() return named_type(return_type) end,
        get_param_names = function()
            if #param_types == 0 then return {} end
            return { "key", "valueData" }
        end,
        get_param_types = function()
            local result = {}
            for _, value in ipairs(param_types) do
                result[#result + 1] = named_type(value.name, value.is_by_ref)
            end
            return result
        end,
        is_static = function() return is_static == true end,
        call = function(_, object, key)
            dictionary_method_calls = dictionary_method_calls + 1
            if call_handler == nil then error("metadata-only method must never be invoked") end
            return call_handler(object, key)
        end,
    }
end
local function semantic_metadata_method(name, return_type, param_types)
    local method = metadata_method(name, return_type, param_types, false)
    method.call = function()
        semantic_method_calls = semantic_method_calls + 1
        error("semantic metadata method must never be invoked")
    end
    return method
end
local bitset_type = {
    get_full_name = function()
        return "snow.BitSetFlag`1<snow.player.PlayerInput.CommandButton2>"
    end,
    get_fields = function() return {} end,
    get_methods = function()
        return {
            semantic_metadata_method("getFlag", "System.Boolean", {
                { name = "snow.player.PlayerInput.CommandButton2" },
            }),
            {
                get_name = function() return "setFlag" end,
                get_return_type = function() return named_type("System.Void") end,
                get_param_names = function() return { "command", "enabled" } end,
                get_param_types = function()
                    return {
                        named_type("snow.player.PlayerInput.CommandButton2"),
                        named_type("System.Boolean"),
                    }
                end,
                is_static = function() return false end,
                call = function()
                    bitset_mutator_calls = bitset_mutator_calls + 1
                    error("bitset mutator must never be called by read contract")
                end,
            },
        }
    end,
}
local bitset_object = { get_type_definition = function() return bitset_type end }
local function semantic_read_getter(name)
    local method = semantic_metadata_method(name, bitset_type:get_full_name(), {})
    method.call = function(_, owner)
        assert(owner == stm, "semantic getter must use StmInputManager singleton")
        semantic_read_calls = semantic_read_calls + 1
        return bitset_object
    end
    return method
end
local semantic_parameter = { { name = "snow.player.PlayerInput.CommandButton2" } }
local semantic_manager_methods = {
    semantic_metadata_method("isOn", "System.Boolean", semantic_parameter),
    semantic_metadata_method("isTrg", "System.Boolean", semantic_parameter),
    semantic_read_getter("getOn"),
    semantic_read_getter("getTrg"),
    semantic_read_getter("getRel"),
    semantic_read_getter("getDelay"),
    semantic_metadata_method("updateInput", "System.Void", {}),
}
stm_type.get_methods = function()
    return {
        {
            get_name = function() return "get_ActiveInputDevice" end,
            get_return_type = function() return named_type("snow.InputDevice") end,
            get_param_types = function() return {} end,
        },
        table.unpack(semantic_manager_methods),
    }
end
local stm_player_input_instance = {}
local stm_player_input_type = {
    get_full_name = function() return "snow.StmPlayerInput" end,
    get_fields = function() return {} end,
    get_methods = function()
        return { semantic_metadata_method("updateCommand", "System.Void", {}) }
    end,
}
local player_input_type = {
    get_full_name = function() return "snow.player.PlayerInput" end,
    get_fields = function() return {} end,
    get_methods = function()
        return { semantic_metadata_method("checkCommand", "System.Boolean", semantic_parameter) }
    end,
}
local input_ui_type = {
    get_full_name = function() return "snow.StmInputManager.InputUI" end,
    get_fields = function() return {} end,
    get_methods = function()
        return { semantic_metadata_method("setInput", "System.Void", semantic_parameter) }
    end,
}
local main_method = metadata_method("TryGet_main_pl_Conf", "System.Boolean", {
    { name = "snow.StmInputManager.PL_INPUT" },
    { name = "snow.StmInputManager.InGameMouseKeyBoardKey" },
}, true)
local byref_probe_method = metadata_method("TryGet_probe_binding", "System.Boolean", {
    { name = "snow.StmInputManager.PL_INPUT" },
    { name = "snow.Pad.Button", is_by_ref = true },
}, true)
local keyboard_dictionary_type = {
    get_full_name = function()
        return "System.Collections.Generic.Dictionary`2<System.Int32, snow.StmInputManager.InGameMouseKeyBoardKey>"
    end,
}
local keyboard_values = { [8] = 10, [13] = 20, [14] = 30, [15] = 40 }
function keyboard_dictionary_type:get_methods()
    return {
        metadata_method("get_Item", "snow.StmInputManager.InGameMouseKeyBoardKey", {
            { name = "System.Int32" },
        }, false, function(_, key) return keyboard_values[key] end),
        metadata_method("ContainsKey", "System.Boolean", {
            { name = "System.Int32" },
        }, false, function(_, key) return keyboard_values[key] ~= nil end),
        metadata_method("get_Count", "System.Int32", {}, false),
        metadata_method("Add", "System.Void", {
            { name = "System.Int32" },
            { name = "snow.StmInputManager.InGameMouseKeyBoardKey" },
        }, false),
    }
end
function keyboard_dictionary_type:get_method(signature)
    for _, method in ipairs(self:get_methods()) do
        if signature == method:get_name() .. "(System.Int32)" then return method end
    end
end
local pad_dictionary_type = {
    get_full_name = function()
        return "System.Collections.Generic.Dictionary`2<System.Int32, snow.Pad.Button>"
    end,
}
local pad_values = { [8] = 1, [13] = 2, [14] = 4, [15] = 8 }
function pad_dictionary_type:get_methods()
    return {
        metadata_method("get_Item", "snow.Pad.Button", {
            { name = "System.Int32" },
        }, false, function(_, key) return pad_values[key] end),
        metadata_method("ContainsKey", "System.Boolean", {
            { name = "System.Int32" },
        }, false, function(_, key) return pad_values[key] ~= nil end),
        metadata_method("TryGetValue", "System.Boolean", {
            { name = "System.Int32" },
            { name = "snow.Pad.Button", is_by_ref = true },
        }, false),
    }
end
function pad_dictionary_type:get_method(signature)
    for _, method in ipairs(self:get_methods()) do
        if signature == method:get_name() .. "(System.Int32)" then return method end
    end
end
local keyboard_dictionary = {
    get_type_definition = function() return keyboard_dictionary_type end,
}
local pad_dictionary = {
    get_type_definition = function() return pad_dictionary_type end,
}
local function dictionary_field(name, declared_type, is_static, object)
    return {
        get_name = function() return name end,
        get_type = function() return named_type(declared_type) end,
        is_static = function() return is_static end,
        get_data = function(_, owner)
            if is_static then
                assert(owner == nil, "static binding dictionary must use a nil owner")
            else
                assert(owner == input_config_instance,
                    "instance binding dictionary must use StmInputConfig singleton")
            end
            return object
        end,
    }
end
local main_dictionary_field = dictionary_field(
    "main_pl_Conf", keyboard_dictionary_type:get_full_name(), true, keyboard_dictionary)
local sub_dictionary_field = dictionary_field(
    "sub_pl_Conf", keyboard_dictionary_type:get_full_name(), true, keyboard_dictionary)
local pad_dictionary_field = dictionary_field(
    "pad_pl_Conf", pad_dictionary_type:get_full_name(), false, pad_dictionary)
local input_config_type = {
    get_full_name = function() return "snow.StmInputConfig" end,
    get_fields = function()
        return { main_dictionary_field, sub_dictionary_field, pad_dictionary_field }
    end,
    get_methods = function()
        return { main_method, byref_probe_method }
    end,
}
function input_config_type:get_field(name)
    if name == "main_pl_Conf" then return main_dictionary_field end
    if name == "sub_pl_Conf" then return sub_dictionary_field end
    if name == "pad_pl_Conf" then return pad_dictionary_field end
end
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
        if name == "snow.StmInputManager.PL_INPUT" then return player_input_enum end
        if name == "snow.StmInputManager.InGameMouseKeyBoardKey" then return keyboard_enum end
        if name == "snow.Pad.Button" then return pad_enum end
        if name == "snow.StmPlInputData" then return player_input_data_type end
        if name == "snow.StmInputConfig" then return input_config_type end
        if name == "snow.StmInputManager" then return stm_type end
        if name == "snow.StmPlayerInput" then return stm_player_input_type end
        if name == "snow.player.PlayerInput" then return player_input_type end
        if name == "snow.StmInputManager.InputUI" then return input_ui_type end
        if name == bitset_type:get_full_name() then return bitset_type end
    end,
    get_native_singleton = function() return {} end,
    call_native_func = function(_, _, name)
        if name == "get_LastInputDevice" then return device end
    end,
    get_managed_singleton = function(name)
        if name == "snow.StmInputManager" then return stm end
        if name == "snow.StmInputConfig" then return input_config_instance end
        if name == "snow.StmPlayerInput" then return stm_player_input_instance end
    end,
}
Vector2f = { new = function(x, y) return { x = x, y = y } end }

local Adapter = require("MHRiseMonsterCoach.input_motion_adapter")
local diagnostics = Adapter.new():diagnostics()
assert(diagnostics.schema_version == 8)
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
local active_input_device_method_found = false
for _, method in ipairs(diagnostics.stm_input_contract[1].methods) do
    if method.name == "get_ActiveInputDevice" then active_input_device_method_found = true end
end
assert(active_input_device_method_found)
assert(diagnostics.semantic_command_enum.available)
assert(#diagnostics.semantic_command_enum.values == 2)
assert(diagnostics.semantic_command_enum.values[1].name == "Attack")
assert(diagnostics.semantic_command_enum.values[1].value == 4)
assert(diagnostics.semantic_command_enum.values[2].name == "Evade")
local semantic = diagnostics.semantic_input_contract
assert(semantic.schema_version == 1)
assert(semantic.policy == "read_only_exact_semantic_input_metadata")
assert(semantic.gameplay_method_calls == 0 and semantic.gameplay_writes == 0)
assert(semantic.command_enum.available and #semantic.command_enum.values == 2)
assert(#semantic.types == 4)
assert(semantic.types[1].type == "snow.StmInputManager")
assert(semantic.types[1].singleton_lookup and semantic.types[1].instance_available)
assert(#semantic.types[1].semantic_query_methods == 6)
assert(semantic.types[1].semantic_query_methods[1].name == "getDelay")
assert(semantic.types[1].semantic_query_methods[2].name == "getOn")
assert(semantic.types[1].semantic_query_methods[3].name == "getRel")
assert(semantic.types[1].semantic_query_methods[4].name == "getTrg")
assert(semantic.types[1].semantic_query_methods[5].name == "isOn")
assert(semantic.types[1].semantic_query_methods[6].name == "isTrg")
assert(semantic.types[2].type == "snow.StmPlayerInput")
assert(semantic.types[2].singleton_lookup and semantic.types[2].instance_available)
assert(semantic.types[3].type == "snow.player.PlayerInput")
assert(not semantic.types[3].singleton_lookup and not semantic.types[3].instance_available)
assert(semantic.types[4].type == "snow.StmInputManager.InputUI")
assert(semantic_method_calls == 0, "semantic metadata contract is strictly read-only")
local bitsets = diagnostics.semantic_bitset_contract
assert(bitsets.schema_version == 1)
assert(bitsets.policy == "bounded_read_only_semantic_bitset_getters")
assert(bitsets.max_calls == 4 and bitsets.call_count == 4)
assert(bitsets.call_failures == 0 and bitsets.gameplay_writes == 0)
assert(bitsets.manager_type_available and bitsets.manager_instance_available)
assert(#bitsets.getters == 4)
for _, getter in ipairs(bitsets.getters) do
    assert(getter.status == "resolved")
    assert(getter.object_available)
    assert(getter.object_type == bitset_type:get_full_name())
    assert(getter.object_contract.available)
    assert(#getter.object_contract.methods == 2)
end
assert(semantic_read_calls == 4)
assert(bitset_mutator_calls == 0, "returned bitset methods are metadata-only")
assert(#diagnostics.input_enum_contracts == 9)
assert(diagnostics.input_enum_contracts[1].values[2].name == "GamePad")
assert(diagnostics.input_enum_contracts[2].available == false)
assert(#diagnostics.input_enum_contracts[2].values == 0)
assert(diagnostics.known_type_contracts[1].available)
assert(diagnostics.known_type_contracts[1].fields[1].name == "_CommandButton")
assert(diagnostics.known_type_contracts[1].methods[1].name == "isCommandTrg")
local binding_method = diagnostics.known_type_contracts[2].methods[1]
assert(binding_method.name == "TryGet_main_pl_Conf")
assert(binding_method.is_static == true)
assert(#binding_method.params == 2)
assert(binding_method.params[1].index == 0 and binding_method.params[1].name == "key")
assert(binding_method.params[1].type == "snow.StmInputManager.PL_INPUT")
assert(binding_method.params[1].is_by_ref == false)
assert(binding_method.params[2].index == 1 and binding_method.params[2].name == "valueData")
assert(binding_method.params[2].type == "snow.StmInputManager.InGameMouseKeyBoardKey")
assert(binding_method.params[2].is_by_ref == false)
local byref_method = diagnostics.known_type_contracts[2].methods[2]
assert(byref_method.params[2].is_by_ref == true, "by-ref metadata remains observable")
assert(diagnostics.known_type_hierarchies[1].available)
assert(#diagnostics.known_type_hierarchies[1].levels == 1)
assert(diagnostics.known_type_hierarchies[1].levels[1].type == "snow.StmPlInputData")
local dictionaries = diagnostics.binding_dictionaries
assert(dictionaries.policy == "read_only_exact_dictionary_metadata")
assert(dictionaries.config_type_available and dictionaries.config_instance_available)
assert(#dictionaries.fields == 4)
assert(dictionaries.fields[1].role == "main_keyboard")
assert(dictionaries.fields[1].available and dictionaries.fields[1].is_static)
assert(dictionaries.fields[1].object_available)
assert(dictionaries.fields[1].declared_type == keyboard_dictionary_type:get_full_name())
assert(dictionaries.fields[1].object_type == keyboard_dictionary_type:get_full_name())
assert(#dictionaries.fields[1].methods == 3, "only allow-listed read methods are exposed")
assert(dictionaries.fields[1].methods[1].name == "ContainsKey")
assert(dictionaries.fields[1].methods[2].name == "get_Count")
assert(dictionaries.fields[1].methods[3].name == "get_Item")
assert(dictionaries.fields[3].role == "player_pad")
assert(dictionaries.fields[3].available and not dictionaries.fields[3].is_static)
assert(dictionaries.fields[3].object_type == pad_dictionary_type:get_full_name())
assert(dictionaries.fields[3].methods[1].name == "ContainsKey")
assert(dictionaries.fields[3].methods[2].name == "TryGetValue")
assert(dictionaries.fields[3].methods[2].params[2].is_by_ref)
assert(dictionaries.fields[4].role == "static_pad")
assert(not dictionaries.fields[4].available and not dictionaries.fields[4].object_available)
local current = diagnostics.current_bindings
assert(current.policy == "read_only_exact_dictionary_lookup")
assert(current.call_count == 24 and current.max_calls == 24)
assert(current.call_failures == 0 and current.value_failures == 0 and not current.truncated)
assert(#current.targets == 4)
assert(current.targets[1].role == "evade")
assert(current.targets[1].main.name == "KeyEscape")
assert(current.targets[2].main.name == "MouseLeft" and current.targets[2].pad.name == "PadX")
assert(current.targets[3].main.name == "MouseRight" and current.targets[3].pad.name == "PadA")
assert(current.targets[4].main.name == "MouseSide" and current.targets[4].pad.name == "PadR")
assert(dictionary_method_calls == 24, "only bounded dictionary lookups are invoked")
local cached_adapter = Adapter.new()
cached_adapter:diagnostics()
local calls_after_first_snapshot = dictionary_method_calls
local semantic_reads_after_first_snapshot = semantic_read_calls
cached_adapter:diagnostics()
assert(dictionary_method_calls == calls_after_first_snapshot,
    "current binding lookup is cached per adapter")
assert(semantic_read_calls == semantic_reads_after_first_snapshot,
    "semantic bitset getters are cached per adapter")
local adapter = Adapter.new()
assert(adapter:write_axis(0, 1))
assert(adapter:diagnostics().owned and adapter:diagnostics().request_count == 1)
assert(adapter:flush() and adapter:diagnostics().write_count == 1)
assert(adapter:release())
assert(adapter:diagnostics().owned, "release remains owned until zero-axis flush")
assert(adapter:flush())
assert(not adapter:diagnostics().owned and adapter:diagnostics().write_count == 2)
print("test_input_motion_adapter.lua: PASS")
