package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Controller = require("MHRiseMonsterCoach.controller")

local roar = {
    id = "tigrex_roar_single", name_zh = "咆哮", actions = { 19 },
    training_category = "independent", max_verified_repeats = 10,
    summary_zh = "独立单招训练。", verification = { status = "verified" },
}
local bite = {
    id = "tigrex_half_turn_bite_short", name_zh = "短距半回转钩咬", actions = { 5000 },
    training_category = "fixed_branch", execution_mode = "natural_condition",
    max_verified_repeats = 1, summary_zh = "固定派生训练。",
    verification = { status = "verified" },
}
local hidden = {
    id = "unverified", name_zh = "未验证动作", actions = { 9999 },
    training_category = "independent", verification = { status = "candidate" },
}
local model = {
    profile = { training_quest = { id = 200032001 } },
    context = { in_quest = true, quest_no = 200032001, is_online = false,
        build_supported = true, target_found = true },
    scenarios = { roar, bite, hidden },
}
function model:training_catalog()
    return {
        { id = "independent", name = "独立关键招式", scenarios = { roar, hidden } },
        { id = "fixed_branch", name = "固定派生起手", scenarios = { bite } },
    }
end
function model:training_branch_tree(scenario)
    return { action = tostring(scenario.actions[1]), name = scenario.name_zh,
        kind = scenario == bite and "fixed" or "unverified", candidates = {} }
end

local config = { forced_action_training_enabled = false, training_repeat_count = 5 }
local controller = Controller.new(model, {}, {}, config, {}, nil, nil)

local menu = controller:training_menu_view_model()
assert(menu.state == "disabled" and menu.state_label == "未启用"
    and menu.scenario_count == 2 and not menu.can_start,
    "disabled state keeps the verified catalog visible without exposing start")
assert(#menu.groups == 2 and #menu.groups[1].scenarios == 1,
    "unverified scenarios are absent instead of appearing as disabled executable rows")

assert(controller:set_training_enabled(true), "feature enable is an explicit state transition")
local scope_cases = {
    { field = "is_online", value = true, expected = "联机" },
    { field = "build_supported", value = false, expected = "版本" },
    { field = "in_quest", value = false, expected = "进入" },
    { field = "quest_no", value = 1, expected = "当前不是" },
    { field = "target_found", value = false, expected = "怪物区域" },
}
for _, case in ipairs(scope_cases) do
    model.context = { in_quest = true, quest_no = 200032001, is_online = false,
        build_supported = true, target_found = true }
    model.context[case.field] = case.value
    menu = controller:training_menu_view_model()
    assert(menu.state == "unavailable" and not menu.can_start
        and string.find(menu.status, case.expected, 1, true),
        "scope variant fails with a visible, specific recovery reason: " .. case.field)
end

model.context = { in_quest = true, quest_no = 200032001, is_online = false,
    build_supported = true, target_found = true }
controller.training_state = "idle"
controller.training_preview_scenario_id = nil
menu = controller:training_menu_view_model()
assert(menu.state == "ready" and menu.can_select and not menu.can_start,
    "ready state requires a branch preview before start")

assert(controller:preview_training_scenario(bite), "verified branch tree can be selected")
menu = controller:training_menu_view_model()
assert(menu.state == "previewed" and menu.can_start and menu.selected.scenario_id == bite.id
    and menu.selected.effective_repeats == 1
    and string.find(menu.selected.repeat_gate_message, "稳定性门禁", 1, true),
    "preview state exposes selection, branch tree and evidence-gated repeat count")

controller.training_state = "running"
controller.training_status = "怪物正在执行“短距半回转钩咬”"
menu = controller:training_menu_view_model()
assert(menu.state == "active" and menu.state_label == "训练中"
    and menu.can_stop and not menu.can_select and not menu.can_start,
    "active state locks selection and exposes one stop path")
assert(not controller:preview_training_scenario(roar)
    and controller.training_preview_scenario_id == bite.id,
    "active training cannot silently switch the selected scenario")
assert(controller:set_training_enabled(false) and controller.training_state == "cancelled"
    and string.find(controller.training_status, "功能已关闭", 1, true),
    "disabling the feature cancels queued or active work immediately")

controller:set_training_enabled(true)
controller.training_state = "completed"
controller.training_status = "训练完成：1/1"
menu = controller:training_menu_view_model()
assert(menu.state == "completed" and menu.can_start
    and string.find(menu.primary_label, "再练一次", 1, true),
    "completed state offers one explicit replay action")

controller.training_state = "failed"
controller.training_status = "招式未正常退出"
menu = controller:training_menu_view_model()
assert(menu.state == "failed" and menu.can_start
    and string.find(menu.primary_label, "重新尝试", 1, true)
    and string.find(menu.instruction, "F7", 1, true),
    "failed state provides bounded retry plus the safe native restart fallback")

controller.training_state = "cancelled"
controller.training_status = "训练已停止"
menu = controller:training_menu_view_model()
assert(menu.state == "cancelled" and menu.can_start and not menu.can_stop,
    "cancelled state retains selection but clears active input ownership")

controller.training_state = "unavailable"
controller.training_status = "上次请求因任务状态变化取消"
menu = controller:training_menu_view_model()
assert(menu.state == "unavailable" and menu.scope_ready and menu.can_start
    and string.find(menu.primary_label, "重新尝试", 1, true),
    "a retained selection becomes explicitly retryable after the scope recovers")

menu = controller:training_menu_view_model(5, true)
assert(menu.groups[1].scenarios[1].branch_tree ~= nil
    and menu.groups[2].scenarios[1].branch_tree ~= nil,
    "developer UI contract snapshot consumes the same state model with all trees included")

model.scenarios = {}
function model:training_catalog() return {} end
controller.training_preview_scenario_id = nil
controller.training_state = "idle"
menu = controller:training_menu_view_model()
assert(menu.state == "empty" and menu.scenario_count == 0 and not menu.can_start,
    "empty verified catalog has a visible explanation and no executable action")

print("test_training_menu_state.lua: PASS")
