package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local QuestListOrder = require("MHRiseMonsterCoach.quest_list_order")

local function fake_list(values)
    local list = { values = values }
    function list:contains(id)
        for _, value in ipairs(self.values) do
            if value == id then return true end
        end
        return false
    end
    function list:remove(id)
        for index, value in ipairs(self.values) do
            if value == id then
                table.remove(self.values, index)
                return true
            end
        end
        return false
    end
    function list:add(id) self.values[#self.values + 1] = id end
    return list
end

local list = fake_list({ 100, 200032001, 999931, 999942 })
local moved, order_error = QuestListOrder.move_registered_to_end(list, { 200032001 })
assert(order_error == nil and moved == 1, "moves the registered training quest")
assert(table.concat(list.values, ",") == "100,999931,999942,200032001", "preserves other custom quest order")

local multiple = fake_list({ 10, 300, 20, 200 })
moved, order_error = QuestListOrder.move_registered_to_end(multiple, { 200, 300 })
assert(order_error == nil and moved == 2, "moves every registered training quest")
assert(table.concat(multiple.values, ",") == "10,20,200,300", "uses registration order for the training block")

local absent = fake_list({ 1, 2, 3 })
moved, order_error = QuestListOrder.move_registered_to_end(absent, { 9 })
assert(order_error == nil and moved == 0, "missing training quests are a no-op")
assert(table.concat(absent.values, ",") == "1,2,3", "no-op preserves the list")

print("test_quest_list_order.lua: PASS")
