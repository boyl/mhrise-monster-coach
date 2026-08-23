local M = {}

local CONFIG_PATH = "MHRiseMonsterCoach/config.json"
local CALIBRATION_PATH = "MHRiseMonsterCoach/tigrex_calibration.json"
local STATIC_AI_PATH = "MHRiseMonsterCoach/tigrex_static_ai.json"
local LONG_SWORD_KNOWLEDGE_PATH = "MHRiseMonsterCoach/long_sword_knowledge.json"

local DEFAULTS = {
    schema_version = 1,
    supported_game_name = "mhrise",
    supported_tdb_version = 71,
    diagnostic_safe_mode = true,
    enabled = true,
    overlay_enabled = true,
    show_move = true,
    show_prediction = true,
    show_advice = true,
    show_timeline_review = true,
    show_hitboxviewer_debug_shapes = false,
    time_control_enabled = true,
    quick_reset_enabled = false,
    auto_capture_anchors = false,
    native_quest_reset_enabled = true,
    forced_action_training_enabled = false,
    training_repeat_count = 1,
    experimental_in_place_reset_enabled = true,
    quick_reset_cooldown_frames = 180,
    quick_reset_safe_frames = 15,
    slowmo_scale = 0.25,
    safety_health_lock = false,
    protect_monster_health = false,
    transition_history_limit = 256,
    timeline_event_limit = 128,
    learned_action_limit = 128,
    min_prediction_samples = 3,
    keys = {
        slowmo_hold = 0x75, -- F6
        quick_reset = 0x76, -- F7
        capture_anchor = 0x77, -- F8
        in_place_reset = 0x78, -- F9
    },
    controller_input = {
        enabled = false,
        long_hold_seconds = 0.75,
    },
    action_reader = {
        kind = "auto",
        name = "",
    },
}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copy(child) end
    return result
end

local function merge_known(target, source)
    if type(source) ~= "table" then return target end
    for key, current in pairs(target) do
        local incoming = source[key]
        if incoming ~= nil then
            if type(current) == "table" then
                merge_known(current, incoming)
            elseif type(incoming) == type(current) then
                target[key] = incoming
            end
        end
    end
    return target
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

function M.load()
    local config = copy(DEFAULTS)
    local loaded = json.load_file(CONFIG_PATH)
    merge_known(config, loaded)

    config.slowmo_scale = clamp(config.slowmo_scale, 0.05, 1.0)
    config.transition_history_limit = math.floor(clamp(config.transition_history_limit, 32, 512))
    config.timeline_event_limit = math.floor(clamp(config.timeline_event_limit, 32, 512))
    config.learned_action_limit = math.floor(clamp(config.learned_action_limit, 16, 256))
    config.min_prediction_samples = math.floor(clamp(config.min_prediction_samples, 2, 20))
    config.quick_reset_cooldown_frames = math.floor(clamp(config.quick_reset_cooldown_frames, 60, 600))
    config.quick_reset_safe_frames = math.floor(clamp(config.quick_reset_safe_frames, 5, 60))
    config.training_repeat_count = math.floor(clamp(config.training_repeat_count, 1, 20))

    local calibration = json.load_file(CALIBRATION_PATH)
    if type(calibration) ~= "table" then calibration = {} end
    if type(calibration.moves) ~= "table" then calibration.moves = {} end
    if type(calibration.scenarios) ~= "table" then calibration.scenarios = {} end
    if type(calibration.observed_hit_timing) ~= "table" then calibration.observed_hit_timing = {} end
    if type(calibration.observed_hitbox_windows) ~= "table" then calibration.observed_hitbox_windows = {} end

    local static_ai = M.load_static_ai()

    local long_sword_knowledge = json.load_file(LONG_SWORD_KNOWLEDGE_PATH)
    if type(long_sword_knowledge) ~= "table" then long_sword_knowledge = { actions = {} } end
    if type(long_sword_knowledge.actions) ~= "table" then long_sword_knowledge.actions = {} end

    return config, calibration, static_ai, long_sword_knowledge
end

function M.load_static_ai()
    local static_ai = json.load_file(STATIC_AI_PATH)
    if type(static_ai) ~= "table" then static_ai = { actions = {} } end
    if type(static_ai.actions) ~= "table" then static_ai.actions = {} end
    return static_ai
end

function M.save(config)
    json.dump_file(CONFIG_PATH, config)
end

function M.calibration_path()
    return CALIBRATION_PATH
end

function M.write_calibration(calibration)
    json.dump_file(CALIBRATION_PATH, calibration)
end

return M
