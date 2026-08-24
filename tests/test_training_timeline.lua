package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Timeline = require("MHRiseMonsterCoach.training_timeline")

local timeline = Timeline.new(8)
assert(timeline:start(10, { action = "2", state_key = "4:2" }))
assert(timeline:record("hitbox_open", nil, { motion_frame = 20 }))
assert(timeline:record("damage", nil, { motion_frame = 24, damage = 15 }))
assert(timeline:record("player_action", nil, { semantic = "foresight_slash", role = "attempt" }))
assert(timeline:has_event("damage"))
assert(timeline:record("hitbox_close", nil, { motion_frame = 28 }))
assert(timeline:finish(11, "hit", { damage = 15 }))

local snapshot = timeline:snapshot()
assert(snapshot.active == false)
assert(snapshot.revision == 1)
assert(snapshot.last_round.outcome == "hit")
assert(#snapshot.last_round.events == 6)
assert(snapshot.last_round.events[1].kind == "action_start")
assert(snapshot.last_round.events[6].kind == "result")

snapshot.last_round.events[1].data.action = "mutated"
assert(timeline:snapshot().last_round.events[1].data.action == "2")

local ok, reason = timeline:record("player_input", nil, {})
assert(ok == false and reason == "unsupported_event_kind")
ok, reason = timeline:record("damage", nil, {})
assert(ok == false and reason == "timeline_inactive")

timeline:start(20, { action = "10" })
for index = 1, 12 do
    timeline:record("damage", nil, { index = index })
end
local active = timeline:snapshot()
assert(#active.events == 8)
assert(active.dropped_events == 5)
assert(active.events[1].sequence == 6)

timeline:start(21, { action = "15" })
assert(timeline:snapshot().last_round.outcome == "interrupted")
timeline:finish(22, "unclassified")
timeline:reset("quest_reset")
assert(timeline:snapshot().last_round.outcome == "unclassified")
timeline:reset("full_clear", true)
assert(timeline:snapshot().last_round == nil)
assert(timeline:snapshot().revision == 4)

print("test_training_timeline.lua: PASS")
