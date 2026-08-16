local Config = require("MHRiseMonsterCoach.config")
local Model = require("MHRiseMonsterCoach.model")
local Runtime = require("MHRiseMonsterCoach.runtime")
local View = require("MHRiseMonsterCoach.view")
local Controller = require("MHRiseMonsterCoach.controller")
local InputAdapter = require("MHRiseMonsterCoach.input_adapter")
local Profile = require("MHRiseMonsterCoach.profile_tigrex")
local Font = require("MHRiseMonsterCoach.font")

local M = {}

function M.start()
    local config, calibration, static_ai, long_sword_knowledge = Config.load()
    local model = Model.new(Profile, calibration, config, static_ai, long_sword_knowledge)
    local runtime = Runtime.new(config, Profile)
    local font = Font.new()
    local view = View.new(config, font)
    local input_adapter = InputAdapter.new(config.controller_input)
    local controller = Controller.new(model, runtime, view, config, Config, font, input_adapter)

    local order_hooked, order_error = runtime:install_quest_list_order_hook({ Profile.training_quest.id })
    if not order_hooked then
        log.warn("[MHRiseMonsterCoach] " .. tostring(order_error))
    end

    re.on_pre_application_entry("UpdateBehavior", function()
        runtime:flush_quest_list_order()
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

    log.info("[MHRiseMonsterCoach] 0.8.0-controller-input-candidate loaded; diagnostic safe mode=" .. tostring(config.diagnostic_safe_mode))
end

return M
