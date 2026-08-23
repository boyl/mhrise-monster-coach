package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Probe = require("MHRiseMonsterCoach.dev_probe_controller")
local Recorder = require("MHRiseMonsterCoach.behavior_graph_recorder")

local combat_layer = true
local reports = {}
local context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
local api = { quest_api = {} }
function api:get_context() return context end
function api:write_report(report) reports[#reports + 1] = report end
function api:environment_evidence() return {} end
function api:area_snapshot() return { combat_layer = combat_layer } end
function api:action_request_evidence() return {} end
function api:current_action() return { category = 4, action = 5000 } end
function api:behavior_tree_snapshot() return { layers = {} } end
function api:think_context_snapshot() return {} end
function api:target_geometry_snapshot()
    return { horizontal_distance = 7, vertical_gap = combat_layer and 0 or 568 }
end

local probe = Probe.new(api, 200032001, { stable_frames = 1 })
probe.request = { session_id = "survey-recovery", kind = "behavior_path_survey",
    require_combat_area = true, behavior_survey_frames = 3 }
probe.behavior_survey = {
    target_frames = 3, sampled_frames = 0, reentry_count = 0,
    recorder = Recorder.new(16),
}
probe:set_state("behavior_survey")
probe:update()
assert(probe.behavior_survey.sampled_frames == 1)

combat_layer = false
probe:update()
assert(probe.state == "behavior_survey_reenter"
    and probe.behavior_survey.sampled_frames == 1
    and probe.behavior_survey.reentry_count == 1,
    "death return pauses sampling before preparation-area coordinates are recorded")
probe:update()
assert(probe.behavior_survey.sampled_frames == 1,
    "preparation-area frames remain excluded while waiting for arena re-entry")

combat_layer = true
probe:update()
assert(probe.state == "behavior_survey", "combat re-entry resumes the same survey")
assert(reports[#reports].state == "behavior_survey" and reports[#reports].status == "running",
    "re-entry publishes the resumed state immediately so external navigation releases its latch")
probe:update()
probe:update()
assert(reports[#reports].status == "completed"
    and reports[#reports].behavior_survey.samples == 3,
    "only three valid combat samples complete the survey")

print("test_behavior_survey_recovery.lua: PASS")
