local M = {}

local function depth(name)
    local _, count = tostring(name or ""):gsub("%.", "")
    return count + 1
end

local function select_primary(snapshot)
    local preferred, fallback = nil, nil
    for _, layer in ipairs(snapshot and snapshot.layers or {}) do
        for _, node in ipairs(layer.active_nodes or {}) do
            if node.name and node.name ~= "root" then
                local candidate = {
                    layer = layer.layer,
                    id = node.id,
                    index = node.index,
                    name = node.name,
                    status1 = node.status1,
                    status2 = node.status2,
                }
                if tonumber(node.status1) == 2
                    and (preferred == nil or depth(candidate.name) > depth(preferred.name)) then
                    preferred = candidate
                end
                if tonumber(node.status2) == 2
                    and (fallback == nil or depth(candidate.name) > depth(fallback.name)) then
                    fallback = candidate
                end
            end
        end
    end
    return preferred or fallback
end

function M.new(max_events)
    return setmetatable({
        max_events = tonumber(max_events) or 128,
        events = {},
        last_signature = nil,
        samples = 0,
        truncated = false,
    }, { __index = M })
end

function M:sample(frame, snapshot, action)
    self.samples = self.samples + 1
    local node = select_primary(snapshot)
    if node == nil then return false end
    local signature = tostring(node.layer) .. ":" .. tostring(node.id) .. ":"
        .. tostring(action and action.category) .. ":" .. tostring(action and action.action)
    if signature == self.last_signature then return false end
    self.last_signature = signature
    if #self.events >= self.max_events then
        self.truncated = true
        return false
    end
    self.events[#self.events + 1] = {
        frame = frame,
        node = node,
        action = action and {
            category = action.category,
            action = action.action,
            motion_name = action.motion_name,
        } or nil,
    }
    return true
end

function M:result()
    return {
        policy = "read_only_primary_fsm_node_transitions",
        samples = self.samples,
        truncated = self.truncated,
        events = self.events,
    }
end

return M
