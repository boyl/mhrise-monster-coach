package.path = package.path .. ";./reframework/autorun/?.lua;./reframework/autorun/?/init.lua"

local Skills = require("MHRiseMonsterCoach.long_sword_switch_skills")

local base, base_error = Skills.resolve({ 0, 0, 0, 0, 0, 0 })
assert(base_error == nil)
assert(base[1] == "step_slash")
assert(base[2] == "spirit_roundslash_combo")
assert(base[3] == "special_sheathe_combo")
assert(base[4] == "soaring_kick")
assert(base[5] == "serene_pose")

local replaced = Skills.resolve({ 1, 1, 1, 1, 0, 1 })
assert(replaced[1] == "drawn_double_slash")
assert(replaced[2] == "spirit_reckoning_combo")
assert(replaced[3] == "sacred_sheathe_combo")
assert(replaced[4] == "silkbind_sakura_slash")
assert(replaced[5] == "harvest_moon")

local tempered = Skills.resolve({ 0, 1, 0, 0, 1, 0 })
assert(tempered[4] == "tempered_spirit_blade", "new MR flag overrides the legacy slot-four pair")

local missing, missing_error = Skills.resolve({ 0, 0, 0 })
assert(missing == nil and missing_error == "incomplete_replace_attack_flags")

local unknown, unknown_error = Skills.resolve({ 2, 0, 0, 0, 0, 0 })
assert(unknown == nil and unknown_error == "unknown_replace_attack_flag_1")

print("test_long_sword_switch_skills.lua: PASS")
