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
        return {
            get_full_name = function() return type_name end,
            get_field = function(_, name)
                if fields == nil or fields[name] == nil then return nil end
                return { get_data = function() return fields[name] end }
            end,
            get_parent_type = function() return nil end,
        }
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

local requested_state = nil
local root_action = object({ _ActionNo = 5000 }, nil, "root-action")
local successor_action = object({ _ActionNo = 5001 }, nil, "successor-action")
local combo_root_state = object(nil, {
    get_ID = function() return 8 end,
    get_ActionList = function() return collection({ root_action }) end,
}, "snow.enemy.ThinkState")
local combo_successor_state = object(nil, {
    get_ID = function() return 6 end,
    get_ActionList = function() return collection({ successor_action }) end,
}, "snow.enemy.ThinkState")
local reference = object(nil, {
    get_Path = function() return "enemy/em032/combo/em032_combo_001.user" end,
    get_StateList = function() return collection({ combo_root_state, combo_successor_state }) end,
}, "think-data")
local reference_state = object(nil, {
    get_ID = function() return 6 end,
    get_TreeNodeID = function() return 99 end,
    get_ReferenceThinkData = function() return reference end,
}, "snow.enemy.ThinkState")
local reference_info = object(nil, {
    get_CurrentStateNo = function() return 1 end,
    get_CurrentState = function() return reference_state end,
    get_StateList = function() return collection({ reference_state }) end,
    setState = function(id) requested_state = id end,
}, "snow.enemy.EnemyThinkBehavior.ThinkInfoData")
local reference_behavior = object(nil, {
    getCurrentStateInfo = function() return reference_info end,
}, "snow.enemy.EnemyThinkBehavior")
local reference_character = object({
    ["<RefEnemyThinkBehavior>k__BackingField"] = reference_behavior,
}, nil, "enemy")
local ok, contract = Reader.request_reference_state(reference_character, "em032_combo_001.user")
assert(ok and requested_state == 6 and contract.tree_node_id == 99)

local jumped_data = nil
local started_info = nil
local root_state = object(nil, {
    get_ReferenceThinkData = function() return reference end,
}, "snow.enemy.ThinkState")
local jumped_info = object(nil, {}, "snow.enemy.EnemyThinkBehavior.ThinkInfoData")
function jumped_info:call(name, ...)
    if name == "get_StateList" then return collection({ combo_root_state, combo_successor_state }) end
    if name == "setState" then requested_state = ... return end
end
local jump_behavior = object({
    _MainThinkStateList = collection({ root_state }),
}, {
    getCurrentStateInfo = function() return info end,
    nextJumpThinkData = function(data) jumped_data = data return jumped_info end,
    startActionTable = function(value) started_info = value end,
}, "snow.enemy.EnemyThinkBehavior")
local jump_character = object({
    ["<RefEnemyThinkBehavior>k__BackingField"] = jump_behavior,
}, nil, "enemy")
local jump_ok, jump_contract = Reader.request_reference_state(jump_character, "em032_combo_001.user")
assert(jump_ok and jumped_data == reference and started_info == jumped_info
    and requested_state == 8
    and jump_contract.mode == "next_jump_set_validated_state_and_start")
