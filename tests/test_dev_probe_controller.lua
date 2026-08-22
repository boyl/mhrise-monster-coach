package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Probe = require("MHRiseMonsterCoach.dev_probe_controller")

local context = { in_quest = false, is_online = false, build_supported = true, player_found = true }
local request = {
    session_id = "probe-1", kind = "environment_creature_lifecycle", allow_spawn_probe = true,
}
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
function api:area_snapshot() return {} end

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

local retry_context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
local retry_attempts = 0
local retry_api = { quest_api = quest_api }
function retry_api:get_context() return retry_context end
function retry_api:read_request() return nil end
function retry_api:write_report() end
function retry_api:observe_environment() return true end
function retry_api:spawn_environment_probe()
    retry_attempts = retry_attempts + 1
    if retry_attempts < 3 then return false, "Environment creature prefab list unavailable" end
    return true, "bird-after-init"
end
function retry_api:environment_evidence() return {} end
function retry_api:area_snapshot() return {} end

local retry_probe = Probe.new(retry_api, 200032001, {
    stable_frames = 1, spawn_retry_interval_frames = 2, spawn_timeout_frames = 10,
})
retry_probe.request = { session_id = "probe-retry", kind = "environment_creature_lifecycle" }
retry_probe.request.allow_spawn_probe = true
retry_probe:set_state("wait_stable")
for _ = 1, 6 do retry_probe:update() end
assert(retry_attempts == 3 and retry_probe.state == "wait_collection",
    "transient prefab initialization is retried without aborting the session")
assert(retry_probe.probe_key == "bird-after-init", "retry preserves the successful probe identity")

local passive_observations = 0
local passive_api = { quest_api = quest_api }
function passive_api:get_context() return retry_context end
function passive_api:read_request() return nil end
function passive_api:write_report() end
function passive_api:observe_environment() passive_observations = passive_observations + 1 return true end
function passive_api:spawn_environment_probe() error("passive probe must not spawn") end
function passive_api:environment_evidence() return {} end
function passive_api:area_snapshot() return {} end
local passive_probe = Probe.new(passive_api, 200032001, { stable_frames = 1 })
passive_probe.request = { session_id = "probe-passive", kind = "environment_creature_lifecycle" }
passive_probe:set_state("wait_stable")
passive_probe:update()
assert(passive_probe.state == "wait_collection" and passive_observations == 1,
    "default automation uses passive observation without unsafe prefab access")

local layer_snapshot = {
    player = 1, enemy = -1, same_area = false, combat_layer = false,
    player_enemy_vertical_gap = 569.0,
}
local layer_observations = 0
local layer_api = { quest_api = quest_api }
function layer_api:get_context() return retry_context end
function layer_api:read_request() return nil end
function layer_api:write_report() end
function layer_api:observe_environment() layer_observations = layer_observations + 1 return true end
function layer_api:environment_evidence() return {} end
function layer_api:area_snapshot() return layer_snapshot end
local layer_probe = Probe.new(layer_api, 200032001, { stable_frames = 1 })
layer_probe.request = {
    session_id = "probe-combat-layer", kind = "environment_creature_lifecycle",
    require_combat_area = true,
}
layer_probe:set_state("wait_stable")
layer_probe:update()
assert(layer_probe.state == "wait_stable" and layer_observations == 0,
    "preparation layer cannot satisfy the combat-area gate")
layer_snapshot = {
    player = 0, enemy = -1, same_area = false, combat_layer = true,
    player_enemy_vertical_gap = 1.16435,
}
layer_probe:update()
assert(layer_probe.state == "wait_collection" and layer_observations == 1,
    "scene-layer evidence satisfies the combat gate despite mismatched native area numbers")

local forced_context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
local forced_current = { category = 0, action = 0 }
local forced_calls, forced_reports = {}, {}
local forced_api = { quest_api = quest_api }
function forced_api:get_context() return forced_context end
function forced_api:read_request() return nil end
function forced_api:write_report(report) forced_reports[#forced_reports + 1] = report end
function forced_api:environment_evidence() return {} end
function forced_api:area_snapshot() return {} end
function forced_api:action_request_evidence() return { calls = #forced_calls } end
function forced_api:request_forced_action(action)
    forced_calls[#forced_calls + 1] = action
    forced_current = { category = 4, action = action, motion_name = "forced_" .. action }
    return true
end
function forced_api:current_action() return forced_current end
local forced_probe = Probe.new(forced_api, 200032001, { stable_frames = 1 })
forced_probe.request = { session_id = "forced-sequence", kind = "forced_action_sequence" }
forced_probe.forced_actions = { 19, 20 }
forced_probe.forced_index = 1
forced_probe:set_state("forced_prepare")
for index = 1, 2 do
    forced_probe:update()
    forced_probe:update()
    assert(forced_probe.state == "forced_wait_exit", "forced Action is verified from the live reader")
    forced_current = { category = 0, action = 0 }
    for _ = 1, 10 do forced_probe:update() end
end
forced_probe:update()
assert(#forced_calls == 2 and forced_calls[1] == 19 and forced_calls[2] == 20,
    "a forced sequence runs every allowlisted action once")
assert(forced_reports[#forced_reports].status == "completed",
    "forced sequence produces one aggregate completion report")
assert(forced_reports[#forced_reports].forced_actions.results[1].status == "completed",
    "forced report retains per-action verification evidence")

local batch_probe = Probe.new(forced_api, 200032001, { stable_frames = 1 })
batch_probe.request = {
    session_id = "forced-batch", kind = "forced_action_sequence",
    continue_on_action_failure = true,
}
batch_probe.forced_actions = { 20, 21 }
batch_probe.forced_index = 1
batch_probe.forced_results = {
    { action = 20, status = "failed", reason = "did not finish" },
}
batch_probe.forced_failure_count = 1
layer_snapshot = { combat_layer = true }
function forced_api:area_snapshot() return layer_snapshot end
batch_probe.forced_error = "Action 20 did not finish"
batch_probe:set_state("forced_recovery_verify")
batch_probe:update()
assert(batch_probe.state == "forced_prepare" and batch_probe.forced_index == 2,
    "batch probe continues with the next action after a verified safe recovery")
assert(batch_probe.forced_results[1].recovered == true,
    "batch probe records that the failed action was isolated by F7 recovery")

local training_reports = {}
local training_status = { state = "waiting", status = "waiting", completed_rounds = 0, target_rounds = 3 }
local training_api = { quest_api = quest_api }
function training_api:get_context() return forced_context end
function training_api:read_request() return nil end
function training_api:write_report(report) training_reports[#training_reports + 1] = report end
function training_api:environment_evidence() return {} end
function training_api:area_snapshot() return { combat_layer = true } end
function training_api:start_training_acceptance(id, count)
    assert(id == "tigrex_roar_single" and count == 3)
    return true
end
function training_api:training_acceptance_status() return training_status end
function training_api:finish_training_acceptance() training_api.finished = true end
local training_probe = Probe.new(training_api, 200032001, { stable_frames = 1 })
training_probe.request = {
    session_id = "training-acceptance", kind = "training_scenario_acceptance",
    training_scenario_id = "tigrex_roar_single", training_repeat_count = 3,
}
training_probe:set_state("wait_stable")
training_probe:update()
assert(training_probe.state == "training_acceptance_wait",
    "product-path acceptance starts the real training controller after the combat gate")
training_status = { state = "completed", status = "训练完成：3/3",
    completed_rounds = 3, target_rounds = 3 }
training_probe:update()
assert(training_reports[#training_reports].status == "completed"
    and training_reports[#training_reports].training_acceptance.completed_rounds == 3,
    "product-path acceptance reports the controller's exact completed repeat count")
assert(training_api.finished == true, "acceptance restores temporary training configuration")

print("test_dev_probe_controller.lua: PASS")
