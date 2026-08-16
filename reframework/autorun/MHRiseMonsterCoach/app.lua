local Config = require("MHRiseMonsterCoach.config")
local Model = require("MHRiseMonsterCoach.model")
local Runtime = require("MHRiseMonsterCoach.runtime")
local View = require("MHRiseMonsterCoach.view")
local Controller = require("MHRiseMonsterCoach.controller")
local Profile = require("MHRiseMonsterCoach.profile_tigrex")

local M = {}

function M.start()
    local config, calibration = Config.load()
    local model = Model.new(Profile, calibration, config)
    local runtime = Runtime.new(config, Profile)
    local view = View.new(config)
    local controller = Controller.new(model, runtime, view, config, Config)

    if not config.diagnostic_safe_mode then
        local hooked, hook_error = runtime:install_enemy_hook(function()
            controller:guard("observe_enemy", function() controller:observe_enemy() end)
        end)
        if not hooked then model:fail(hook_error) end
    end

    re.on_pre_application_entry("UpdateBehavior", function()
        controller:guard("update", function() controller:update() end)
    end)
    re.on_frame(function()
        controller:guard("draw_overlay", function() controller:draw_overlay() end)
    end)
    re.on_draw_ui(function()
        controller:guard("draw_menu", function() controller:draw_menu() end)
    end)
    re.on_config_save(function() Config.save(config) end)
    re.on_script_reset(function() controller:shutdown() end)

    log.info("[MHRiseMonsterCoach] 0.1.2-safe loaded; diagnostic safe mode=" .. tostring(config.diagnostic_safe_mode))
end

return M
