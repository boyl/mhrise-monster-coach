local M = {}

local function runtime_matches(scope, runtime)
    if type(scope) ~= "table" then return true end
    runtime = runtime or {}
    if scope.game_name ~= nil
        and tostring(scope.game_name) ~= tostring(runtime.game_name) then return false end
    if scope.tdb_version ~= nil
        and tonumber(scope.tdb_version) ~= tonumber(runtime.tdb_version) then return false end
    return true
end

local function best_match(node_name, row)
    local best = nil
    for _, value in ipairs(row.exact or {}) do
        if node_name == value then
            local candidate = { kind = "exact", value = value, score = 20000 + #value }
            if best == nil or candidate.score > best.score then best = candidate end
        end
    end
    for _, value in ipairs(row.prefixes or {}) do
        if string.sub(node_name, 1, #value) == value then
            local candidate = { kind = "prefix", value = value, score = 10000 + #value }
            if best == nil or candidate.score > best.score then best = candidate end
        end
    end
    return best
end

local function source_by_id(knowledge, source_id)
    for _, source in ipairs(knowledge.sources or {}) do
        if source.id == source_id then return source end
    end
    return nil
end

function M.resolve(combat_state, knowledge, runtime)
    if type(combat_state) ~= "table" then return nil, "player_state_unavailable" end
    if combat_state.weapon_type ~= "long_sword" then return nil, "unsupported_weapon" end
    if type(knowledge) ~= "table" then return nil, "knowledge_unavailable" end

    local action_state = combat_state.action_state
    local evidence = type(action_state) == "table" and action_state.evidence or nil
    local node_name = type(evidence) == "table" and evidence.node_name or nil
    if type(node_name) ~= "string" or node_name == "" then return nil, "node_name_unavailable" end

    local winner, winner_match = nil, nil
    for _, row in ipairs(knowledge.runtime_node_patterns or {}) do
        if runtime_matches(row.runtime_scope, runtime) then
            local match = best_match(node_name, row)
            if match ~= nil and (winner_match == nil or match.score > winner_match.score) then
                winner, winner_match = row, match
            end
        end
    end
    if winner == nil then return nil, "unmapped_node" end

    local definition = (knowledge.actions or {})[winner.semantic] or {}
    local source = source_by_id(knowledge, winner.source_id)
    return {
        semantic = winner.semantic,
        name = definition.name or winner.semantic,
        role = winner.role or "action",
        node_id = evidence.node_id,
        node_name = node_name,
        match_type = winner_match.kind,
        matched_pattern = winner_match.value,
        mapping_status = winner.evidence_status or "community_candidate",
        runtime_observed = true,
        source_id = winner.source_id,
        source_url = source and source.url or nil,
    }, nil
end

return M
