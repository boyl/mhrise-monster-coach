package.path = package.path .. ";./reframework/autorun/?.lua;./reframework/autorun/?/init.lua"

local Classifier = require("MHRiseMonsterCoach.outcome_classifier")

local function classify(events, options)
    return Classifier.classify(events, options or {})
end

local damage = { { kind = "damage", data = { damage = 10 } } }
assert(classify(damage, { outcome_tracking = true }).outcome == "hit")
assert(classify(damage, { outcome_tracking = true }).score == "failure")
assert(classify(damage, { outcome_tracking = false }).outcome == "observed_hit")
assert(classify(damage, { outcome_tracking = false }).score == "unclassified")

local verified_success = { { kind = "player_action", data = {
    semantic = "foresight_slash", name = "见切斩", role = "success", mapping_status = "verified_runtime",
} } }
local result = classify(verified_success, { outcome_tracking = false })
assert(result.outcome == "counter_success" and result.score == "success")
assert(result.label == "见切斩成功")

local candidate_success = { { kind = "player_action", data = {
    semantic = "iai_spirit_slash", name = "居合拔刀气刃斩", role = "success",
    mapping_status = "community_candidate",
} } }
result = classify(candidate_success, { outcome_tracking = false })
assert(result.outcome == "response_success_candidate" and result.score == "unclassified")
result = classify(candidate_success, { outcome_tracking = true })
assert(result.outcome == "no_damage" and result.score == "success")
assert(string.find(result.label, "待验证", 1, true))

local attempt = { { kind = "player_action", data = {
    semantic = "foresight_slash", name = "见切斩", role = "attempt",
    mapping_status = "community_candidate",
} } }
result = classify(attempt, { outcome_tracking = false })
assert(result.outcome == "response_attempt" and result.score == "unclassified")

result = classify({}, { outcome_tracking = true, damage = 0 })
assert(result.outcome == "no_damage" and result.label == "无伤（应对方式待确认）")
result = classify({}, { outcome_tracking = false })
assert(result.outcome == "unclassified")
result = classify({}, { interrupted = true })
assert(result.outcome == "interrupted")
result = classify(nil, {})
assert(result.reason == "invalid_events")

print("test_outcome_classifier.lua: PASS")
