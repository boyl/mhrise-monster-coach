package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Phase = require("MHRiseMonsterCoach.monster_phase")
local move = {
    timing = {
        status = "confirmed",
        unit = "frame",
        motion_name = "em032_attack",
        active_windows = {
            { start_frame = 20, end_frame = 24 },
            { start_frame = 30, end_frame = 34 },
        },
    },
}

assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 10 }) == "startup")
assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 22 }) == "active")
assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 27 }) == "active",
    "multi-hit gaps remain active until the final confirmed hit window ends")
assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 27,
    runtime_hitbox_phase = "recovery" }) == "active",
    "runtime off-edges between confirmed multi-hit windows must not advertise recovery")
assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 10,
    runtime_hitbox_phase = "active" }) == "active", "live active hitboxes always win")
assert(Phase.resolve(move, { motion_name = "em032_attack", current_frame = 40 }) == "recovery")
local live_phase, live_reason = Phase.resolve(nil, { runtime_hitbox_phase = "active" })
assert(live_phase == "active" and live_reason == "runtime_hitbox")

local phase, reason = Phase.resolve({ timing = { status = "observed" } }, { current_frame = 20 })
assert(phase == "unknown" and reason == "timing_unconfirmed")
phase, reason = Phase.resolve(move, { motion_name = "different", current_frame = 20 })
assert(phase == "unknown" and reason == "motion_mismatch")
phase, reason = Phase.resolve({ timing = {
    status = "confirmed", active_windows = { { start_frame = 30, end_frame = 20 } },
} }, { current_frame = 20 })
assert(phase == "unknown" and reason == "invalid_active_window")

print("test_monster_phase.lua: PASS")
