local M = {}
local INITIALIZE_SIGNATURE = "initialize(System.Single, System.Single, System.UInt32, System.UInt32, System.Int32, snow.hit.userdata.BaseHitAttackRSData)"
local MAX_PENDING, MAX_COLLIDABLE_INDEX = 256, 64
local function safe(fn) local ok, value = pcall(fn) return ok and value or nil end
local function address(value) return value and safe(function() return value:get_address() end) or nil end

function M.new(api)
    return setmetatable({ api = api or sdk, available = false, installed = false,
        status = "Native hitbox hook not installed", pending = {}, collidables = {},
        target_address = nil }, { __index = M })
end

function M.install(self)
    if self.installed then return true end
    local type_def = safe(function() return self.api.find_type_definition("snow.hit.AttackWork") end)
    local method = type_def and safe(function() return type_def:get_method(INITIALIZE_SIGNATURE) end) or nil
    if method == nil then self.status = "AttackWork.initialize signature unavailable" return false, self.status end
    local ok, err = pcall(function()
        self.api.hook(method, function(args)
            local attack_work = safe(function() return self.api.to_managed_object(args[2]) end)
            local resource_idx = safe(function() return self.api.to_int64(args[5]) end)
                or safe(function() return self.api.to_int(args[5]) end)
            local set_idx = safe(function() return self.api.to_int64(args[6]) end)
                or safe(function() return self.api.to_int(args[6]) end)
            if attack_work == nil or resource_idx == nil or set_idx == nil then return end
            local rsc = safe(function() return attack_work:call("get_RSCCtrl") end)
                or safe(function() return attack_work:get_RSCCtrl() end)
            local game_object = rsc and (safe(function() return rsc:call("get_GameObject") end)
                or safe(function() return rsc:get_GameObject() end)) or nil
            if rsc == nil or game_object == nil then return end
            self.pending[#self.pending + 1] = { rsc = rsc, game_object_address = address(game_object),
                resource_idx = tonumber(resource_idx), set_idx = tonumber(set_idx) }
            if #self.pending > MAX_PENDING then table.remove(self.pending, 1) end
        end, function(retval) return retval end)
    end)
    if not ok then self.status = "Native hitbox hook failed: " .. tostring(err) return false, self.status end
    self.available, self.installed, self.status = true, true, "Monster Coach native hitbox hook ready"
    return true
end

local function resource_path(rsc, resource_idx)
    return safe(function()
        local data = rsc:call("get_RSC")
        local group = data:call("getRequestSetGroups(System.UInt32)", resource_idx)
        return group:call("get_Resource"):call("get_ResourcePath")
    end)
end

function M.consume_pending(self, target_address)
    local remaining = {}
    for _, request in ipairs(self.pending) do
        if request.game_object_address == target_address then
            local count = safe(function() return request.rsc:call(
                "getNumCollidables(System.UInt32, System.UInt32)", request.resource_idx, request.set_idx) end)
                or safe(function() return request.rsc:getNumCollidables(request.resource_idx, request.set_idx) end)
            count = math.min(tonumber(count) or -1, MAX_COLLIDABLE_INDEX)
            for index = 0, count do
                local collidable = safe(function() return request.rsc:call(
                    "getCollidable(System.UInt32, System.UInt32, System.UInt32)",
                    request.resource_idx, request.set_idx, index) end)
                    or safe(function() return request.rsc:getCollidable(request.resource_idx, request.set_idx, index) end)
                local key = address(collidable)
                if key then self.collidables[key] = { collidable = collidable,
                    resource_path = resource_path(request.rsc, request.resource_idx),
                    resource_idx = request.resource_idx, set_idx = request.set_idx, collidable_idx = index } end
            end
        else remaining[#remaining + 1] = request end
    end
    self.pending = remaining
end

function M.poll(self, enemy)
    if not self.available then return nil, self.status end
    if enemy == nil then self.collidables = {} return nil, "Target monster unavailable" end
    local game_object = safe(function() return enemy:call("get_GameObject") end)
        or safe(function() return enemy:get_GameObject() end)
    local target_address = address(game_object)
    if target_address == nil then return nil, "Target GameObject unavailable" end
    if self.target_address ~= target_address then
        self.target_address = target_address
        self.collidables = {}
    end
    self:consume_pending(target_address)
    local active_count, known_count, entries = 0, 0, {}
    for key, item in pairs(self.collidables) do
        local refs = safe(function() return item.collidable:get_reference_count() end)
        if refs ~= nil and refs <= 1 then self.collidables[key] = nil else
            known_count = known_count + 1
            if safe(function() return item.collidable:read_byte(0x10) ~= 0 end) == true then
                active_count = active_count + 1
                entries[#entries + 1] = { resource_path = item.resource_path,
                    resource_idx = item.resource_idx, set_idx = item.set_idx,
                    collidable_idx = item.collidable_idx, collidable_address = key }
            end
        end
    end
    self.status = known_count > 0 and "Monster Coach native hitbox reader active"
        or "Native hook ready; waiting for monster attack data"
    return { active = active_count > 0, active_count = active_count, known_count = known_count,
        entries = entries, source = "monster_coach_native", version = 1 }
end

function M.description(self)
    return { available = self.available, installed = self.installed, status = self.status }
end
return M
