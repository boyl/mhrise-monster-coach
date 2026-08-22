local Tracker = require("MHRiseMonsterCoach.behavior_path_tracker")

local tracker = Tracker.new(8)
local snapshot = { layers = { { layer = 0, active_nodes = {
    { id = "1", index = 1, name = "Attack", status1 = 2, status2 = 2 },
    { id = "2", index = 2, name = "Attack.Roar", status1 = 2, status2 = 2 },
    { id = "3", index = 3, name = "Move.Dash.End", status1 = 0, status2 = 2 },
} } } }
assert(tracker:sample(10, snapshot, { category = 4, action = 19, motion_name = "TigRoar_R" }))
assert(tracker.events[1].node.name == "Attack.Roar", "status1 active node wins over stale status2")
assert(not tracker:sample(11, snapshot, { category = 4, action = 19, motion_name = "TigRoar_R" }),
    "unchanged FSM and Action state is deduplicated")
tracker:sample(12, snapshot, { category = 1, action = 8, motion_name = "Idle" })
assert(#tracker.events == 2 and tracker.events[2].action.action == 8,
    "an Action transition at the same FSM node is retained for correlation")
print("test_behavior_path_tracker.lua: PASS")
