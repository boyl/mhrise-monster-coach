package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Presenter = require("MHRiseMonsterCoach.timeline_presenter")

local hit = Presenter.summarize({
    round_id = 7,
    outcome = "hit",
    dropped_events = 0,
    events = {
        { kind = "action_start", data = { action = "2", move_name = "直线冲锋" } },
        { kind = "hitbox_open", data = { motion_frame = 20 } },
        { kind = "damage", data = { motion_frame = 24, damage = 15 } },
        { kind = "hitbox_close", data = { motion_frame = 29, last_active_frame = 28 } },
        { kind = "result", data = { outcome = "hit" } },
    },
})
assert(hit.round_id == 7 and hit.tone == "failure")
assert(hit.text == "复盘: 直线冲锋 | 判定 20–28帧 | 受击")

local multi = Presenter.summarize({
    outcome = "no_damage",
    events = {
        { kind = "action_start", data = { action = "5000" } },
        { kind = "hitbox_open", data = { motion_frame = 10.5 } },
        { kind = "hitbox_close", data = { motion_frame = 12.5 } },
        { kind = "hitbox_open", data = { motion_frame = 20 } },
        { kind = "hitbox_close", data = { motion_frame = 22 } },
        { kind = "hitbox_open", data = { motion_frame = 30 } },
        { kind = "hitbox_close", data = { motion_frame = 31 } },
    },
})
assert(multi.tone == "success")
assert(multi.text == "复盘: Action 5000 | 判定 10.5–12.5帧/20–22帧/+1段 | 无伤")

local incomplete = Presenter.summarize({
    outcome = "unclassified",
    dropped_events = 3,
    events = { { kind = "action_start", data = {} } },
})
assert(incomplete.text == "复盘: 未知招式 | 判定未采集 | 结果待分类 | 事件不完整")
assert(incomplete.tone == "muted")
assert(Presenter.summarize(nil) == nil)

print("test_timeline_presenter.lua: PASS")
