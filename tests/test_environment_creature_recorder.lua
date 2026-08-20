package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Recorder = require("MHRiseMonsterCoach.environment_creature_recorder")
local recorder = Recorder.new(3)

recorder:observe({ { key = "1", type_name = "Ec013", values = { active = true } } }, { frame = 1 })
assert(recorder.revision == 1 and recorder.events[1].kind == "appeared", "first instance appears")

recorder:observe({ { key = "1", type_name = "Ec013", values = { active = true } } }, { frame = 2 })
assert(recorder.revision == 1, "unchanged samples do not create noise")

recorder:observe({ { key = "1", type_name = "Ec013", values = { active = false } } }, { frame = 3 })
assert(recorder.revision == 2 and recorder.events[2].kind == "changed", "primitive state changes are recorded")

recorder:observe({}, { frame = 4 })
assert(recorder.revision == 3 and recorder.events[3].kind == "disappeared", "removed instances are recorded")

recorder:observe({ { key = "2", type_name = "Ec014", values = {} } }, { frame = 5 })
assert(#recorder.events == 3 and recorder.events[3].entry.key == "2", "history is bounded")
assert(#recorder:export().observed_types == 2, "observed types persist across disappearance")

print("test_environment_creature_recorder.lua: PASS")
