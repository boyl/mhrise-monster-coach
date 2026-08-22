local M = {}

local function attempt(fn)
    local ok, value = pcall(fn)
    return ok and value or nil
end

local function address(value)
    return value and tostring(attempt(function() return value:get_address() end)) or nil
end

local function node_snapshot(node, index)
    if node == nil then return nil end
    local status1 = tonumber(attempt(function() return node:get_status1() end))
    local status2 = tonumber(attempt(function() return node:get_status2() end))
    if status1 ~= 2 and status2 ~= 2 then return nil end
    local children = attempt(function() return node:get_children() end)
    local child_count = children and attempt(function() return #children end) or nil
    return {
        index = index,
        id = tostring(attempt(function() return node:get_id() end)),
        name = attempt(function() return node:get_full_name() end),
        status1 = status1,
        status2 = status2,
        child_count = child_count,
        leaf = child_count == 0,
    }
end

local function read_tree(layer, layer_index)
    local tree = attempt(function() return layer:get_tree_object() end)
    if tree == nil then return nil end
    local count = tonumber(attempt(function() return tree:get_node_count() end))
    if count == nil or count < 0 or count > 4096 then
        return { layer = layer_index, layer_address = address(layer), tree_address = address(tree), error = "invalid_node_count" }
    end
    local active = {}
    for index = 0, count - 1 do
        local snapshot = node_snapshot(attempt(function() return tree:get_node(index) end), index)
        if snapshot ~= nil then active[#active + 1] = snapshot end
    end
    return {
        layer = layer_index,
        layer_address = address(layer),
        tree_address = address(tree),
        node_count = count,
        active_nodes = active,
    }
end

function M.read(character)
    local result = { available = false, policy = "read_only_motion_fsm_active_nodes", layers = {} }
    if character == nil or sdk == nil then return result end
    local component_type = attempt(function() return sdk.typeof("via.motion.MotionFsm2") end)
    local host = character
    local motion_fsm = component_type and attempt(function()
        return host:call("getComponent(System.Type)", component_type)
    end) or nil
    if motion_fsm == nil then
        local game_object = attempt(function() return character:call("get_GameObject") end)
        if game_object ~= nil then
            host = game_object
            result.game_object_address = address(game_object)
            motion_fsm = attempt(function()
                return host:call("getComponent(System.Type)", component_type)
            end)
        end
    end
    if motion_fsm == nil then
        result.reason = "MotionFsm2 component unavailable"
        return result
    end
    result.available = true
    result.host = host == character and "character" or "game_object"
    result.component_address = address(motion_fsm)
    local count = tonumber(attempt(function() return motion_fsm:call("getLayerCount") end))
    if count == nil or count < 0 or count > 32 then
        result.available = false
        result.reason = "Invalid MotionFsm2 layer count"
        return result
    end
    result.layer_count = count
    for index = 0, count - 1 do
        local layer = attempt(function() return motion_fsm:call("getLayer", index) end)
        if layer ~= nil then result.layers[#result.layers + 1] = read_tree(layer, index) end
    end
    return result
end

return M
