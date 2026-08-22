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
        previous = nil,
    }, { __index = M })
end

function M:sample(frame, snapshot, action)
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
    }
end

return M
