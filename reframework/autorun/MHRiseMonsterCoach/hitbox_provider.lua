local Native = require("MHRiseMonsterCoach.hitbox_provider_native")
local HitboxViewer = require("MHRiseMonsterCoach.hitbox_provider_hitboxviewer")

local M = {}

function M.new(options)
    options = options or {}
    local self = setmetatable({
        native = Native.new(options.sdk),
        validator = HitboxViewer.new(options.loader),
        last_validation = nil,
        validation_stats = { samples = 0, mismatches = 0, matched_active = 0,
            max_native = 0, max_validator = 0 },
    }, { __index = M })
    if options.enabled ~= false then self.native:install()
    else self.native.status = options.disabled_reason or "Native hitbox hook disabled" end
    return self
end

function M.poll(self, enemy)
    local native_sample, native_error = self.native:poll(enemy)
    local validation_sample = self.validator:poll(enemy)
    if native_sample and validation_sample then
        local matches = native_sample.active == validation_sample.active
        self.last_validation = {
            matches = matches,
            native_active_count = native_sample.active_count,
            validator_active_count = validation_sample.active_count,
        }
        local stats = self.validation_stats
        stats.samples = stats.samples + 1
        if not matches then stats.mismatches = stats.mismatches + 1 end
        if matches and native_sample.active then stats.matched_active = stats.matched_active + 1 end
        stats.max_native = math.max(stats.max_native, native_sample.active_count or 0)
        stats.max_validator = math.max(stats.max_validator, validation_sample.active_count or 0)
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
        validation_stats = self.validation_stats,
    }
end

function M.set_debug_shapes(self, enabled)
    return self.validator:set_debug_shapes(enabled)
end

return M
