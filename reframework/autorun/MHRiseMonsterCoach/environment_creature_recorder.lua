local M = {}

function M.new(limit)
    return setmetatable({
        limit = tonumber(limit) or 256,
        revision = 0,
        samples = 0,
        previous = {},
        events = {},
        observed_types = {},
    }, { __index = M })
end

local function same_values(left, right)
    for key, value in pairs(left or {}) do
        if right == nil or right[key] ~= value then return false end
    end
    for key, value in pairs(right or {}) do
        if left == nil or left[key] ~= value then return false end
    end
    return true
end

local function append_event(self, event)
    self.events[#self.events + 1] = event
    while #self.events > self.limit do table.remove(self.events, 1) end
    self.revision = self.revision + 1
end

function M:observe(entries, context)
    local current = {}
    self.samples = self.samples + 1
    for _, entry in ipairs(entries or {}) do
        if entry.key then
            current[entry.key] = entry
            if entry.type_name then self.observed_types[entry.type_name] = true end
            local previous = self.previous[entry.key]
            if previous == nil then
                append_event(self, { kind = "appeared", entry = entry, context = context })
            elseif previous.type_name ~= entry.type_name
                or not same_values(previous.values, entry.values) then
                append_event(self, {
                    kind = "changed",
                    before = previous,
                    entry = entry,
                    context = context,
                })
            end
        end
    end
    for key, previous in pairs(self.previous) do
        if current[key] == nil then
            append_event(self, { kind = "disappeared", entry = previous, context = context })
        end
    end
    self.previous = current
    return self.revision
end

function M:reset_current()
    self.previous = {}
end

function M:export()
    local types = {}
    for name in pairs(self.observed_types) do types[#types + 1] = name end
    table.sort(types)
    local current = {}
    for _, entry in pairs(self.previous) do current[#current + 1] = entry end
    table.sort(current, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return {
        schema_version = 1,
        policy = "read_only_scene_component_and_primitive_field_sampling",
        revision = self.revision,
        samples = self.samples,
        observed_types = types,
        current = current,
        events = self.events,
    }
end

return M
