local Native = require("MHRiseMonsterCoach.hitbox_provider_native")
local HitboxViewer = require("MHRiseMonsterCoach.hitbox_provider_hitboxviewer")

local M = {}

function M.new(options)
    options = options or {}
    local self = setmetatable({
        native = Native.new(options.sdk),
        validator = HitboxViewer.new(options.loader),
        last_validation = nil,
    }, { __index = M })
    if options.enabled ~= false then self.native:install()
    else self.native.status = options.disabled_reason or "Native hitbox hook disabled" end
    return self
end

function M.poll(self, enemy)
    local native_sample, native_error = self.native:poll(enemy)
    local validation_sample = self.validator:poll(enemy)
    if native_sample and validation_sample then
        self.last_validation = {
            matches = native_sample.active == validation_sample.active,
            native_active_count = native_sample.active_count,
            validator_active_count = validation_sample.active_count,
        }
    end
    if native_sample then return native_sample end
    if validation_sample then return validation_sample end
    return nil, native_error
end

function M.description(self)
    local primary = self.native:description()
    local validator = self.validator:description()
    return {
        available = primary.available or validator.available,
        status = primary.status,
        primary = primary,
        validator = validator,
        validation = self.last_validation,
    }
end

return M
