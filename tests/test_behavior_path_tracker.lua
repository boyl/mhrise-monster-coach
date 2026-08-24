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

local sticky = Tracker.new(8)
sticky:sample(20, { layers = { { layer = 0, active_nodes = {
    { id = "bite0", name = "Attack.CheckBite.Phase00", status1 = 2 },
} } } }, { category = 4, action = 29, motion_name = "FrontContainBite_Start_L" })
sticky:sample(21, { layers = { { layer = 0, active_nodes = {
    { id = "bite1", name = "Attack.CheckBite.Phase01", status1 = 2 },
} } } }, { category = 4, action = 29, motion_name = "em032_00_08274" })
assert(not sticky:attack_cycle_completed_since(20),
    "moving between attack phases does not complete the attack")
sticky:sample(22, { layers = { { layer = 0, active_nodes = {
    { id = "search", name = "Normal.Search.Phase00", status1 = 2 },
} } } }, { category = 4, action = 29, motion_name = "em032_00_08274" })
assert(sticky:attack_cycle_completed_since(20),
    "a known non-attack node completes a sticky-ActionNo attack lifecycle")

local stale_motion = Tracker.new(8)
stale_motion:sample(30, { layers = { { layer = 0, active_nodes = {
    { id = "wait", name = "Wait.NoCombatMode", status1 = 2 },
} } } }, { category = 4, action = 29, motion_name = "em042_00_00003_Loop" })
assert(not stale_motion:attack_cycle_completed_since(30),
    "a stale motion and ActionNo cannot complete a cycle unless Attack was observed first")
print("test_behavior_path_tracker.lua: PASS")
