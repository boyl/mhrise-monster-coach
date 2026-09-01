package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Controller = require("MHRiseMonsterCoach.controller")

local texts, buttons, checkboxes = {}, {}, {}
local available_width = 232
imgui = {
    separator = function() end,
    text = function(value) texts[#texts + 1] = tostring(value) end,
    text_wrapped = function(value) texts[#texts + 1] = tostring(value) end,
    same_line = function() end,
    checkbox = function(label, value)
        checkboxes[#checkboxes + 1] = tostring(label)
        return false, value
    end,
    button = function(label) buttons[#buttons + 1] = tostring(label) return false end,
    get_content_region_avail = function() return { x = available_width + 8, y = 600 } end,
    calc_text_size = function(value)
        local width = 0
        for character in tostring(value):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            width = width + (#character == 1 and 8 or 18)
        end
        return { x = width, y = 19 }
    end,
}

local function assert_lines_fit(label)
    for _, value in ipairs(texts) do
        assert(imgui.calc_text_size(value).x <= available_width,
            label .. " contains clipped text: " .. value)
    end
end

local scenario = {
    id = "tigrex_roar_single", name_zh = "咆哮", actions = { 19 },
    training_category = "independent", max_verified_repeats = 10,
    summary_zh = "独立单招训练。", verification = { status = "verified" },
}
local model = {
    profile = { training_quest = { id = 200032001 } },
    context = { in_quest = true, quest_no = 200032001, is_online = false,
        build_supported = true, target_found = true },
    scenarios = { scenario },
}
function model:training_catalog()
    return { { id = "independent", name = "独立关键招式", scenarios = { scenario } } }
end
function model:training_branch_tree()
    return { action = "19", name = "咆哮", kind = "unverified", candidates = {} }
end
local config = { forced_action_training_enabled = true, training_repeat_count = 1 }
local controller = Controller.new(model, {}, {}, config, {}, nil, nil)

controller:draw_training_menu()
local initial_text = table.concat(texts, "\n")
local initial_buttons = table.concat(buttons, "\n")
assert(initial_text:find("状态：%[请选择起手%]")
    and initial_buttons:find("查看派生树：咆哮", 1, true)
    and table.concat(checkboxes, "\n"):find("启用指定出招训练", 1, true)
    and not initial_buttons:find("开始：咆哮", 1, true),
    "initial menu renders one branch-preview entry and no premature start action")
assert_lines_fit("initial menu")

assert(controller:preview_training_scenario(scenario))
texts, buttons, checkboxes = {}, {}, {}
controller:draw_training_menu()
local preview_text = table.concat(texts, "\n")
local preview_buttons = table.concat(buttons, "\n")
assert(preview_text:find("状态：%[可开始%]")
    and preview_text:find("当前选择：咆哮", 1, true)
    and preview_text:find("起手: 咆哮", 1, true)
    and preview_buttons:find("开始当前起手 × 1", 1, true),
    "previewed menu renders the selected summary, branch tree and one start action")
assert_lines_fit("previewed menu")

controller.training_state = "running"
controller.training_status = "怪物正在执行“咆哮”"
controller.training_scenario = scenario
controller.training_target_rounds = 1
texts, buttons, checkboxes = {}, {}, {}
controller:draw_training_menu()
local active_text = table.concat(texts, "\n")
local active_buttons = table.concat(buttons, "\n")
assert(active_text:find("状态：%[训练中%]")
    and active_text:find("咆哮（当前训练）", 1, true)
    and active_text:find("进度：0/1", 1, true)
    and active_buttons:find("停止训练", 1, true)
    and not active_buttons:find("查看派生树", 1, true)
    and not active_buttons:find("开始：", 1, true),
    "active menu locks selection and repeat controls while preserving one visible stop action")
assert_lines_fit("active menu")

print("test_training_menu_render.lua: PASS")
