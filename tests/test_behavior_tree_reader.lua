local original_sdk = sdk

local active_leaf = {
    get_status1 = function() return 2 end,
    get_status2 = function() return 0 end,
    get_children = function() return {} end,
    get_id = function() return 77 end,
    get_full_name = function() return "Attack/Combo/Root" end,
}
local inactive = {
    get_status1 = function() return 0 end,
    get_status2 = function() return 0 end,
}
local tree = {
    get_address = function() return 200 end,
    get_node_count = function() return 2 end,
    get_node = function(_, index) return index == 0 and inactive or active_leaf end,
}
local layer = {
    get_address = function() return 100 end,
    get_tree_object = function() return tree end,
}
local component = {
    get_address = function() return 50 end,
    call = function(_, method, index)
        if method == "getLayerCount" then return 1 end
        if method == "getLayer" and index == 0 then return layer end
    end,
}
local character = {
    call = function(_, method) if method == "getComponent(System.Type)" then return component end end,
}
sdk = { typeof = function() return {} end }

package.loaded["MHRiseMonsterCoach.behavior_tree_reader"] = nil
local Reader = require("MHRiseMonsterCoach.behavior_tree_reader")
local snapshot = Reader.read(character)
assert(snapshot.available == true)
assert(snapshot.host == "character")
assert(snapshot.layer_count == 1)
assert(#snapshot.layers[1].active_nodes == 1)
assert(snapshot.layers[1].active_nodes[1].id == "77")
assert(snapshot.layers[1].active_nodes[1].name == "Attack/Combo/Root")
assert(snapshot.layers[1].active_nodes[1].leaf == true)

sdk = original_sdk
print("test_behavior_tree_reader.lua: PASS")
