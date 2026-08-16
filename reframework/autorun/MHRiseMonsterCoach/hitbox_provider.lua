local M = {}

local SUPPORTED_VERSION = "2.2.0"

local function safe(fn)
    local ok, value = pcall(fn)
    return ok and value or nil
end

function M.new(loader)
    loader = loader or require
    local self = {
        available = false,
        status = "HitboxViewer not detected",
        version = nil,
        cache = nil,
        config = nil,
    }

    local ok_version, version = pcall(loader, "HitboxViewer.config.version")
    if not ok_version or type(version) ~= "table" then
        return setmetatable(self, { __index = M })
    end
    self.version = tostring(version.version or version.commit or "unknown")
    if self.version ~= SUPPORTED_VERSION then
        self.status = "Unsupported HitboxViewer version " .. self.version
        return setmetatable(self, { __index = M })
    end

    local ok_cache, cache = pcall(loader, "HitboxViewer.character.char_cache")
    local ok_config, config = pcall(loader, "HitboxViewer.config.init")
    if not ok_cache or not ok_config or type(cache) ~= "table" or type(config) ~= "table" then
        self.status = "HitboxViewer runtime modules unavailable"
        return setmetatable(self, { __index = M })
    end

    self.cache = cache
    self.config = config
    self.available = true
    self.status = "HitboxViewer 2.2.0 shared runtime ready"
    return setmetatable(self, { __index = M })
end

function M.poll(self, enemy)
    if not self.available then return nil, self.status end
    local enabled = safe(function()
        return self.config.current.mod.enabled_hitboxes == true
    end)
    if not enabled then
        self.status = "Enable Draw Hitboxes in HitboxViewer"
        return nil, self.status
    end
    if enemy == nil then return nil, "Target monster unavailable" end

    local game_object = safe(function() return enemy:call("get_GameObject") end)
        or safe(function() return enemy:get_GameObject() end)
    if game_object == nil then return nil, "Target GameObject unavailable" end
    local character = self.cache.by_gameobject and self.cache.by_gameobject[game_object] or nil
    if character == nil or type(character.hitboxes) ~= "table" then
        self.status = "Waiting for HitboxViewer monster cache"
        return nil, self.status
    end

    local active_count, known_count = 0, 0
    local entries = {}
    for _, box in pairs(character.hitboxes) do
        known_count = known_count + 1
        if box.is_enabled == true then
            active_count = active_count + 1
            local log_entry = box.log_entry or {}
            entries[#entries + 1] = {
                resource_path = log_entry.resource_path,
                resource_idx = box.resource_idx or log_entry.resource_idx,
                set_idx = box.set_idx or log_entry.set_idx,
                collidable_idx = box.collidable_idx or log_entry.collidable_idx,
                attack_id = log_entry.attack_id,
            }
        end
    end
    self.status = "HitboxViewer runtime active"
    return {
        active = active_count > 0,
        active_count = active_count,
        known_count = known_count,
        entries = entries,
        source = "hitboxviewer_shared_runtime",
        version = self.version,
    }
end

function M.description(self)
    return { available = self.available, version = self.version, status = self.status }
end

return M
