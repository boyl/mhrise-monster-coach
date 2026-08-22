local Recorder = require("MHRiseMonsterCoach.behavior_graph_recorder")

local recorder = Recorder.new(16)
local function snapshot(id, name)
    return { layers = { { layer = 0, active_nodes = {
        { id = id, index = tonumber(id), name = name, status1 = 2, status2 = 2 },
    } } } }
end
recorder:sample(1, snapshot("1", "Attack.Root.Phase00"), { category = 4, action = 10 }, { current_state_no = 7 })
recorder:sample(2, snapshot("1", "Attack.Root.Phase00"), { category = 4, action = 10 })
recorder:sample(3, snapshot("2", "Attack.Root.Phase01"), { category = 4, action = 10 })
recorder:sample(4, snapshot("3", "Move.Dash"), { category = 1, action = 8 })
local graph = recorder:result()
assert(graph.samples == 4 and #graph.events == 3)
assert(#graph.nodes == 3 and #graph.edges == 2)
assert(graph.edges[1].observations == 1)
assert(graph.nodes[1].think_contexts["nil:7:nil"] == 1)
local catalog_recorder = Recorder.new(4)
catalog_recorder:sample(1, snapshot("1", "Attack.Root.Phase00"), {}, {
    info_address = "info-a", current_state_no = 7, states = { { id = 7 } }, state_count = 1,
})
assert(#catalog_recorder:result().think_catalogs == 1)
assert(graph.policy == "observed_candidates_only_not_deterministic")
print("test_behavior_graph_recorder.lua: PASS")
