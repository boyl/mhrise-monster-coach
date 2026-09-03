package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local drawn, rectangles = {}, {}
imgui = {
    calc_text_size = function(text) return { x = #text * 10, y = 19 } end,
}
draw = {
    filled_rect = function(x, y, w, h, color)
        rectangles[#rectangles + 1] = { kind = "fill", x = x, y = y, w = w, h = h, color = color }
    end,
    outline_rect = function(x, y, w, h, color)
        rectangles[#rectangles + 1] = { kind = "outline", x = x, y = y, w = w, h = h, color = color }
    end,
    text = function(text) drawn[#drawn + 1] = text end,
}

local View = require("MHRiseMonsterCoach.view")
local config = {
    overlay_enabled = true,
    simple_move_cue_enabled = true,
    detailed_overlay_enabled = true,
    overlay_positioning_enabled = false,
    overlay_position = { x = 0.5, y = 0.065 },
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
    assert(imgui.calc_text_size(text).x <= 360,
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
assert(table.concat(drawn, "\n"):find("条件派生：", 1, true),
    "conditional branches are visibly distinct from generic candidates")
model.prediction.kind = "random"
drawn = {}
view:draw(model, runtime, false, nil)
assert(table.concat(drawn, "\n"):find("随机候选：", 1, true),
    "random branches are never presented as conditional or fixed")

config.show_advice = true
model.current_move = { name = "右回旋攻击", advice = "Move sideways", threat = {
    direction = "front", response = "leave the line",
} }
model.response_candidates = { { availability = "available", name = "Foresight Slash" } }
model.player_combat_state = { weapon_type = "long_sword", active_scroll = "red",
    switch_skills = { red = { 1, 2, 3, 4, 5 } } }
drawn = {}
view:draw(model, runtime, false, nil)
local response_disabled_text = table.concat(drawn, "\n")
assert(not response_disabled_text:find("武器应对：", 1, true),
    "disabled optional extension hides weapon-specific response text")
assert(not response_disabled_text:find("Long Sword loadout:", 1, true),
    "disabled optional extension hides weapon loadout diagnostics")
config.weapon_response_extension_enabled = true
drawn = {}
view:draw(model, runtime, false, nil)
local response_enabled_text = table.concat(drawn, "\n")
assert(view:layout_snapshot().cue_visible,
    "legacy show_move=false cannot hide the overlay's primary move cue")
assert(response_enabled_text:find("武器应对：Foresight Slash", 1, true),
    "enabled optional extension shows weapon-specific response text")
assert(not response_enabled_text:find("Long Sword loadout:", 1, true),
    "battlefield HUD never exposes loadout diagnostics")

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
rectangles = {}
view:draw(model, runtime, false, nil)
local compact_layout = view:layout_snapshot()
assert(compact_layout.bottom <= compact_layout.screen_height - compact_layout.bottom_margin,
    "minimum-height overlay stays inside its measured screen content rectangle")
assert(not compact_layout.horizontal_overflow and not compact_layout.vertical_overflow,
    "shared runtime layout snapshot reports no horizontal or vertical overflow")
assert(compact_layout.cue_visible and compact_layout.cue_line_height > compact_layout.line_height,
    "move cue is an independent, visually dominant layer")
local compact_text = table.concat(compact_layout.text, "\n")
assert(compact_text:find("右回旋攻击", 1, true)
    and compact_text:find("Move sideways", 1, true)
    and compact_text:find("随机候选：", 1, true)
    and compact_text:find("训练 ·", 1, true),
    "compact HUD preserves move cue, branch, response and training state")
for _, noise in ipairs({ "Target:", "State key:", "Animation:", "READ-ONLY:",
    "Long Sword loadout:", "Actual path", "Last hit" }) do
    assert(not compact_text:find(noise, 1, true), "battlefield HUD removes diagnostic noise: " .. noise)
end
assert(#rectangles == 2, "detailed HUD retains its background and border")
for _, text in ipairs(compact_layout.text) do
    assert(imgui.calc_text_size(text).x <= compact_layout.content_width,
        "all compact overlay text shares the measured content width")
end

screen_width = 1920
screen_height = 1080
drawn = {}
view:draw(model, runtime, false, nil)
local full_layout = view:layout_snapshot()
assert(full_layout.clipped_line_count == 0 and full_layout.raw_line_count == full_layout.line_count,
    "common 1080p layout retains the complete focused coaching set")

revision = 2
view:draw(model, runtime, false, nil)
assert(snapshot_calls == 2, "new completed round invalidates the cached review once")

drawn, rectangles = {}, {}
model.current_move = nil
model.current_action = nil
model.prediction = nil
model.training_scenario = nil
model.training_timeline_snapshot = function() return { last_round = nil } end
revision = 3
view:draw(model, runtime, false, nil)
local idle_layout = view:layout_snapshot()
assert(not idle_layout.cue_visible and idle_layout.detail_line_count == 0 and #rectangles == 0,
    "idle battlefield HUD is silent instead of showing status or controls")

drawn, rectangles = {}, {}
view:draw(model, runtime, true, nil)
assert(table.concat(drawn, "\n"):find("子弹时间", 1, true),
    "detailed HUD preserves slow-motion state while active")

config.detailed_overlay_enabled = false
model.current_move = { name = "右回旋攻击", advice = "Move sideways" }
model.current_action = "12"
drawn, rectangles = {}, {}
view:draw(model, runtime, false, nil)
local simple_layout = view:layout_snapshot()
assert(simple_layout.cue_visible and not simple_layout.detailed_overlay_enabled
    and simple_layout.detail_line_count == 0 and #rectangles == 0,
    "default simple mode renders only a frameless move name")
local simple_text = table.concat(simple_layout.text, "\n")
assert(simple_text:find("右回旋攻击", 1, true)
    and not simple_text:find("应对：", 1, true)
    and not simple_text:find("阶段：", 1, true),
    "simple cue never leaks detailed HUD content")

local drag_frame = 1
local drag_mouse = { { x = 600, y = 100 }, { x = 800, y = 200 }, { x = 800, y = 200 } }
reframework = { is_drawing_ui = function() return true end }
imgui.set_next_window_pos = function() end
imgui.set_next_window_size = function() end
imgui.begin_window = function() return true end
imgui.end_window = function() end
imgui.set_cursor_pos = function() end
imgui.invisible_button = function() end
imgui.is_item_hovered = function() return true end
imgui.is_mouse_clicked = function() return drag_frame == 1 end
imgui.is_mouse_down = function() return drag_frame <= 2 end
imgui.is_mouse_released = function() return drag_frame == 3 end
imgui.get_mouse = function() return drag_mouse[drag_frame] end
config.overlay_positioning_enabled = true
for frame = 1, 3 do
    drag_frame = frame
    local saved = view:draw(model, runtime, false, nil)
    if frame < 3 then assert(not saved, "dragging does not persist every frame")
    else assert(saved, "drag release requests exactly one position save") end
end
local dragged_layout = view:layout_snapshot()
assert(dragged_layout.positioning and not dragged_layout.framed
    and config.overlay_position.x > 0.5 and config.overlay_position.y > 0.065,
    "transparent drag target updates normalized HUD position without adding a frame")

print("test_view.lua: PASS")
