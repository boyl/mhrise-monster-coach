package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local Semantics = require("MHRiseMonsterCoach.player_action_semantics")

local knowledge = {
    sources = { { id = "community", url = "https://example.invalid/reference" } },
    actions = {
        foresight_slash = { name = "见切斩" },
        iai_spirit_slash = { name = "居合拔刀气刃斩" },
    },
    runtime_node_patterns = {
        {
            semantic = "foresight_slash", role = "attempt",
            exact = { "atk.atk_147.atk_147" }, prefixes = { "atk.atk_147.atk_147." },
            evidence_status = "community_candidate", source_id = "community",
            runtime_scope = { game_name = "mhrise", tdb_version = 71 },
        },
        {
            semantic = "foresight_slash", role = "success",
            exact = { "atk.atk_147.atk_147_end" },
            evidence_status = "community_candidate", source_id = "community",
            runtime_scope = { game_name = "mhrise", tdb_version = 71 },
        },
        {
            semantic = "iai_spirit_slash", role = "success",
            exact = { "atk.atk151.atk_155.success" },
            evidence_status = "runtime_verified", source_id = "community",
        },
    },
}

local function state(node_name, weapon)
    return {
        weapon_type = weapon or "long_sword",
        action_state = { evidence = { node_id = 42, node_name = node_name } },
    }
end

local result, reason = Semantics.resolve(state("atk.atk_147.atk_147"), knowledge,
    { game_name = "mhrise", tdb_version = 71 })
assert(reason == nil and result.semantic == "foresight_slash")
assert(result.name == "见切斩" and result.role == "attempt")
assert(result.match_type == "exact" and result.runtime_observed == true)
assert(result.mapping_status == "community_candidate")

result = Semantics.resolve(state("atk.atk_147.atk_147.follow"), knowledge,
    { game_name = "mhrise", tdb_version = 71 })
assert(result.role == "attempt" and result.match_type == "prefix")

result = Semantics.resolve(state("atk.atk_147.atk_147_end"), knowledge,
    { game_name = "mhrise", tdb_version = 71 })
assert(result.role == "success", "longer exact success node must beat the attempt family")

result, reason = Semantics.resolve(state("atk.atk_147.atk_147"), knowledge,
    { game_name = "mhrise", tdb_version = 72 })
assert(result == nil and reason == "unmapped_node", "runtime-scoped candidates must fail closed")

result, reason = Semantics.resolve(state("atk.atk151.atk_155.success", "dual_blades"), knowledge,
    { game_name = "mhrise", tdb_version = 71 })
assert(result == nil and reason == "unsupported_weapon")

result, reason = Semantics.resolve(state("wait.main"), knowledge,
    { game_name = "mhrise", tdb_version = 71 })
assert(result == nil and reason == "unmapped_node")

print("test_player_action_semantics.lua: PASS")
