local Config = require("MHRiseMonsterCoach.config")
local Model = require("MHRiseMonsterCoach.model")
local Runtime = require("MHRiseMonsterCoach.runtime")
local View = require("MHRiseMonsterCoach.view")
local Controller = require("MHRiseMonsterCoach.controller")
local InputAdapter = require("MHRiseMonsterCoach.input_adapter")
local Profile = require("MHRiseMonsterCoach.profile_tigrex")
local Font = require("MHRiseMonsterCoach.font")
local DevProbeController = require("MHRiseMonsterCoach.dev_probe_controller")
local StartupBootstrapController = require("MHRiseMonsterCoach.startup_bootstrap_controller")

local M = {}

function M.start()
    local config, calibration, static_ai, long_sword_knowledge = Config.load()
    local model = Model.new(Profile, calibration, config, static_ai, long_sword_knowledge)
    local runtime = Runtime.new(config, Profile)
    local font = Font.new()
    local view = View.new(config, font)
    local input_adapter = InputAdapter.new(config.controller_input)
    local controller = Controller.new(model, runtime, view, config, Config, font, input_adapter)
    local probe_api = { quest_api = runtime:quest_restart_api() }
    local function load_required_data_file(name)
        local contents = fs.read("MHRiseMonsterCoach/" .. name)
        if type(contents) ~= "string" or contents == "" then return nil end
        local ok, value = pcall(function()
            return json.load_string(contents)
        end)
        return ok and value or nil
    end
    function probe_api:get_context()
        return runtime.last_context or {
            in_quest = false,
            is_online = false,
            build_supported = runtime.game_name == config.supported_game_name
                and runtime.tdb_version == config.supported_tdb_version,
        }
    end
    function probe_api:read_request()
        local request = load_required_data_file("dev_probe_request.json")
        if type(request) ~= "table" then return nil end
        local report = load_required_data_file("dev_probe_report.json")
        if type(report) == "table" and report.session_id == request.session_id
            and (report.status == "completed" or report.status == "failed") then return nil end
        return request
    end
    function probe_api:write_report(report)
        json.dump_file("MHRiseMonsterCoach/dev_probe_report.json", report)
    end
    function probe_api:observe_environment()
        return runtime:observe_environment_creatures()
    end
    function probe_api:spawn_environment_probe(session_id)
        return runtime:spawn_owned_environment_probe(session_id)
    end
    function probe_api:environment_evidence()
        return runtime:environment_creature_evidence()
    end
    function probe_api:area_snapshot()
        return runtime:area_snapshot()
    end
    function probe_api:target_geometry_snapshot()
        return runtime:target_geometry_snapshot()
    end
    function probe_api:input_motion_diagnostics()
        return runtime:input_motion_diagnostics()
    end
    function probe_api:player_action_diagnostics()
        return runtime:player_action_diagnostics()
    end
    function probe_api:training_timeline_diagnostics()
        return model:training_timeline_snapshot()
    end
    function probe_api:write_input_motion_axis(x, y)
        return runtime:write_input_motion_axis(x, y)
    end
    function probe_api:release_input_motion_axis()
        return runtime:release_input_motion_axis()
    end
    function probe_api:request_arena_transfer()
        return runtime:request_arena_transfer()
    end
    function probe_api:start_monster_respawn()
        return runtime:start_monster_respawn_probe()
    end
    function probe_api:update_monster_respawn()
        runtime:update_monster_respawn_probe()
        local respawn = runtime.monster_respawn
        return respawn and respawn.state or "unavailable",
            respawn and respawn.error or nil,
            runtime:monster_respawn_diagnostics()
    end
    function probe_api:request_forced_action(action_no)
        return runtime:request_forced_action_probe(action_no)
    end
    function probe_api:current_action()
        return runtime:current_action_snapshot()
    end
    function probe_api:behavior_tree_snapshot()
        return runtime:behavior_tree_snapshot()
    end
    function probe_api:think_context_snapshot(include_catalog)
        return runtime:think_context_snapshot(include_catalog)
    end
    function probe_api:request_think_reference(path_suffix)
        return runtime:request_think_reference_probe(path_suffix)
    end
    function probe_api:action_request_evidence()
        local trace = runtime.action_request_trace or {}
        local method_counts = {}
        local forced_events = {}
        for _, event in ipairs(trace.events or {}) do
            local method = tostring(event.method or "unknown")
            method_counts[method] = (method_counts[method] or 0) + 1
            if event.source == "forced_probe" and #forced_events < 64 then
                forced_events[#forced_events + 1] = event
            end
        end
        return {
            installed = trace.installed,
            calls = trace.calls,
            hook_count = trace.hook_count,
            hook_failures = trace.hook_failures,
            method_counts = method_counts,
            forced_events = forced_events,
        }
    end
    local training_acceptance_config = nil
    function probe_api:start_training_acceptance(scenario_id, repeat_count)
        local scenario = nil
        for _, candidate in ipairs(model.scenarios or {}) do
            if tostring(candidate.id) == tostring(scenario_id) then scenario = candidate break end
        end
        if scenario == nil then return false, "Unknown verified training scenario: " .. tostring(scenario_id) end
        training_acceptance_config = {
            enabled = config.forced_action_training_enabled,
            repeat_count = config.training_repeat_count,
        }
        config.forced_action_training_enabled = true
        config.training_repeat_count = math.max(1, math.min(20, math.floor(tonumber(repeat_count) or 1)))
        controller:preview_training_scenario(scenario)
        local ok = controller:start_training_scenario(scenario)
        if not ok then
            config.forced_action_training_enabled = training_acceptance_config.enabled
            config.training_repeat_count = training_acceptance_config.repeat_count
            training_acceptance_config = nil
            return false, controller.training_status
        end
        return true
    end
    function probe_api:training_acceptance_status()
        local scenario = controller.training_scenario
        local geometry = runtime.target_geometry_snapshot
            and runtime:target_geometry_snapshot() or nil
        return {
            state = controller.training_state,
            status = controller.training_status,
            scenario_id = scenario and scenario.id or nil,
            execution_mode = scenario and scenario.execution_mode or nil,
            positioning = scenario and scenario.positioning or nil,
            geometry = geometry,
            completed_rounds = controller.training_completed_rounds,
            target_rounds = controller.training_target_rounds,
            actual_path = model.training_scenario and model.training_scenario.actual_path or nil,
            actual_branch = model.training_scenario and model.training_scenario.actual_branch or nil,
        }
    end
    function probe_api:training_menu_snapshot(requested_repeats)
        local groups = {}
        for _, group in ipairs(model:training_catalog()) do
            local rows = {}
            for _, scenario in ipairs(group.scenarios or {}) do
                if scenario.verification and scenario.verification.status == "verified" then
                    local presentation = controller:training_scenario_presentation(
                        scenario, requested_repeats)
                    presentation.summary_zh = scenario.summary_zh
                    presentation.execution_mode = scenario.execution_mode
                    presentation.branch_tree = model:training_branch_tree(scenario, 3)
                    rows[#rows + 1] = presentation
                end
            end
            groups[#groups + 1] = { id = group.id, name = group.name, scenarios = rows }
        end
        return { requested_repeats = requested_repeats, groups = groups }
    end
    function probe_api:finish_training_acceptance()
        if controller.training_state == "waiting" or controller.training_state == "requested"
            or controller.training_state == "running" or controller.training_state == "positioning" then
            controller:cancel_training_scenario("自动验收已结束")
        end
        if training_acceptance_config ~= nil then
            config.forced_action_training_enabled = training_acceptance_config.enabled
            config.training_repeat_count = training_acceptance_config.repeat_count
            training_acceptance_config = nil
        end
    end
    local dev_probe = DevProbeController.new(probe_api, Profile.training_quest.id, {
        player_action_quest_id = Profile.training_quest.player_calibration_id,
    })
    local bootstrap_api = {}
    function bootstrap_api:read_request() return probe_api:read_request() end
    function bootstrap_api:write_status(status)
        json.dump_file("MHRiseMonsterCoach/startup_bootstrap_status.json", status)
    end
    function bootstrap_api:read_ack()
        return load_required_data_file("startup_bootstrap_ack.json")
    end
    function bootstrap_api:observe() return runtime:startup_bootstrap_observation() end
    function bootstrap_api:diagnostics() return runtime:startup_bootstrap_diagnostics() end
    function bootstrap_api:select_title_menu(index)
        return runtime:select_startup_title_menu(index)
    end
    function bootstrap_api:advance_to_press_any()
        return runtime:advance_startup_to_press_any()
    end
    function bootstrap_api:advance_to_title_menu()
        return runtime:advance_startup_to_title_menu()
    end
    function bootstrap_api:dismiss_autosave_notice()
        return runtime:dismiss_startup_autosave_notice()
    end
    function bootstrap_api:open_load_data_menu()
        return runtime:open_startup_load_data_menu()
    end
    function bootstrap_api:select_save_slot(index)
        return runtime:select_startup_save_slot(index)
    end
    local startup_bootstrap = StartupBootstrapController.new(bootstrap_api)
    startup_bootstrap:accept_request(probe_api:read_request())

    local order_hooked, order_error = runtime:install_quest_list_order_hook({
        Profile.training_quest.id,
        Profile.training_quest.player_calibration_id,
    })
    if not order_hooked then
        log.warn("[MHRiseMonsterCoach] " .. tostring(order_error))
    end

    re.on_pre_application_entry("UpdateBehavior", function()
        runtime:flush_quest_list_order()
        controller:guard("update", function() controller:update() end)
        controller:guard("dev_probe", function() dev_probe:update() end)
    end)
    re.on_application_entry("UpdateHID", function()
        controller:guard("input_motion_flush", function()
            runtime:flush_input_motion_axis()
        end)
    end)
    re.on_pre_application_entry("LockScene", function()
        controller:guard("startup_bootstrap", function() startup_bootstrap:update() end)
    end)
    re.on_frame(function()
        controller:guard("draw_overlay", function() controller:draw_overlay() end)
    end)
    re.on_draw_ui(function()
        controller:guard("draw_menu", function() controller:draw_menu() end)
    end)
    re.on_config_save(function() Config.save(config) end)
    re.on_script_reset(function() startup_bootstrap:shutdown() dev_probe:shutdown() controller:shutdown() end)

    log.info("[MHRiseMonsterCoach] 0.49.25-runtime-binding-calibration loaded; diagnostic safe mode=" .. tostring(config.diagnostic_safe_mode))
end

return M
