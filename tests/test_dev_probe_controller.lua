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
local terminal_reports = {}
for _, report in ipairs(reports) do
    if report.status == "completed" or report.status == "failed" then
        terminal_reports[#terminal_reports + 1] = report
    end
end
assert(#terminal_reports == 1 and terminal_reports[1].status == "completed",
    "one completed terminal report is emitted automatically")
assert(terminal_reports[1].probe_key == "bird-1" and probe.state == "idle",
    "terminal report binds evidence to the owned probe")

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
function forced_api:behavior_tree_snapshot()
    return { layers = { { layer = 0, active_nodes = {
        { id = tostring(forced_current.action), index = forced_current.action,
            name = "Attack.Test." .. tostring(forced_current.action), status1 = 2, status2 = 2 },
    } } } }
end
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
assert(forced_reports[#forced_reports].forced_actions.results[1].exit_to.action == 0,
    "forced report records the live successor observed when the requested root exits")
assert(#forced_reports[#forced_reports].forced_actions.results[1].behavior_path.events >= 2,
    "forced report records deduplicated FSM and Action transitions for the complete root action")

local sticky_reports = {}
local sticky_current = { category = 4, action = 29, motion_name = "FrontContainBite_Start_L" }
local sticky_node = "Attack.CheckBite.Phase00"
local sticky_api = { quest_api = quest_api }
function sticky_api:get_context() return forced_context end
function sticky_api:read_request() return nil end
function sticky_api:write_report(report) sticky_reports[#sticky_reports + 1] = report end
function sticky_api:environment_evidence() return {} end
function sticky_api:area_snapshot() return {} end
function sticky_api:action_request_evidence() return {} end
function sticky_api:request_forced_action() return true end
function sticky_api:current_action() return sticky_current end
function sticky_api:behavior_tree_snapshot()
    return { layers = { { layer = 0, active_nodes = {
        { id = sticky_node, index = 29, name = sticky_node, status1 = 2, status2 = 2 },
    } } } }
end
local sticky_probe = Probe.new(sticky_api, 200032001, { stable_frames = 1 })
sticky_probe.request = { session_id = "forced-sticky", kind = "forced_action_sequence" }
sticky_probe.forced_actions = { 29 }
sticky_probe.forced_index = 1
sticky_probe:set_state("forced_prepare")
sticky_probe:update()
sticky_probe:update()
assert(sticky_probe.state == "forced_wait_exit")
sticky_node = "Attack.CheckBite.Phase01"
for _ = 1, 5 do sticky_probe:update() end
assert(sticky_probe.state == "forced_wait_exit",
    "an ActionNo that remains in the attack tree must not complete early")
sticky_node = "Normal.Search.Phase00"
for _ = 1, 6 do sticky_probe:update() end
sticky_probe:update()
assert(sticky_reports[#sticky_reports].status == "completed"
    and sticky_reports[#sticky_reports].forced_actions.results[1].completion_basis
        == "behavior_tree_attack_exit",
    "forced probe completes sticky ActionNo only after the observed behavior-tree attack exit")

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
function training_api:training_menu_snapshot(repeats)
    return { requested_repeats = repeats, scenarios = {
        { scenario_id = "tigrex_roar_single", start_label = "开始：咆哮 × 5",
            effective_repeats = 5 },
        { scenario_id = "tigrex_half_turn_bite_short",
            start_label = "开始：短距半回转钩咬 × 1", effective_repeats = 1,
            repeat_gate_message = "该场景当前仅开放 1 轮：更高重复次数尚未通过稳定性门禁。" },
    } }
end
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

local ui_probe = Probe.new(training_api, 200032001, { stable_frames = 1 })
assert(ui_probe:accept_request({ session_id = "ui-contract", kind = "ui_contract_snapshot",
    auto_load_save = false, ui_requested_repeats = 5 }, {
    in_quest = false, is_online = false, build_supported = true,
}), "runtime UI contract snapshot completes without entering a quest")
local ui_report = training_reports[#training_reports]
assert(ui_report.status == "completed" and ui_report.ui_contract.requested_repeats == 5
    and ui_report.ui_contract.scenarios[2].effective_repeats == 1,
    "developer evidence serializes the same presentation contract consumed by ImGui")

local survey_reports, survey_action = {}, 0
local survey_api = { quest_api = quest_api }
function survey_api:get_context() return forced_context end
function survey_api:read_request() return nil end
function survey_api:write_report(report) survey_reports[#survey_reports + 1] = report end
function survey_api:environment_evidence() return {} end
local survey_combat_layer = true
function survey_api:area_snapshot() return { combat_layer = survey_combat_layer } end
function survey_api:action_request_evidence() return {} end
function survey_api:current_action()
    survey_action = survey_action + 1
    return { category = 4, action = survey_action, motion_name = "survey" }
end
function survey_api:behavior_tree_snapshot()
    return { layers = { { layer = 0, active_nodes = {
        { id = tostring(survey_action), index = survey_action,
            name = "Attack.Survey." .. tostring(survey_action), status1 = 2, status2 = 2 },
    } } } }
end
local survey_probe = Probe.new(survey_api, 200032001, { stable_frames = 1 })
survey_probe.request = { session_id = "behavior-survey", kind = "behavior_path_survey",
    require_combat_area = true, behavior_survey_frames = 300 }
survey_probe:set_state("wait_stable")
survey_probe:update()
assert(survey_probe.state == "behavior_survey", "combat gate starts the natural FSM survey")
for _ = 1, 100 do survey_probe:update() end
survey_combat_layer = false
survey_probe:update()
assert(survey_probe.state == "behavior_survey_reenter",
    "hunter recovery immediately pauses behavior sampling outside the combat layer")
for _ = 1, 20 do survey_probe:update() end
assert(survey_probe.behavior_survey.sampled_frames == 100,
    "preparation-area frames never count toward a behavior survey")
survey_combat_layer = true
survey_probe:update()
assert(survey_probe.state == "behavior_survey", "combat re-entry resumes the same survey")
for _ = 1, 200 do survey_probe:update() end
local survey_report = survey_reports[#survey_reports]
assert(survey_report.status == "completed" and survey_report.behavior_survey.samples == 300)
assert(#survey_report.behavior_survey.edges == 299,
    "natural survey reports observed candidate edges without declaring deterministic branches")
assert(survey_probe.behavior_survey.reentry_count == 1,
    "survey diagnostics retain the hunter-recovery count")

local condition_reports, condition_action = {}, 29
local condition_api = { quest_api = quest_api }
function condition_api:get_context() return forced_context end
function condition_api:write_report(report) condition_reports[#condition_reports + 1] = report end
function condition_api:environment_evidence() return {} end
function condition_api:area_snapshot() return { combat_layer = true } end
function condition_api:target_geometry_snapshot() return { horizontal_distance = 7.25 } end
function condition_api:action_request_evidence() return {} end
function condition_api:behavior_tree_snapshot() return { layers = {} } end
function condition_api:think_context_snapshot() return {} end
function condition_api:current_action()
    if condition_action == 29 then condition_action = 5000
    elseif condition_action == 5000 then condition_action = 5001 end
    return { category = 4, action = condition_action }
end
local condition_probe = Probe.new(condition_api, 200032001, { stable_frames = 1 })
assert(condition_probe:accept_request({
    session_id = "condition-branch", kind = "condition_induced_branch",
    target_root = 5000, expected_successor = 5001, target_distance = 7,
    condition_timeout_frames = 300,
}, forced_context))
condition_probe:update()
assert(condition_probe.state == "condition_branch_seek")
condition_probe:update()
assert(condition_probe.state == "condition_branch_verify_successor"
    and condition_probe.condition_branch.desired_movement == "stop")
condition_probe:update()
assert(condition_reports[#condition_reports].status == "completed"
    and condition_reports[#condition_reports].condition_branch.status == "passed",
    "condition branch stops movement at root and verifies the engine-owned successor")

local metadata_reports = {}
local metadata_api = { quest_api = quest_api }
function metadata_api:get_context() return forced_context end
function metadata_api:write_report(report) metadata_reports[#metadata_reports + 1] = report end
function metadata_api:environment_evidence() return {} end
function metadata_api:area_snapshot() return { combat_layer = true } end
function metadata_api:behavior_tree_snapshot() return { layers = {} } end
function metadata_api:think_context_snapshot() return {} end
function metadata_api:input_motion_diagnostics()
    return { policy = "read_only_known_hid_contract_probe", device_available = true }
end
local metadata_probe = Probe.new(metadata_api, 200032001, { stable_frames = 1 })
assert(metadata_probe:accept_request({
    session_id = "input-motion-metadata", kind = "input_motion_metadata",
}, forced_context))
metadata_probe:update()
assert(metadata_reports[#metadata_reports].status == "completed"
    and metadata_reports[#metadata_reports].input_motion.device_available,
    "known HID metadata probe completes without any input write")

function metadata_api:player_action_diagnostics()
    return {
        weapon_type = "long_sword",
        player_action = {
            availability = "available", node_id = 123,
            node_name = "atk.atk_147.atk_147",
        },
    }
end
function metadata_api:training_timeline_diagnostics()
    return { schema_version = 3, revision = 7, last_round = { outcome = "hit" } }
end
local player_action_probe = Probe.new(metadata_api, 200032001, { stable_frames = 1 })
assert(player_action_probe:accept_request({
    session_id = "player-action-evidence", kind = "player_action_evidence",
}, forced_context))
player_action_probe:update()
assert(metadata_reports[#metadata_reports].status == "completed"
    and metadata_reports[#metadata_reports].player_action.weapon_type == "long_sword"
    and metadata_reports[#metadata_reports].player_action.player_action.node_name == "atk.atk_147.atk_147",
    "player action probe requires a resolved current node name")
assert(metadata_reports[#metadata_reports].training_timeline.revision == 7
    and metadata_reports[#metadata_reports].training_timeline.last_round.outcome == "hit",
    "player action probe preserves the same training timeline consumed by the overlay")

local axis_reports, axis_writes, axis_releases = {}, 0, 0
local axis_api = { quest_api = quest_api }
function axis_api:get_context() return forced_context end
function axis_api:write_report(report) axis_reports[#axis_reports + 1] = report end
function axis_api:environment_evidence() return {} end
function axis_api:area_snapshot()
    return { combat_layer = true, player_position = { x = axis_writes / 10, y = 0, z = 0 } }
end
function axis_api:behavior_tree_snapshot() return { layers = {} } end
function axis_api:think_context_snapshot() return {} end
function axis_api:write_input_motion_axis(x, y)
    assert(x == 0 and y == 1)
    axis_writes = axis_writes + 1
    return true
end
function axis_api:release_input_motion_axis() axis_releases = axis_releases + 1 return true end
function axis_api:input_motion_diagnostics() return { owned = false, write_count = axis_writes } end
local axis_probe = Probe.new(axis_api, 200032001, { stable_frames = 1 })
assert(axis_probe:accept_request({
    session_id = "input-motion-axis", kind = "input_motion_axis_write",
    axis_x = 0, axis_y = 1, axis_frames = 60,
}, forced_context))
axis_probe:update()
for _ = 1, 60 do axis_probe:update() end
assert(axis_probe.state == "input_motion_axis_verify" and axis_releases >= 1)
for _ = 1, 15 do axis_probe:update() end
assert(axis_reports[#axis_reports].status == "completed"
    and axis_reports[#axis_reports].input_motion.displacement > 0
    and axis_releases >= 2,
    "bounded axis probe writes exactly 60 frames and releases on completion")

local branch_action = 0
local branch_api = { quest_api = quest_api }
function branch_api:get_context() return forced_context end
function branch_api:write_report() end
function branch_api:environment_evidence() return {} end
function branch_api:area_snapshot() return { combat_layer = true } end
function branch_api:action_request_evidence() return {} end
function branch_api:behavior_tree_snapshot() return { layers = {} } end
function branch_api:think_context_snapshot() return {} end
function branch_api:request_think_reference(path)
    assert(path == "em032_combo_001.user")
    branch_action = 5000
    return true, { state_id = 6 }, false
end
function branch_api:current_action()
    local value = branch_action
    if branch_action == 5000 then branch_action = 5001 end
    return { category = 4, action = value }
end
local branch_probe = Probe.new(branch_api, 200032001, { stable_frames = 1 })
branch_probe.request = { session_id = "native-branch", kind = "native_think_branch",
    think_reference = "em032_combo_001.user", expected_successor = 5001 }
branch_probe.native_branch = { reference = "em032_combo_001.user",
    expected_roots = { 5000, 5002 }, expected_successor = 5001, status = "pending" }
branch_probe:set_state("native_branch_request")
branch_probe:update()
assert(branch_probe.state == "native_branch_verify_root")
branch_probe:update()
assert(branch_probe.state == "native_branch_verify_successor")
branch_probe:update()
assert(branch_probe.state == "native_branch_recovery"
    and branch_probe.native_branch.status == "passed",
    "native Think branch writes only the parent reference and observes the engine successor")

print("test_dev_probe_controller.lua: PASS")
