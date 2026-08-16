local M = {}

local GLYPH_RANGES = {
    0x0020, 0x00FF,
    0x2000, 0x206F,
    0x3000, 0x30FF,
    0x31F0, 0x31FF,
    0x4E00, 0x9FFF,
    0xFF00, 0xFFEF,
    0,
}

local SAMPLE = "轰龙陪练"

local function vector_component(value, name, index)
    if value == nil then return nil end
    local ok, component = pcall(function() return value[name] end)
    if ok and type(component) == "number" then return component end
    if type(value) == "table" and type(value[index]) == "number" then return value[index] end
    return nil
end

function M.new()
    local self = setmetatable({
        path = "NotoSansSC-Regular.otf",
        size = 19,
        handle = nil,
        ready = false,
        attempted = false,
        error = nil,
        sample_width = nil,
        line_height = 19,
    }, { __index = M })

    self:load()
    return self
end

function M.load(self)
    if self.attempted then return self.ready end
    self.attempted = true

    if type(imgui) ~= "table" or type(imgui.load_font) ~= "function" then
        self.error = "imgui.load_font unavailable"
        return false
    end

    local ok, handle = pcall(imgui.load_font, self.path, self.size, GLYPH_RANGES)
    if not ok or handle == nil then
        self.error = ok and ("font not found: " .. self.path) or tostring(handle)
        return false
    end
    self.handle = handle
    return true
end

function M.validate(self)
    if self.ready then return true end
    if self.handle == nil then return false end
    if type(imgui.push_font) ~= "function" or type(imgui.pop_font) ~= "function"
        or type(imgui.calc_text_size) ~= "function" then
        self.error = "font validation API unavailable"
        return false
    end

    local pushed, push_error = pcall(imgui.push_font, self.handle)
    if not pushed then
        self.error = tostring(push_error)
        return false
    end
    local measured, size_or_error = pcall(imgui.calc_text_size, SAMPLE)
    pcall(imgui.pop_font)
    if not measured then
        self.error = tostring(size_or_error)
        return false
    end

    local width = vector_component(size_or_error, "x", 1)
    local height = vector_component(size_or_error, "y", 2)
    if type(width) ~= "number" or width <= 0 then
        self.error = "Chinese sample measured zero width"
        return false
    end

    self.sample_width = width
    if type(height) == "number" and height > 0 then self.line_height = math.ceil(height) end
    self.ready = true
    self.error = nil
    return true
end

function M.push(self)
    if not self:validate() then return false end
    local ok, error_message = pcall(imgui.push_font, self.handle)
    if not ok then self.ready = false self.error = tostring(error_message) end
    return ok
end

function M.pop(self, pushed)
    if pushed then pcall(imgui.pop_font) end
end

function M.diagnostic(self)
    if self.ready then
        return string.format("CJK font ready: %s (sample %.1f px)", self.path, self.sample_width)
    end
    return "CJK font unavailable: " .. tostring(self.error or "not validated")
end

return M
