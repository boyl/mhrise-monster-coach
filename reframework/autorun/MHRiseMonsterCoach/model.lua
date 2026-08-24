local M = {}
local LongSwordResponse = require("MHRiseMonsterCoach.response_long_sword")
local MonsterPhase = require("MHRiseMonsterCoach.monster_phase")
local TrainingTimeline = require("MHRiseMonsterCoach.training_timeline")
local PlayerActionSemantics = require("MHRiseMonsterCoach.player_action_semantics")
local OutcomeClassifier = require("MHRiseMonsterCoach.outcome_classifier")

M.states = {
    INITIAL = "initial",
    WAITING = "waiting",
    OBSERVING = "observing",
    READY = "ready",
    RUNNING = "running",
    SUCCESS = "success",
    FAILURE = "failure",
    DISABLED = "disabled",
    ERROR = "error",
}

local function bounded_append(list, value, limit)
    list[#list + 1] = value
    if #list > limit then table.remove(list, 1) end
end

local function merge_profile(profile, calibration, static_ai)
    local moves = {}
    for key, value in pairs(profile.moves or {}) do moves[tostring(key)] = value end
    for key, value in pairs(calibration.moves or {}) do moves[tostring(key)] = value end

    local scenarios = {}
    for _, value in ipairs(profile.scenarios or {}) do scenarios[#scenarios + 1] = value end
    for _, value in ipairs((static_ai and static_ai.training_scenarios) or {}) do
        scenarios[#scenarios + 1] = value
    end
    for _, value in ipairs(calibration.scenarios or {}) do scenarios[#scenarios + 1] = value end
    return moves, scenarios
end

local function rebuild_evidence_row(row)
    if type(row) ~= "table" or type(row.observations) ~= "table" then return false end
    local normalized, changed = {}, false
    for _, observation in ipairs(row.observations) do
        local current, last_start = {}, nil
        for _, window in ipairs(observation) do
            local start_frame, end_frame = tonumber(window.start_frame), tonumber(window.end_frame)
            if start_frame and end_frame and end_frame >= start_frame then
                if last_start and start_frame < last_start then
                    if #current > 0 then normalized[#normalized + 1] = current end
                    current, changed = {}, true
                end
                current[#current + 1] = window
                last_start = start_frame
            else changed = true end
        end
        if #current > 0 then normalized[#normalized + 1] = current end
    end
    if not changed then return false end
    row.observations, row.samples = normalized, #normalized
    row.window_count, row.aggregate_windows = nil, {}
    row.variable_window_count = nil
    local stable = true
    for _, observation in ipairs(normalized) do
        row.window_count = row.window_count or #observation
        if row.window_count ~= #observation then row.variable_window_count = true end
        for index, window in ipairs(observation) do
            local aggregate = row.aggregate_windows[index] or {}
            local start_frame, end_frame = tonumber(window.start_frame), tonumber(window.end_frame)
            aggregate.min_start_frame = aggregate.min_start_frame
                and math.min(aggregate.min_start_frame, start_frame) or start_frame
            aggregate.max_start_frame = aggregate.max_start_frame
                and math.max(aggregate.max_start_frame, start_frame) or start_frame
            aggregate.min_end_frame = aggregate.min_end_frame
                and math.min(aggregate.min_end_frame, end_frame) or end_frame
            aggregate.max_end_frame = aggregate.max_end_frame
                and math.max(aggregate.max_end_frame, end_frame) or end_frame
            if aggregate.max_start_frame - aggregate.min_start_frame > 3
                or aggregate.max_end_frame - aggregate.min_end_frame > 3 then stable = false end
            row.aggregate_windows[index] = aggregate
        end
    end
    row.status = row.variable_window_count and "variable"
        or (row.samples >= 3 and stable and "confirmed"
        or (row.samples >= 2 and "repeated" or "observed"))
    return true
end

function M.new(profile, calibration, config, static_ai, long_sword_knowledge)
    local moves, scenarios = merge_profile(profile, calibration, static_ai)
    local self = setmetatable({
        state = M.states.INITIAL,
        status = "Waiting for a single-player quest",
        profile = profile,
        moves = moves,
        scenarios = scenarios,
        calibration_scenarios = calibration.scenarios or {},
        static_ai = static_ai or { actions = {} },
        long_sword_knowledge = long_sword_knowledge or { actions = {} },
        player_combat_state = nil,
        current_player_action_semantic = nil,
        last_player_action_semantic_key = nil,
        response_candidates = {},
        response_error = nil,
        current_action = nil,
        current_state_key = nil,
        current_move = nil,
        current_metadata = nil,
        action_started_at = 0,
        prediction = nil,
        transitions = {},
        history = {},
        state_metadata = {},
        state_metadata_count = 0,
        hit_timing_evidence = calibration.observed_hit_timing or {},
        hitbox_window_evidence = calibration.observed_hitbox_windows or {},
        current_hitbox_observation = nil,
        evidence_revision = 0,
        live_hitbox_seen = false,
        live_hitbox_state_key = nil,
        unknown_actions = {},
        unknown_action_count = 0,
        learned_actions = 0,
        rounds = 0,
        state_changes = 0,
        successes = 0,
        failures = 0,
        streak = 0,
        round_damage = 0,
        last_result = nil,
        last_hit_event = nil,
        training_timeline = TrainingTimeline.new(config.timeline_event_limit or 128),
        config = config,
        context = { in_quest = false, is_online = false, target_found = false },
    }, { __index = M })
    for _, row in pairs(self.hitbox_window_evidence) do
        if rebuild_evidence_row(row) then self.evidence_revision = 1 end
    end
    return self
end

local function confirmed_evidence_move(self)
    local metadata = self.current_metadata or {}
    local state = tostring(self.current_state_key or "")
    local motion = tostring(metadata.motion_name or "unknown_motion")
    local row = self.hitbox_window_evidence[state .. "|" .. motion]
        or self.hitbox_window_evidence[state]
    if type(row) ~= "table" or row.status ~= "confirmed"
        or type(row.aggregate_windows) ~= "table" then return nil end
    local windows = {}
    for _, aggregate in ipairs(row.aggregate_windows) do
        local start_frame = tonumber(aggregate.min_start_frame)
        local end_frame = tonumber(aggregate.max_end_frame)
        if start_frame and end_frame and end_frame >= start_frame then
            windows[#windows + 1] = { start_frame = start_frame, end_frame = end_frame }
        end
    end
    if #windows == 0 then return nil end
    return { timing = { status = "confirmed", unit = "frame",
        motion_name = row.motion_name, active_windows = windows,
        source = "automatic_native_evidence" } }
end

local function monster_phase(self)
    return MonsterPhase.resolve(confirmed_evidence_move(self) or self.current_move,
        self.current_metadata)
end

function M.current_monster_phase(self)
    return monster_phase(self)
end

function M.training_branch_tree(self, scenario, max_depth)
    max_depth = math.max(1, math.min(5, math.floor(tonumber(max_depth) or 3)))
    local root = type(scenario) == "table" and type(scenario.actions) == "table"
        and tostring(scenario.actions[1]) or nil
    if root == nil then return nil end
    local path = {}
    local function build(action, depth)
        action = tostring(action)
        local move = self.moves[action]
            or (self.static_ai.moves and self.static_ai.moves[action]) or {}
        local row = self.static_ai.actions and self.static_ai.actions[action] or nil
        local node = {
            action = action,
            name = move.short_name or move.name or ("Action " .. action),
            kind = row and row.kind or "unverified",
            candidates = {},
        }
        if path[action] then node.cycle = true return node end
        if depth >= max_depth or type(row) ~= "table" or type(row.next) ~= "table" then
            node.truncated = depth >= max_depth and type(row) == "table" and #(row.next or {}) > 0
            return node
        end
        path[action] = true
        for _, edge in ipairs(row.next) do
            local target = edge and edge.action
            if target ~= nil then
                node.candidates[#node.candidates + 1] = {
                    evidence_count = tonumber(edge.evidence_count) or 0,
                    condition = edge.condition,
                    node = build(target, depth + 1),
                }
            end
        end
        path[action] = nil
        return node
    end
    return build(root, 0)
end

function M.training_catalog(self)
    local group_definitions = {
        independent = { id = "independent", name = "独立关键招式", order = 10 },
        fixed_branch = { id = "fixed_branch", name = "固定派生起手", order = 20 },
        conditional_branch = { id = "conditional_branch", name = "条件派生起手", order = 30 },
        random_branch = { id = "random_branch", name = "随机派生起手", order = 40 },
        observed_branch = { id = "observed_branch", name = "仅观察派生起手", order = 50 },
    }
    local groups = {}
    for _, scenario in ipairs(self.scenarios or {}) do
        local group = group_definitions[scenario.training_category]
            or { id = "other", name = "其他已验证训练", order = 90 }
        local bucket = groups[group.id]
        if bucket == nil then
            bucket = { id = group.id, name = group.name, order = group.order, scenarios = {} }
            groups[group.id] = bucket
        end
        bucket.scenarios[#bucket.scenarios + 1] = scenario
    end
    local result = {}
    for _, group in pairs(groups) do
        table.sort(group.scenarios, function(left, right)
            local left_order = tonumber(left.training_order) or 1000
            local right_order = tonumber(right.training_order) or 1000
            if left_order ~= right_order then return left_order < right_order end
            return tostring(left.id) < tostring(right.id)
        end)
        result[#result + 1] = group
    end
    table.sort(result, function(left, right)
        if left.order ~= right.order then return left.order < right.order end
        return left.id < right.id
    end)
    return result
end

function M.coaching_state(self)
    local phase, source = monster_phase(self)
    local state = { phase = phase, source = source }
    local metadata = self.current_metadata or {}
    local move = confirmed_evidence_move(self) or self.current_move
    local timing = move and move.timing
    local current = tonumber(metadata.current_frame)
    if current and type(timing) == "table" and type(timing.active_windows) == "table" then
        local next_start, final_end = nil, nil
        for _, window in ipairs(timing.active_windows) do
            local start_frame = tonumber(window.start_frame or window.start_value)
            local end_frame = tonumber(window.end_frame or window.end_value)
            if start_frame and end_frame then
                final_end = final_end and math.max(final_end, end_frame) or end_frame
                if start_frame > current and (next_start == nil or start_frame < next_start) then
                    next_start = start_frame
                end
            end
        end
        if next_start then state.frames_to_next_active = math.max(0, next_start - current) end
        if final_end then state.frames_from_final_active = current - final_end end
    end
    return state
end

local function timeline_player_action(self, semantic)
    local event = {}
    for key, value in pairs(semantic) do event[key] = value end
    local phase = M.coaching_state(self)
    event.monster_phase = phase.phase
    event.frames_to_next_active = phase.frames_to_next_active
    event.frames_from_final_active = phase.frames_from_final_active
    event.monster_motion_frame = self.current_metadata and tonumber(self.current_metadata.current_frame) or nil
    return event
end

function M.update_player_combat_state(self, state, at)
    self.player_combat_state = state
    local semantic = nil
    if type(state) == "table" then
        semantic = PlayerActionSemantics.resolve(state, self.long_sword_knowledge, {
            game_name = self.context.game_name,
            tdb_version = self.context.tdb_version,
        })
        self.current_player_action_semantic = semantic
        state.action_state = state.action_state or {}
        state.action_state.current_action = semantic and semantic.semantic or nil
        state.action_state.current_action_role = semantic and semantic.role or nil
        if semantic ~= nil then
            local key = table.concat({
                tostring(semantic.semantic), tostring(semantic.role),
                tostring(semantic.node_id), tostring(semantic.node_name),
            }, "|")
            if key ~= self.last_player_action_semantic_key then
                self.training_timeline:record("player_action", at, timeline_player_action(self, semantic))
                self.last_player_action_semantic_key = key
            end
        else
            self.last_player_action_semantic_key = nil
        end
    else
        self.current_player_action_semantic = nil
        self.last_player_action_semantic_key = nil
    end
    if type(state) ~= "table" or self.current_action == nil then
        self.response_candidates = {}
        self.response_error = state == nil and "player_state_unavailable" or nil
        return
    end
    local results, response_error = LongSwordResponse.evaluate({
        state_key = self.current_state_key,
        phase = monster_phase(self),
    }, state)
    local actions = self.long_sword_knowledge.actions or {}
    for _, item in ipairs(results) do
        local knowledge = actions[item.action]
        item.name = knowledge and knowledge.name or item.action
    end
    self.response_candidates = results
    self.response_error = response_error
end

function M.observe_hitboxes(self, sample)
    if self.current_action == nil or type(sample) ~= "table" then return false end
    if self.live_hitbox_state_key ~= self.current_state_key then
        self.live_hitbox_state_key = self.current_state_key
        self.live_hitbox_seen = false
    end
    local metadata = self.current_metadata or {}
    local observation = self.current_hitbox_observation
    local frame = tonumber(metadata.current_frame)
    local progress = tonumber(metadata.motion_progress)
    if observation and observation.state_key == self.current_state_key then
        local motion_changed = observation.motion_name ~= nil and metadata.motion_name ~= nil
            and observation.motion_name ~= metadata.motion_name
        local frame_wrapped = frame ~= nil and observation.last_frame ~= nil
            and frame < observation.last_frame - 1
        if motion_changed or frame_wrapped then
            M.finalize_hitbox_observation(self)
            observation = nil
        end
    end
    if observation == nil or observation.state_key ~= self.current_state_key then
        observation = { state_key = self.current_state_key, action = self.current_action,
            motion_name = metadata.motion_name, bank_id = metadata.bank_id,
            motion_id = metadata.motion_id, windows = {}, was_active = false }
        self.current_hitbox_observation = observation
    end
    local active = sample.active == true
    if active then self.live_hitbox_seen = true end
    if active and not observation.was_active then
        observation.open_window = { start_frame = frame, start_progress = progress,
            entries = sample.entries, max_active_count = tonumber(sample.active_count) or 0 }
        self.training_timeline:record("hitbox_open", nil, {
            motion_frame = frame,
            motion_progress = progress,
            active_count = tonumber(sample.active_count) or 0,
            source = sample.source,
        })
    elseif active and observation.open_window then
        observation.open_window.max_active_count = math.max(
            observation.open_window.max_active_count, tonumber(sample.active_count) or 0)
    end
    if active and observation.open_window then
        observation.open_window.last_active_frame = frame
        observation.open_window.last_active_progress = progress
    elseif not active and observation.was_active and observation.open_window then
        observation.open_window.end_frame = observation.open_window.last_active_frame
        observation.open_window.end_progress = observation.open_window.last_active_progress
        observation.open_window.last_active_frame = nil
        observation.open_window.last_active_progress = nil
        observation.windows[#observation.windows + 1] = observation.open_window
        self.training_timeline:record("hitbox_close", nil, {
            motion_frame = frame,
            last_active_frame = observation.open_window.end_frame,
            motion_progress = progress,
            source = sample.source,
        })
        observation.open_window = nil
    end
    observation.was_active = active
    observation.last_frame = frame or observation.last_frame
    self.current_metadata = self.current_metadata or {}
    self.current_metadata.runtime_hitbox_phase = active and "active"
        or (self.live_hitbox_seen and "recovery" or "startup")
    self.current_metadata.runtime_hitbox_count = tonumber(sample.active_count) or 0
    self.current_metadata.runtime_hitbox_source = sample.source
    self.current_metadata.runtime_hitbox_entries = sample.entries
    return true
end

function M.finalize_hitbox_observation(self)
    local observation = self.current_hitbox_observation
    if type(observation) ~= "table" then return false end
    if observation.open_window then
        observation.open_window.end_frame = observation.open_window.last_active_frame
        observation.open_window.end_progress = observation.open_window.last_active_progress
        observation.open_window.last_active_frame = nil
        observation.open_window.last_active_progress = nil
        observation.windows[#observation.windows + 1] = observation.open_window
        self.training_timeline:record("hitbox_close", nil, {
            motion_frame = observation.open_window.end_frame,
            motion_progress = observation.open_window.end_progress,
            reason = "action_ended",
        })
        observation.open_window = nil
    end
    self.current_hitbox_observation = nil
    if #observation.windows == 0 then return false end
    local state_key_value = tostring(observation.state_key)
    local motion_key = tostring(observation.motion_name or "unknown_motion")
    local key = state_key_value .. "|" .. motion_key
    local legacy = self.hitbox_window_evidence[state_key_value]
    if type(legacy) == "table" and legacy.motion_name == observation.motion_name then
        key = state_key_value
    end
    local row = self.hitbox_window_evidence[key]
    if row == nil then
        row = { action = observation.action, state_key = key,
            motion_name = observation.motion_name, bank_id = observation.bank_id,
            motion_id = observation.motion_id, samples = 0, observations = {} }
        self.hitbox_window_evidence[key] = row
    end
    row.samples = row.samples + 1
    row.observations[#row.observations + 1] = observation.windows
    self.evidence_revision = self.evidence_revision + 1
    if #row.observations > 32 then table.remove(row.observations, 1) end
    if row.window_count == nil then row.window_count = #observation.windows end
    if row.window_count == #observation.windows then
        row.aggregate_windows = row.aggregate_windows or {}
        local stable = true
        for index, window in ipairs(observation.windows) do
            local aggregate = row.aggregate_windows[index] or {}
            local start_frame, end_frame = tonumber(window.start_frame), tonumber(window.end_frame)
            if start_frame and end_frame then
                aggregate.min_start_frame = aggregate.min_start_frame
                    and math.min(aggregate.min_start_frame, start_frame) or start_frame
                aggregate.max_start_frame = aggregate.max_start_frame
                    and math.max(aggregate.max_start_frame, start_frame) or start_frame
                aggregate.min_end_frame = aggregate.min_end_frame
                    and math.min(aggregate.min_end_frame, end_frame) or end_frame
                aggregate.max_end_frame = aggregate.max_end_frame
                    and math.max(aggregate.max_end_frame, end_frame) or end_frame
                if aggregate.max_start_frame - aggregate.min_start_frame > 3
                    or aggregate.max_end_frame - aggregate.min_end_frame > 3 then stable = false end
            else stable = false end
            row.aggregate_windows[index] = aggregate
        end
        row.status = row.variable_window_count and "variable"
            or (row.samples >= 3 and stable and "confirmed"
            or (row.samples >= 2 and "repeated" or "observed"))
    else
        row.variable_window_count = true
        row.status = "variable"
    end
    return true
end

function M.hitbox_window_summary(self)
    local summary = { actions = 0, observations = 0, confirmed = 0, variable = 0 }
    for _, row in pairs(self.hitbox_window_evidence) do
        summary.actions = summary.actions + 1
        summary.observations = summary.observations + (tonumber(row.samples) or 0)
        if row.status == "confirmed" then summary.confirmed = summary.confirmed + 1 end
        if row.status == "variable" then summary.variable = summary.variable + 1 end
    end
    return summary
end

function M.set_context(self, context)
    local was_in_quest = self.context.in_quest
    if was_in_quest and not context.in_quest then
        M.finalize_hitbox_observation(self)
        self.training_timeline:reset("left_quest")
        self.current_action = nil
        self.current_state_key = nil
        self.current_move = nil
        self.current_metadata = nil
        self.prediction = nil
        self.current_player_action_semantic = nil
        self.last_player_action_semantic_key = nil
        self.round_damage = 0
        self.live_hitbox_seen = false
        self.live_hitbox_state_key = nil
    end
    self.context = context
    if context.error then
        self.state = M.states.ERROR
        self.status = context.error
    elseif context.safe_mode then
        self.state = M.states.DISABLED
        self.status = "Diagnostic mode: polling and guarded training controls enabled"
    elseif context.build_supported == false then
        self.state = M.states.DISABLED
        self.status = string.format("Read-only: unsupported runtime %s / TDB %s", tostring(context.game_name), tostring(context.tdb_version))
    elseif context.is_online then
        self.state = M.states.DISABLED
        self.status = "Disabled: multiplayer quest detected"
    elseif not context.in_quest then
        self.state = M.states.WAITING
        self.status = "Enter a single-player quest"
    elseif not context.target_found then
        self.state = M.states.OBSERVING
        self.status = "Waiting for Tigrex (em032_00)"
    elseif not context.reader_ready then
        self.state = M.states.OBSERVING
        self.status = "Calibrating the action reader"
    elseif self.current_action == nil then
        self.state = M.states.READY
        self.status = "Reader ready; waiting for an action"
    elseif self.state ~= M.states.SUCCESS and self.state ~= M.states.FAILURE then
        self.state = M.states.RUNNING
        self.status = "Training round active"
    end
end

local function named_move(self, action, metadata)
    local key = tostring(action)
    local move = self.moves[key]
    if move then return move end
    local static_move = self.static_ai and self.static_ai.moves and self.static_ai.moves[key]
    if static_move then
        local threat = self.static_ai.threats and self.static_ai.threats[key]
        if threat then
            local enriched = {}
            for field, value in pairs(static_move) do enriched[field] = value end
            enriched.threat = threat
            return enriched
        end
        return static_move
    end
    metadata = metadata or self.state_metadata[key]
    if metadata and type(metadata.motion_name) == "string" and metadata.motion_name ~= "" then
        return {
            name = metadata.motion_name,
            short_name = metadata.motion_name,
            advice = "Engine motion name captured; combat meaning awaits confirmation.",
            certainty = "engine_name",
        }
    end
    return {
        name = "Uncatalogued action " .. key,
        short_name = "Action " .. key,
        advice = "Observe the tell; add a name and advice in tigrex_calibration.json.",
        certainty = "unknown",
    }
end

local function action_category(metadata)
    return metadata and tonumber(metadata.action_category) or nil
end

local function required_action_category(self)
    return self.static_ai and tonumber(self.static_ai.required_action_category) or nil
end

local function is_coaching_action(self, metadata)
    local required = required_action_category(self)
    return required == nil or action_category(metadata) == required
end

local function state_key(action, metadata)
    local category = action_category(metadata)
    if category == nil then return tostring(action) end
    return tostring(category) .. ":" .. tostring(action)
end

local function action_from_state_key(key)
    return tostring(key):match("^[^:]+:(.+)$") or tostring(key)
end

local function record_state_metadata(self, action, metadata)
    if metadata == nil then return end
    if self.state_metadata[action] == nil then
        if self.state_metadata_count >= self.config.learned_action_limit then return end
        self.state_metadata_count = self.state_metadata_count + 1
    end
    self.state_metadata[action] = metadata
end

local function learned_prediction(self, action)
    local row = self.transitions[tostring(action)]
    if not row or row.total < self.config.min_prediction_samples then return nil end

    local candidates = {}
    for next_action, count in pairs(row.next) do
        candidates[#candidates + 1] = {
            action = action_from_state_key(next_action),
            name = named_move(self, action_from_state_key(next_action)).short_name,
            count = count,
            probability = count / row.total,
        }
    end
    table.sort(candidates, function(a, b) return a.count > b.count end)

    return {
        kind = #candidates == 1 and "observed_single" or "observed_candidates",
        samples = row.total,
        candidates = candidates,
    }
end

local function normalized_prediction_kind(kind, candidate_count)
    kind = tostring(kind or "conditional")
    if kind == "fixed" then
        return candidate_count == 1 and "fixed" or "unresolved"
    end
    if kind == "conditional" or kind == "random" or kind == "observed"
        or kind == "unresolved" then return kind end
    return "unresolved"
end

local function profile_prediction(self, move)
    if not move or type(move.next) ~= "table" then return nil end
    local candidates = {}
    for _, item in ipairs(move.next) do
        local action = tostring(item.action)
        candidates[#candidates + 1] = {
            action = action,
            name = named_move(self, action).short_name,
            condition = item.condition,
            probability = item.probability,
        }
    end
    local kind = normalized_prediction_kind(move.next_kind, #candidates)
    return {
        kind = kind,
        samples = move.samples,
        candidates = candidates,
    }
end

local function static_prediction(self, action, metadata)
    local pack = self.static_ai or {}
    local required_category = tonumber(pack.required_action_category)
    local current_category = metadata and tonumber(metadata.action_category) or nil
    if required_category == nil or current_category ~= required_category then return nil end
    local row = pack.actions and pack.actions[tostring(action)] or nil
    if type(row) ~= "table" or type(row.next) ~= "table" then return nil end
    local candidates = {}
    for _, item in ipairs(row.next) do
        local next_action = tostring(item.action)
        candidates[#candidates + 1] = {
            action = next_action,
            name = named_move(self, next_action).short_name,
            condition = item.condition,
            evidence_count = item.evidence_count,
        }
    end
    local kind = normalized_prediction_kind(row.kind, #candidates)
    return {
        kind = kind,
        source = "static_ai",
        evidence_count = row.evidence_count,
        candidates = candidates,
    }
end

function M.reload_static_ai(self, static_ai)
    if type(static_ai) ~= "table" or type(static_ai.actions) ~= "table"
        or (type(static_ai.validation) == "table" and static_ai.validation.ok == false) then return false end
    self.static_ai = static_ai
    local _, scenarios = merge_profile(self.profile,
        { moves = {}, scenarios = self.calibration_scenarios }, static_ai)
    self.scenarios = scenarios
    if self.current_action ~= nil then
        local metadata = self.current_metadata
        self.current_move = is_coaching_action(self, metadata) and named_move(self, self.current_action, metadata) or nil
        self.prediction = self.current_move and (profile_prediction(self, self.current_move)
            or static_prediction(self, self.current_action, metadata)
            or learned_prediction(self, self.current_state_key)) or nil
    end
    return true
end

local function record_transition(self, from_action, to_action)
    if from_action == nil or to_action == nil or from_action == to_action then return end
    local key = tostring(from_action)
    local next_key = tostring(to_action)
    local row = self.transitions[key]
    if not row then
        if self.learned_actions >= self.config.learned_action_limit then return end
        row = { total = 0, next = {} }
        self.transitions[key] = row
        self.learned_actions = self.learned_actions + 1
    end
    row.total = row.total + 1
    row.next[next_key] = (row.next[next_key] or 0) + 1
end

function M.finish_round(self, now)
    if self.current_action == nil then return end
    self.rounds = self.rounds + 1
    local classification = OutcomeClassifier.classify(self.training_timeline.events, {
        outcome_tracking = true,
        damage = self.round_damage,
    })
    self.training_timeline:finish(now, classification.outcome, {
        action = tostring(self.current_action),
        state_key = self.current_state_key,
        damage = self.round_damage,
        classification = classification,
    })
    if classification.score == "failure" then
        self.failures = self.failures + 1
        self.streak = 0
        self.state = M.states.FAILURE
        self.last_result = string.format("%s: %.1f damage", classification.label, self.round_damage)
    elseif classification.score == "success" then
        self.successes = self.successes + 1
        self.streak = self.streak + 1
        self.state = M.states.SUCCESS
        self.last_result = classification.label
    else
        self.state = M.states.RUNNING
        self.last_result = classification.label
    end
    self.round_damage = 0
end

function M.observe_action(self, action, now, metadata)
    if action == nil then return false end
    action = tostring(action)
    local next_state_key = state_key(action, metadata)
    record_state_metadata(self, next_state_key, metadata)
    if next_state_key == self.current_state_key then
        self.current_metadata = metadata or self.current_metadata
        if self.current_move and self.moves[action] == nil and metadata and metadata.motion_name then
            self.current_move = named_move(self, action, metadata)
        end
        return false
    end

    local previous = self.current_action
    local previous_state_key = self.current_state_key
    local previous_metadata = self.current_metadata
    if previous ~= nil then
        M.finalize_hitbox_observation(self)
        if self.context.outcome_tracking == true then
            M.finish_round(self, now)
        else
            local classification = OutcomeClassifier.classify(self.training_timeline.events, {
                outcome_tracking = false,
            })
            self.training_timeline:finish(now, classification.outcome, {
                action = tostring(previous),
                state_key = previous_state_key,
                outcome_tracking = false,
                classification = classification,
            })
            self.state_changes = self.state_changes + 1
        end
        if is_coaching_action(self, previous_metadata) and is_coaching_action(self, metadata) then
            record_transition(self, previous_state_key, next_state_key)
        end
    end

    local event_time = now or 0
    local duration = previous and math.max(0, event_time - self.action_started_at) or nil
    self.current_action = action
    self.current_state_key = next_state_key
    self.current_move = is_coaching_action(self, metadata) and named_move(self, action, metadata) or nil
    self.current_metadata = metadata
    self.live_hitbox_seen = false
    self.live_hitbox_state_key = next_state_key
    self.action_started_at = event_time
    self.prediction = self.current_move and (profile_prediction(self, self.current_move)
        or static_prediction(self, action, metadata)
        or learned_prediction(self, next_state_key)) or nil
    self.training_timeline:start(event_time, {
        action = action,
        state_key = next_state_key,
        move_name = self.current_move and (self.current_move.short_name or self.current_move.name) or nil,
        motion_name = metadata and metadata.motion_name or nil,
        motion_frame = metadata and tonumber(metadata.current_frame) or nil,
    })
    -- A player action already in progress still belongs in the newly opened
    -- monster round. Allow the next read-only sample to record it once.
    self.last_player_action_semantic_key = nil
    if self.context.safe_mode then
        self.state = M.states.DISABLED
        self.status = "Diagnostic mode: polling and guarded training controls enabled"
    elseif self.context.build_supported == false then
        self.state = M.states.DISABLED
        self.status = string.format("Read-only: unsupported runtime %s / TDB %s", tostring(self.context.game_name), tostring(self.context.tdb_version))
    elseif self.context.is_online then
        self.state = M.states.DISABLED
        self.status = "Disabled: multiplayer quest detected"
    elseif not self.context.in_quest then
        self.state = M.states.WAITING
        self.status = "Enter a single-player quest"
    else
        self.state = M.states.RUNNING
        self.status = "Training round active"
    end

    if self.current_move and self.moves[action] == nil and self.unknown_actions[next_state_key] == nil
        and self.unknown_action_count < self.config.learned_action_limit then
        self.unknown_actions[next_state_key] = true
        self.unknown_action_count = self.unknown_action_count + 1
    end
    bounded_append(self.history, {
        from = previous,
        to = action,
        from_state_key = previous_state_key,
        to_state_key = next_state_key,
        at = event_time,
        previous_duration = duration,
    }, self.config.transition_history_limit)
    return true
end

function M.observe_damage(self, amount)
    if type(amount) == "number" and amount > 0 and self.current_action ~= nil then
        if self.context.outcome_tracking == true then
            self.round_damage = self.round_damage + amount
        end
        local metadata = self.current_metadata or {}
        local frame = tonumber(metadata.current_frame)
        local end_frame = tonumber(metadata.end_frame)
        local progress = tonumber(metadata.motion_progress)
        if progress == nil and frame and end_frame and end_frame > 0 then
            progress = math.max(0, math.min(1, frame / end_frame))
        end
        local key = tostring(self.current_state_key or self.current_action)
        local phase = M.coaching_state(self)
        local relation, relative_frame = nil, nil
        local confirmed = confirmed_evidence_move(self)
        local windows = confirmed and confirmed.timing and confirmed.timing.active_windows or nil
        if frame and type(windows) == "table" then
            local final_end = nil
            for _, window in ipairs(windows) do
                local start_frame = tonumber(window.start_frame)
                local end_frame_value = tonumber(window.end_frame)
                if start_frame and end_frame_value then
                    if frame < start_frame then
                        relation, relative_frame = "before_active", frame - start_frame
                        break
                    elseif frame <= end_frame_value then
                        relation, relative_frame = "inside_active", frame - start_frame
                        break
                    end
                    final_end = final_end and math.max(final_end, end_frame_value) or end_frame_value
                end
            end
            if relation == nil and final_end then
                relation, relative_frame = "after_active", frame - final_end
            end
        end
        self.last_hit_event = {
            action = tostring(self.current_action),
            state_key = key,
            move_name = self.current_move and (self.current_move.short_name or self.current_move.name) or nil,
            damage = amount,
            frame = frame,
            phase = phase.phase,
            relation = relation,
            relative_frame = relative_frame,
        }
        self.training_timeline:record("damage", nil, self.last_hit_event)
        local row = self.hit_timing_evidence[key]
        if row == nil then
            row = {
                action = tostring(self.current_action),
                state_key = key,
                motion_name = metadata.motion_name,
                bank_id = metadata.bank_id,
                motion_id = metadata.motion_id,
                samples = 0,
                total_damage = 0,
            }
            self.hit_timing_evidence[key] = row
        end
        row.samples = row.samples + 1
        row.total_damage = row.total_damage + amount
        if frame then
            row.min_hit_frame = row.min_hit_frame and math.min(row.min_hit_frame, frame) or frame
            row.max_hit_frame = row.max_hit_frame and math.max(row.max_hit_frame, frame) or frame
        end
        if progress then
            row.min_hit_progress = row.min_hit_progress and math.min(row.min_hit_progress, progress) or progress
            row.max_hit_progress = row.max_hit_progress and math.max(row.max_hit_progress, progress) or progress
        end
        return true
    end
    return false
end

function M.reset_round(self, reason)
    self.training_timeline:reset(reason or "Training round reset")
    self.round_damage = 0
    self.last_hit_event = nil
    self.last_result = reason or "Training round reset"
    self.state = self.current_action and M.states.RUNNING or M.states.READY
    self.status = self.last_result
end

function M.clear_round_runtime(self, reason)
    M.finalize_hitbox_observation(self)
    self.training_timeline:reset(reason or "Training round reset")
    self.current_action = nil
    self.current_state_key = nil
    self.current_move = nil
    self.current_metadata = nil
    self.current_hitbox_observation = nil
    self.prediction = nil
    self.response_candidates = {}
    self.response_error = nil
    self.current_player_action_semantic = nil
    self.last_player_action_semantic_key = nil
    self.round_damage = 0
    self.last_hit_event = nil
    self.live_hitbox_seen = false
    self.live_hitbox_state_key = nil
    self.last_result = reason or "Training round reset"
    self.state = M.states.READY
    self.status = self.last_result
end

function M.training_timeline_snapshot(self)
    return self.training_timeline:snapshot()
end

function M.training_timeline_revision(self)
    return self.training_timeline.revision
end

function M.fail(self, message)
    self.state = M.states.ERROR
    self.status = message
end

function M.export_calibration(self, reader)
    local unknown = {}
    for action in pairs(self.unknown_actions) do unknown[#unknown + 1] = action end
    table.sort(unknown)
    return {
        schema_version = 5,
        profile = self.profile.id,
        reader = reader,
        moves = self.moves,
        scenarios = self.calibration_scenarios,
        observed_unknown_actions = unknown,
        observed_transitions = self.transitions,
        observed_history = self.history,
        observed_state_metadata = self.state_metadata,
        observed_hit_timing = self.hit_timing_evidence,
        observed_hitbox_windows = self.hitbox_window_evidence,
        state_changes = self.state_changes,
        outcome_tracking = self.context.outcome_tracking == true,
    }
end

return M
