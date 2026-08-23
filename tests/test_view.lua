package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local drawn = {}
imgui = {
    calc_text_size = function(text) return { x = #text * 10, y = 19 } end,
}
draw = {
    filled_rect = function() end,
    outline_rect = function() end,
    text = function(text) drawn[#drawn + 1] = text end,
}

local View = require("MHRiseMonsterCoach.view")
local config = {
    overlay_enabled = true,
    show_move = false,
    show_prediction = false,
    show_advice = false,
    show_timeline_review = true,
    time_control_enabled = false,
    slowmo_scale = 0.25,
}
local snapshot_calls, revision = 0, 1
local model = {
    profile = { name = "Tigrex / 轰龙" },
    context = { in_quest = true, target_found = true, enemy_id = 32,
        outcome_tracking = false, safe_mode = true },
    state = "running",
    status = string.rep("long status ", 20),
    current_action = nil,
    current_move = nil,
    response_candidates = {},
}
function model:training_timeline_revision() return revision end
function model:coaching_state() return { phase = "unknown" } end
function model:training_timeline_snapshot()
    snapshot_calls = snapshot_calls + 1
    return { last_round = { round_id = revision, outcome = "hit", events = {
        { kind = "action_start", data = { move_name = "直线冲锋" } },
        { kind = "hitbox_open", data = { motion_frame = 20 } },
        { kind = "hitbox_close", data = { last_active_frame = 28 } },
    } } }
end

local screen_width = 640
local runtime = { screen_size = function() return screen_width, 360 end }
local view = View.new(config, nil)
view:draw(model, runtime, false, nil)
assert(snapshot_calls == 1, "first render obtains one immutable timeline snapshot")
for _, text in ipairs(drawn) do
    assert(imgui.calc_text_size(text).x <= 336,
        "minimum-width overlay text is measured into its content rectangle")
end

drawn = {}
screen_width = 1920
view:draw(model, runtime, false, nil)
assert(snapshot_calls == 1, "unchanged timeline revision reuses the presented review")
local found_review = false
for _, text in ipairs(drawn) do
    if string.find(text, "复盘:", 1, true) then found_review = true end
end
assert(found_review, "completed round review is visible when enabled")

config.show_prediction = true
model.current_action = "2"
model.prediction = { kind = "conditional", candidates = { { name = "冲锋急停" } } }
drawn = {}
view:draw(model, runtime, false, nil)
assert(table.concat(drawn, "\n"):find("Next (condition):", 1, true),
    "conditional branches are visibly distinct from generic candidates")
model.prediction.kind = "random"
drawn = {}
view:draw(model, runtime, false, nil)
assert(table.concat(drawn, "\n"):find("Next (random):", 1, true),
    "random branches are never presented as conditional or fixed")

revision = 2
view:draw(model, runtime, false, nil)
assert(snapshot_calls == 2, "new completed round invalidates the cached review once")

print("test_view.lua: PASS")
