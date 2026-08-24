package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local dumped = {}
local dump_counts = {}
json = { dump_file = function(path, value)
    dumped[path] = value
    dump_counts[path] = (dump_counts[path] or 0) + 1
end }

local current_node = 200
local active_tags = { [1] = true, [2] = false, [3] = false }

local function field(name, value)
    return { get_data = function() return value end, get_name = function() return name end }
end

local act_status_type = {
    get_field = function(_, name)
        local values = { Attack = 1, Escape = 2, Damage = 3, Jump = 4, WireJump = 5, Ride = 6 }
        return values[name] and field(name, values[name]) or nil
    end,
}

local node_method = {
    call = function() return current_node end,
}
local tree_nodes = {
    { get_id = function() return 200 end, get_full_name = function() return "LongSword/Idle" end },
    { get_id = function() return 201 end, get_full_name = function() return "LongSword/Escape" end },
}
local tree = {
    -- Player MotionFsm2 can expose the active node by ID while reporting no
    -- enumerable nodes.  The reader must resolve the current node directly.
    get_node_count = function() return 0 end,
    get_node = function(_, index) return tree_nodes[index + 1] end,
    get_node_by_id = function(_, id)
        for _, node in ipairs(tree_nodes) do
            if node:get_id() == id then return node end
        end
    end,
}
local layer = { get_tree_object = function() return tree end }
local motion_type = {
    get_method = function(_, name)
        if name == "getCurrentNodeID(System.Int32)" then return node_method end
    end,
    get_full_name = function() return "via.motion.MotionFsm2" end,
}
local motion = {
    get_type_definition = function() return motion_type end,
    get_address = function() return 12345 end,
    call = function(_, method, index)
        if method == "getLayer" and index == 0 then return layer end
    end,
}

local motion_getter = {
    get_name = function() return "getMotionFsm2" end,
    call = function() return motion end,
}
local status_method = {
    get_name = function() return "isActionStatusTag(snow.player.ActStatus)" end,
    call = function(_, _, tag) return active_tags[tag] == true end,
}
local player_type = {
    get_full_name = function() return "snow.player.LongSwordPlayer" end,
    get_parent_type = function() return nil end,
    get_method = function(_, name)
        if name == "getMotionFsm2" then return motion_getter end
        if name == "isActionStatusTag(snow.player.ActStatus)" then return status_method end
    end,
}
local player = { get_type_definition = function() return player_type end }

sdk = {
    find_type_definition = function(name)
        if name == "snow.player.ActStatus" then return act_status_type end
    end,
}

package.loaded["MHRiseMonsterCoach.player_action_reader"] = nil
local Reader = require("MHRiseMonsterCoach.player_action_reader")
local reader = Reader.new("mhrise", 71, 3, 1)

assert(reader:capture(player) == true)
assert(reader.state.availability == "available" and reader.state.node_id == 200)
assert(reader.state.node_name == "LongSword/Idle")
assert(reader.state.tags.attack == true and reader.state.tags.escape == false)
assert(reader.state.tags.guard == nil, "missing enum values remain unknown rather than false")
assert(reader:capture(player) == false, "stable snapshots are deduplicated")

current_node = 201
active_tags[1] = false
active_tags[2] = true
assert(reader:capture(player) == true)
local evidence = dumped["MHRiseMonsterCoach/runtime_player_action_evidence.json"]
assert(evidence.reader.polling_only == true and evidence.reader.hook_installed == false)
assert(evidence.current.node_id == 201 and evidence.current.tags.escape == true)
assert(evidence.current.node_name == "LongSword/Escape")
assert(evidence.reader.node_catalog_count == 2)
assert(#evidence.node_catalog == 2 and evidence.node_catalog[1].id == "200")
assert(#evidence.events == 2 and evidence.events[2].sample == 3)
assert(reader:description().revision == 2)

current_node = 200
active_tags[1] = true
active_tags[2] = false
local throttled = Reader.new("mhrise", 71, 8, 3)
assert(throttled:capture(player) == true)
local evidence_path = "MHRiseMonsterCoach/runtime_player_action_evidence.json"
local initial_dumps = dump_counts[evidence_path]
current_node = 201
assert(throttled:capture(player) == true)
assert(dump_counts[evidence_path] == initial_dumps, "a rapid action change remains memory-only")
assert(throttled:capture(player) == false)
assert(throttled:capture(player) == false)
assert(dump_counts[evidence_path] == initial_dumps + 1,
    "stable frames flush the final dirty transition at the bounded interval")

reader:suspend("transition")
assert(reader.state == nil and reader.status == "transition")

print("test_player_action_reader.lua: PASS")
