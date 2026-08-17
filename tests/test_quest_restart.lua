package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path
local QuestRestart = require("MHRiseMonsterCoach.quest_restart")

local calls = {}
local api = {}
local function called(name) calls[#calls + 1] = name return true end
function api:request_reset() return called("reset") end
function api:is_hub_ready() return true end
function api:open_counter() return called("open") end
function api:start_session() return called("session") end
function api:tick_posting() return true end
function api:select_quest() return called("select") end
function api:update_posting() return called("posted") end
function api:is_counter_closed() return true end
function api:depart() return called("depart") end
function api:finish_posting() called("finish") end
function api:cancel_posting() called("cancel") end

local restart = QuestRestart.new(api, 200032001, { hub_stable_frames = 2, timeout_frames = 30 })
assert(QuestRestart.new(api, 200032001).hub_stable_required == 600,
    "production waits for the proven lobby initialization interval")
local quest = { in_quest = true, is_online = false, build_supported = true, quest_no = 200032001 }
assert(restart:start(quest) == true and restart.state == "wait_hub", "starts with native reset")
assert(restart:start(quest) == false, "duplicate start is rejected")

local hub = { in_quest = false, is_online = false, build_supported = true }
restart:update(hub)
restart:update(hub)
for _ = 1, 6 do restart:update(hub) end
assert(restart.state == "wait_quest", "posts and departs without a second input")
restart:update(quest)
assert(restart.state == "complete", "completes only after the target quest is loaded")
assert(table.concat(calls, ",") == "reset,open,session,select,posted,depart,finish",
    "uses the bounded native workflow in order")

local bad_api = {}
for name, fn in pairs(api) do bad_api[name] = fn end
function bad_api:open_counter() return false, "counter unavailable" end
local failed = QuestRestart.new(bad_api, 200032001, { hub_stable_frames = 1, timeout_frames = 30 })
assert(failed:start(quest))
failed:update(hub)
failed:update(hub)
assert(failed.state == "failed" and failed.error == "counter unavailable",
    "expected runtime failure stops automation")

print("test_quest_restart.lua: PASS")
