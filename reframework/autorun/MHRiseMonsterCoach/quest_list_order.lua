local M = {}

-- Contract: preserve every non-training quest's relative order, then append the
-- registered training quest IDs in registration order.
function M.move_registered_to_end(list, quest_ids)
    if list == nil then return 0, "Quest list unavailable" end
    if type(quest_ids) ~= "table" then return 0, "Training quest IDs unavailable" end

    local moved = 0
    for _, quest_id in ipairs(quest_ids) do
        if list:contains(quest_id) then
            if not list:remove(quest_id) then
                return moved, "Failed to remove training Quest ID " .. tostring(quest_id)
            end
            list:add(quest_id)
            moved = moved + 1
        end
    end
    return moved
end

return M
