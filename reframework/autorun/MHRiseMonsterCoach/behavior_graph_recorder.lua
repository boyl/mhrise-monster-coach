local BehaviorPathTracker = require("MHRiseMonsterCoach.behavior_path_tracker")

local M = {}

local function node_key(node)
    return tostring(node.layer) .. ":" .. tostring(node.id)
end

function M.new(max_events)
    return setmetatable({
        tracker = BehaviorPathTracker.new(max_events or 512),
        nodes = {},
        edges = {},
        think_catalogs = {},
        previous = nil,
    }, { __index = M })
end

function M:sample(frame, snapshot, action, think)
    if think and think.info_address and think.states then
        self.think_catalogs[tostring(think.info_address)] = {
            info_address = think.info_address,
            state_count = think.state_count,
            states = think.states,
        }
    end
    if not self.tracker:sample(frame, snapshot, action) then return false end
    local event = self.tracker.events[#self.tracker.events]
    local key = node_key(event.node)
    local row = self.nodes[key] or {
        key = key, layer = event.node.layer, id = event.node.id,
        name = event.node.name, observations = 0, action_contexts = {},
    }
    row.observations = row.observations + 1
    local action_key = tostring(event.action and event.action.category) .. ":"
        .. tostring(event.action and event.action.action)
    row.action_contexts[action_key] = (row.action_contexts[action_key] or 0) + 1
    row.think_contexts = row.think_contexts or {}
    local think_key = tostring(think and think.info_address) .. ":"
        .. tostring(think and think.current_state_no) .. ":"
        .. tostring(think and think.current_state and think.current_state.tree_node_id)
    row.think_contexts[think_key] = (row.think_contexts[think_key] or 0) + 1
    self.nodes[key] = row
    if self.previous ~= nil and self.previous.key ~= key then
        local edge_key = self.previous.key .. ">" .. key
        local edge = self.edges[edge_key] or {
            from = self.previous.key, to = key, observations = 0,
            first_frame = frame, last_frame = frame,
        }
        edge.observations = edge.observations + 1
        edge.last_frame = frame
        self.edges[edge_key] = edge
    end
    self.previous = { key = key }
    return true
end

local function values_sorted(rows, field)
    local result = {}
    for _, row in pairs(rows) do result[#result + 1] = row end
    table.sort(result, function(left, right) return tostring(left[field]) < tostring(right[field]) end)
    return result
end

function M:result()
    local path = self.tracker:result()
    return {
        schema_version = 1,
        policy = "observed_candidates_only_not_deterministic",
        samples = path.samples,
        events = path.events,
        truncated = path.truncated,
        nodes = values_sorted(self.nodes, "key"),
        edges = values_sorted(self.edges, "from"),
        think_catalogs = values_sorted(self.think_catalogs, "info_address"),
    }
end

return M
