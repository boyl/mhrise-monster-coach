local M = {}
local LongSwordResponse = require("MHRiseMonsterCoach.response_long_sword")
local MonsterPhase = require("MHRiseMonsterCoach.monster_phase")

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

local function merge_profile(profile, calibration)
    local moves = {}
    for key, value in pairs(profile.moves or {}) do moves[tostring(key)] = value end
    for key, value in pairs(calibration.moves or {}) do moves[tostring(key)] = value end

    local scenarios = {}
    for _, value in ipairs(profile.scenarios or {}) do scenarios[#scenarios + 1] = value end
    for _, value in ipairs(calibration.scenarios or {}) do scenarios[#scenarios + 1] = value end
    return moves, scenarios
end

function M.new(profile, calibration, config, static_ai, long_sword_knowledge)
    local moves, scenarios = merge_profile(profile, calibration)
    return setmetatable({
        state = M.states.INITIAL,
        status = "Waiting for a single-player quest",
        profile = profile,
        moves = moves,
        scenarios = scenarios,
        static_ai = static_ai or { actions = {} },
        long_sword_knowledge = long_sword_knowledge or { actions = {} },
        player_combat_state = nil,
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
        hit_timing_evidence = {},
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
        config = config,
        context = { in_quest = false, is_online = false, target_found = false },
    }, { __index = M })
end

local function monster_phase(self)
    return MonsterPhase.resolve(self.current_move, self.current_metadata)
end

function M.update_player_combat_state(self, state)
    self.player_combat_state = state
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
    if sample.active == true then self.live_hitbox_seen = true end
    self.current_metadata = self.current_metadata or {}
    self.current_metadata.runtime_hitbox_phase = sample.active == true and "active"
        or (self.live_hitbox_seen and "recovery" or "startup")
    self.current_metadata.runtime_hitbox_count = tonumber(sample.active_count) or 0
    self.current_metadata.runtime_hitbox_source = sample.source
    self.current_metadata.runtime_hitbox_entries = sample.entries
    return true
end

function M.set_context(self, context)
    local was_in_quest = self.context.in_quest
    if was_in_quest and not context.in_quest then
        self.current_action = nil
        self.current_state_key = nil
        self.current_move = nil
        self.current_metadata = nil
        self.prediction = nil
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
        self.status = "Read-only mode: Action polling enabled; gameplay writes disabled"
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
    if static_move then return static_move end
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
    local kind = move.next_kind or "conditional"
    if kind == "fixed" and #candidates ~= 1 then kind = "conditional" end
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
    local kind = row.kind == "fixed" and #candidates == 1 and "fixed" or "conditional"
    return {
        kind = kind,
        source = "static_ai",
        evidence_count = row.evidence_count,
        candidates = candidates,
    }
end

function M.reload_static_ai(self, static_ai)
    if type(static_ai) ~= "table" or type(static_ai.actions) ~= "table" then return false end
    self.static_ai = static_ai
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

function M.finish_round(self)
    if self.current_action == nil then return end
    self.rounds = self.rounds + 1
    if self.round_damage > 0 then
        self.failures = self.failures + 1
        self.streak = 0
        self.state = M.states.FAILURE
        self.last_result = string.format("Hit taken: %.1f damage", self.round_damage)
    else
        self.successes = self.successes + 1
        self.streak = self.streak + 1
        self.state = M.states.SUCCESS
        self.last_result = "No damage during the action"
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
        if self.context.outcome_tracking == true then
            M.finish_round(self)
        else
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
    if self.context.safe_mode then
        self.state = M.states.DISABLED
        self.status = "Read-only mode: Action polling enabled; gameplay writes disabled"
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
    self.round_damage = 0
    self.last_result = reason or "Training round reset"
    self.state = self.current_action and M.states.RUNNING or M.states.READY
    self.status = self.last_result
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
        schema_version = 4,
        profile = self.profile.id,
        reader = reader,
        moves = self.moves,
        scenarios = self.scenarios,
        observed_unknown_actions = unknown,
        observed_transitions = self.transitions,
        observed_history = self.history,
        observed_state_metadata = self.state_metadata,
        observed_hit_timing = self.hit_timing_evidence,
        state_changes = self.state_changes,
        outcome_tracking = self.context.outcome_tracking == true,
    }
end

return M
