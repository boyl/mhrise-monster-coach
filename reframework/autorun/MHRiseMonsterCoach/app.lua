local Config = require("MHRiseMonsterCoach.config")
local Model = require("MHRiseMonsterCoach.model")
local Runtime = require("MHRiseMonsterCoach.runtime")
local View = require("MHRiseMonsterCoach.view")
local Controller = require("MHRiseMonsterCoach.controller")
local InputAdapter = require("MHRiseMonsterCoach.input_adapter")
local Profile = require("MHRiseMonsterCoach.profile_tigrex")
local Font = require("MHRiseMonsterCoach.font")
local DevProbeController = require("MHRiseMonsterCoach.dev_probe_controller")

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
    local function data_file_exists(name)
        local handle = io.open("reframework/data/MHRiseMonsterCoach/" .. name, "r")
        if handle == nil then return false end
        handle:close()
        return true
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
        if not data_file_exists("dev_probe_request.json") then return nil end
        local request = json.load_file("MHRiseMonsterCoach/dev_probe_request.json")
        if type(request) ~= "table" then return nil end
        local report = data_file_exists("dev_probe_report.json")
            and json.load_file("MHRiseMonsterCoach/dev_probe_report.json") or nil
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

    local order_hooked, order_error = runtime:install_quest_list_order_hook({ Profile.training_quest.id })
    if not order_hooked then
        log.warn("[MHRiseMonsterCoach] " .. tostring(order_error))
    end

    re.on_pre_application_entry("UpdateBehavior", function()
        runtime:flush_quest_list_order()
        controller:guard("update", function() controller:update() end)
        controller:guard("dev_probe", function() dev_probe:update() end)
    end)
    re.on_frame(function()
        controller:guard("draw_overlay", function() controller:draw_overlay() end)
    end)
    re.on_draw_ui(function()
        controller:guard("draw_menu", function() controller:draw_menu() end)
    end)
    re.on_config_save(function() Config.save(config) end)
    re.on_script_reset(function() dev_probe:shutdown() controller:shutdown() end)

    log.info("[MHRiseMonsterCoach] 0.22.0-automated-probe-session loaded; diagnostic safe mode=" .. tostring(config.diagnostic_safe_mode))
end

return M
