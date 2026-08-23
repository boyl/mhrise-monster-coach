package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Observer = require("MHRiseMonsterCoach.player_action_observer")
local observer = Observer.new(2)

assert(observer:sample(10, {
    availability = "available", node_id = 100, node_name = "Attack/A", source = "test", tags = { attack = true },
}) == true)
assert(observer:sample(11, {
    availability = "available", node_id = 100, node_name = "Attack/A", source = "test", tags = { attack = true },
}) == false, "identical evidence does not create per-frame noise")
assert(observer:sample(12, {
    availability = "available", node_id = 101, source = "test", tags = { escape = true },
}) == true)
assert(observer:sample(13, {
    availability = "partial", node_id = nil, source = "test", tags = { damage = true },
}) == true)

local result = observer:result()
assert(result.policy == "read_only_bounded_player_action_evidence")
assert(result.revision == 3 and result.dropped_events == 1)
assert(#result.events == 2 and result.events[1].sample == 12 and result.events[2].sample == 13)
assert(result.current.tags.damage == true)
assert(type(result.current.unavailable) == "table")

local unavailable = Observer.new(4)
assert(unavailable:sample(1, { availability = "unavailable", reason = "no player" }) == false)
assert(#unavailable:result().events == 0, "unavailable frames do not pollute transition evidence")

print("test_player_action_observer.lua: PASS")
