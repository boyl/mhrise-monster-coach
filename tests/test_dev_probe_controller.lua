package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Probe = require("MHRiseMonsterCoach.dev_probe_controller")

local context = { in_quest = false, is_online = false, build_supported = true, player_found = true }
local request = { session_id = "probe-1", kind = "environment_creature_lifecycle" }
local reports, observed, spawned, reset_calls = {}, 0, 0, 0
local quest_api = {}
function quest_api:request_reset() reset_calls = reset_calls + 1 return true end
function quest_api:is_hub_ready() return true end
function quest_api:open_counter() return true end
function quest_api:start_session() return true end
function quest_api:tick_posting() return true end
function quest_api:select_quest() return true end
function quest_api:update_posting() return true end
function quest_api:is_counter_closed() return true end
function quest_api:depart() return true end
function quest_api:finish_posting() end
function quest_api:cancel_posting() end

local api = { quest_api = quest_api }
function api:get_context() return context end
function api:read_request() local value = request request = nil return value end
function api:write_report(report) reports[#reports + 1] = report end
function api:observe_environment() observed = observed + 1 return true end
function api:spawn_environment_probe() spawned = spawned + 1 return true, "bird-1" end
function api:environment_evidence() return { revision = observed } end

local probe = Probe.new(api, 200032001, {
    hub_stable_frames = 1, stable_frames = 2, collect_wait_frames = 2,
    quest_timeout_frames = 60,
})
probe.frame = 60
probe:update()
assert(probe.state == "launching", "request starts automatic hub launch")
for _ = 1, 7 do probe:update() end
context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
for _ = 1, 4 do probe:update() end
assert(spawned == 1 and probe.state == "wait_collection", "stable quest spawns one owned probe")
for _ = 1, 2 do probe:update() end
assert(reset_calls == 1 and probe.state == "restarting", "probe uses the proven native restart")
context = { in_quest = false, is_online = false, build_supported = true }
for _ = 1, 8 do probe:update() end
context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
for _ = 1, 4 do probe:update() end
assert(#reports == 1 and reports[1].status == "completed", "completed report is emitted automatically")
assert(reports[1].probe_key == "bird-1" and probe.state == "idle", "report binds evidence to the owned probe")

print("test_dev_probe_controller.lua: PASS")
