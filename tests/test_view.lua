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
    weapon_response_extension_enabled = false,
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

local screen_width, screen_height = 640, 360
local runtime = { screen_size = function() return screen_width, screen_height end }
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

config.show_advice = true
model.current_move = { advice = "Move sideways", threat = {
    direction = "front", response = "leave the line",
} }
model.response_candidates = { { availability = "available", name = "Foresight Slash" } }
model.player_combat_state = { weapon_type = "long_sword", active_scroll = "red",
    switch_skills = { red = { 1, 2, 3, 4, 5 } } }
drawn = {}
view:draw(model, runtime, false, nil)
local response_disabled_text = table.concat(drawn, "\n")
assert(not response_disabled_text:find("Weapon response:", 1, true),
    "disabled optional extension hides weapon-specific response text")
assert(not response_disabled_text:find("Long Sword loadout:", 1, true),
    "disabled optional extension hides weapon loadout diagnostics")
config.weapon_response_extension_enabled = true
drawn = {}
view:draw(model, runtime, false, nil)
local response_enabled_text = table.concat(drawn, "\n")
assert(response_enabled_text:find("Weapon response: Foresight Slash", 1, true),
    "enabled optional extension shows weapon-specific response text")
assert(response_enabled_text:find("Long Sword loadout: red scroll", 1, true),
    "enabled optional extension shows weapon loadout diagnostics")

config.show_move = true
model.rounds = 4
model.streak = 2
model.state_changes = 9
model.current_state_key = "4:2"
model.current_metadata = { current_frame = 120, end_frame = 180, motion_progress = 2 / 3 }
model.context.outcome_tracking = true
model.last_result = "观察到受击"
model.training_scenario = {
    name = "直线冲锋派生", state = "running", status = "等待条件派生 0/1",
    completed_rounds = 0, target_rounds = 1,
    actual_path = { events = {
        { node = { name = "Attack.StraightRush.Phase00" } },
        { node = { name = "Attack.StraightRush.Phase01" } },
        { node = { name = "Attack.AfterRushDriftForAttack.Phase00" } },
    } },
}
model.last_hit_event = { move_name = "直线冲锋", damage = 42,
    relation = "inside_active", relative_frame = 3 }
screen_width = 640
drawn = {}
view:draw(model, runtime, false, nil)
local compact_layout = view:layout_snapshot()
assert(compact_layout.bottom <= compact_layout.screen_height - compact_layout.bottom_margin,
    "minimum-height overlay stays inside its measured screen content rectangle")
assert(not compact_layout.horizontal_overflow and not compact_layout.vertical_overflow,
    "shared runtime layout snapshot reports no horizontal or vertical overflow")
assert(compact_layout.clipped_line_count > 0 and compact_layout.line_count <= compact_layout.max_lines,
    "low resolution hides lower-priority diagnostics instead of overflowing")
local compact_text = table.concat(compact_layout.text, "\n")
assert(compact_text:find("Move:", 1, true)
    and compact_text:find("Next (random):", 1, true)
    and compact_text:find("Phase / 阶段:", 1, true)
    and compact_text:find("Training ", 1, true),
    "compact layout preserves move, branch certainty, phase and training state")
assert(compact_layout.text[#compact_layout.text]:find("READ%-ONLY:") ~= nil,
    "device-appropriate controls remain the final visible overlay line")
for _, text in ipairs(compact_layout.text) do
    assert(imgui.calc_text_size(text).x <= compact_layout.width - 24,
        "all compact overlay text shares the measured content width")
end

screen_width = 1920
screen_height = 1080
drawn = {}
view:draw(model, runtime, false, nil)
local full_layout = view:layout_snapshot()
assert(full_layout.clipped_line_count == 0 and full_layout.raw_line_count == full_layout.line_count,
    "common 1080p layout retains the full evidence and diagnostic set")

revision = 2
view:draw(model, runtime, false, nil)
assert(snapshot_calls == 2, "new completed round invalidates the cached review once")

print("test_view.lua: PASS")
