local Reader = require("MHRiseMonsterCoach.think_context_reader")

local function object(fields, calls, type_name)
    local value = {}
    function value:get_field(name) return fields and fields[name] or nil end
    function value:call(name, ...)
        local fn = calls and calls[name]
        return fn and fn(...) or nil
    end
    function value:get_address() return type_name .. "_address" end
    function value:get_type_definition()
        return { get_full_name = function() return type_name end }
    end
    return value
end

local action = object(nil, nil, "snow.enemy.action.Attack")
local condition = object(nil, nil, "snow.enemy.condition.Distance")
local function collection(values)
    return object(nil, {
        get_Count = function() return #values end,
        get_Item = function(index) return values[index + 1] end,
    }, "collection")
end
local state = object(nil, {
    get_ID = function() return 7 end,
    get_TreeNodeID = function() return 42 end,
    get_HasReferenceThinkData = function() return false end,
    get_ActionList = function() return collection({ action }) end,
    get_ConditionList = function() return collection({ condition }) end,
}, "snow.enemy.ThinkState")
local info = object(nil, {
    get_CurrentStateNo = function() return 7 end,
    get_IsCallStart = function() return true end,
    get_CurrentState = function() return state end,
    get_StateList = function() return collection({ state }) end,
}, "snow.enemy.EnemyThinkBehavior.ThinkInfoData")
local behavior = object(nil, { getCurrentStateInfo = function() return info end }, "snow.enemy.EnemyThinkBehavior")
local character = object({ ["<RefEnemyThinkBehavior>k__BackingField"] = behavior }, nil, "enemy")

local result = Reader.read(character, true)
assert(result.available and result.current_state_no == 7 and result.current_state.tree_node_id == 42)
assert(result.state_count == 1 and result.states[1].action_types[1] == "snow.enemy.action.Attack")
assert(result.states[1].condition_types[1] == "snow.enemy.condition.Distance")
print("test_think_context_reader.lua: PASS")
