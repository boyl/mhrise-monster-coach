local M = {}

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

function M.new(profile, calibration, config)
    local moves, scenarios = merge_profile(profile, calibration)
    return setmetatable({
        state = M.states.INITIAL,
        status = "Waiting for a single-player quest",
        profile = profile,
        moves = moves,
        scenarios = scenarios,
        current_action = nil,
        current_move = nil,
        action_started_at = 0,
        prediction = nil,
        transitions = {},
        history = {},
        unknown_actions = {},
        unknown_action_count = 0,
        learned_actions = 0,
        rounds = 0,
        successes = 0,
        failures = 0,
        streak = 0,
        round_damage = 0,
        last_result = nil,
        config = config,
        context = { in_quest = false, is_online = false, target_found = false },
    }, { __index = M })
end

function M.set_context(self, context)
    local was_in_quest = self.context.in_quest
    if was_in_quest and not context.in_quest then
        self.current_action = nil
        self.current_move = nil
        self.prediction = nil
        self.round_damage = 0
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

local function named_move(self, action)
    local key = tostring(action)
    local move = self.moves[key]
    if move then return move end
    return {
        name = "Uncatalogued action " .. key,
        short_name = "Action " .. key,
        advice = "Observe the tell; add a name and advice in tigrex_calibration.json.",
        certainty = "unknown",
    }
end

local function learned_prediction(self, action)
    local row = self.transitions[tostring(action)]
    if not row or row.total < self.config.min_prediction_samples then return nil end

    local candidates = {}
    for next_action, count in pairs(row.next) do
        candidates[#candidates + 1] = {
            action = next_action,
            name = named_move(self, next_action).short_name,
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

function M.observe_action(self, action, now)
    if action == nil then return false end
    action = tostring(action)
    if action == self.current_action then return false end

    local previous = self.current_action
    if previous ~= nil then
        M.finish_round(self)
        record_transition(self, previous, action)
    end

    self.current_action = action
    self.current_move = named_move(self, action)
    self.action_started_at = now or 0
    self.prediction = profile_prediction(self, self.current_move) or learned_prediction(self, action)
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

    if self.moves[action] == nil and self.unknown_actions[action] == nil
        and self.unknown_action_count < self.config.learned_action_limit then
        self.unknown_actions[action] = true
        self.unknown_action_count = self.unknown_action_count + 1
    end
    bounded_append(self.history, { from = previous, to = action, at = now or 0 }, self.config.transition_history_limit)
    return true
end

function M.observe_damage(self, amount)
    if type(amount) == "number" and amount > 0 and self.current_action ~= nil then
        self.round_damage = self.round_damage + amount
    end
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
        schema_version = 1,
        profile = self.profile.id,
        reader = reader,
        moves = self.moves,
        scenarios = self.scenarios,
        observed_unknown_actions = unknown,
        observed_transitions = self.transitions,
    }
end

return M
