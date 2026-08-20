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
        local ok, value = pcall(function()
            return json.load_file("MHRiseMonsterCoach/" .. name)
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
    local dev_probe = DevProbeController.new(probe_api, Profile.training_quest.id)
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
    function bootstrap_api:select_save_slot(index)
        return runtime:select_startup_save_slot(index)
    end
    local startup_bootstrap = StartupBootstrapController.new(bootstrap_api)
    startup_bootstrap:accept_request(probe_api:read_request())

    local order_hooked, order_error = runtime:install_quest_list_order_hook({ Profile.training_quest.id })
    if not order_hooked then
        log.warn("[MHRiseMonsterCoach] " .. tostring(order_error))
    end

    re.on_pre_application_entry("UpdateBehavior", function()
        runtime:flush_quest_list_order()
        controller:guard("update", function() controller:update() end)
        controller:guard("dev_probe", function() dev_probe:update() end)
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

    log.info("[MHRiseMonsterCoach] 0.29.1-title-behavior-instances loaded; diagnostic safe mode=" .. tostring(config.diagnostic_safe_mode))
end

return M
