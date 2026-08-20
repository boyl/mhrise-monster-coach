package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Bootstrap = require("MHRiseMonsterCoach.startup_bootstrap_controller")

local request = { session_id = "bootstrap-1", auto_load_save = true }
local view = { build_supported = true, title_state = 0 }
local statuses, ack = {}, nil
local api = {}
function api:read_request() local result = request request = nil return result end
function api:observe() return view end
function api:write_status(status) statuses[#statuses + 1] = status end
function api:read_ack() return ack end
function api:advance_to_press_any() view.title_state = 1 return true end
function api:advance_to_title_menu() view.title_state = 2 return true end
function api:dismiss_autosave_notice() return true end
function api:open_load_data_menu() return true end
function api:select_title_menu(index)
    assert(index == 1, "only Continue may be selected")
    view.title_cursor_index = index
    return true
end
function api:select_save_slot(index)
    assert(index == 0, "only the first save slot may be selected")
    view.current_save_slot = index
    return true
end

local bootstrap = Bootstrap.new(api)
bootstrap.frame = 30
bootstrap:update()
bootstrap:update()
bootstrap:update()
bootstrap:update()
assert(view.title_cursor_index == 1, "Continue is selected and verified before native transition")
view = { build_supported = true, save_menu_available = true, current_save_slot = 2 }
bootstrap:update()
assert(statuses[#statuses].action.id == "bootstrap-1:choose_first_save")
assert(view.current_save_slot == 0, "first slot is selected and verified before F")
ack = { session_id = "bootstrap-1", action_id = statuses[#statuses].action.id }
bootstrap:update()
ack = nil
view = { build_supported = true, in_hub = true }
bootstrap:update()
assert(statuses[#statuses].status == "completed")

local unsafe_request = { session_id = "bootstrap-unsafe", auto_load_save = true }
function api:read_request() local result = unsafe_request unsafe_request = nil return result end
view = { build_supported = true, title_state = 3 }
local unsafe = Bootstrap.new(api)
unsafe.frame = 30
unsafe:update()
unsafe:update()
assert(statuses[#statuses].status == "failed")
assert(string.find(statuses[#statuses].reason, "New Game", 1, true))

print("test_startup_bootstrap_controller.lua: PASS")
