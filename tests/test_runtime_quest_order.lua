package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local info_logs = 0
log = {
    info = function() info_logs = info_logs + 1 end,
    warn = function() end,
}

local Runtime = require("MHRiseMonsterCoach.runtime")

local managed_list = { values = { 100, 200032001, 999931, 999942 } }
function managed_list:call(method, id)
    if method == "Contains(System.Int32)" then
        for _, value in ipairs(self.values) do
            if value == id then return true end
        end
        return false
    end
    if method == "Remove(System.Int32)" then
        for index, value in ipairs(self.values) do
            if value == id then
                table.remove(self.values, index)
                return true
            end
        end
        return false
    end
    if method == "Add(System.Int32)" then
        self.values[#self.values + 1] = id
        return #self.values - 1
    end
    error("Unexpected method " .. tostring(method))
end

local runtime = setmetatable({
    pending_quest_list = managed_list,
    pending_quest_order_ids = { 200032001 },
    pending_quest_order_attempts = 3,
    pending_quest_order_logged = false,
    quest_order_warned = false,
}, { __index = Runtime })

runtime:flush_quest_list_order()
assert(table.concat(managed_list.values, ",") == "100,999931,999942,200032001", "deferred pass moves training quest last")
assert(runtime.pending_quest_order_attempts == 2, "deferred pass remains active for later UI consumption")
assert(info_logs == 1, "successful move is observable once")

runtime:flush_quest_list_order()
runtime:flush_quest_list_order()
assert(runtime.pending_quest_list == nil, "pending managed list is released after bounded attempts")
assert(runtime.pending_quest_order_ids == nil, "pending quest IDs are released after bounded attempts")
assert(info_logs == 1, "retries do not duplicate success logs")

print("test_runtime_quest_order.lua: PASS")
