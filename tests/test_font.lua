package.path = "reframework/autorun/?.lua;reframework/autorun/?/init.lua;" .. package.path

local pushed = 0
imgui = {
    load_font = function(path, size, ranges)
        assert(path == "NotoSansSC-Regular.otf")
        assert(size == 19 and ranges[#ranges] == 0)
        return { path = path }
    end,
    push_font = function(font) assert(font.path) pushed = pushed + 1 end,
    pop_font = function() pushed = pushed - 1 end,
    calc_text_size = function(text) assert(text == "轰龙陪练") return { x = 76, y = 20 } end,
}

local Font = require("MHRiseMonsterCoach.font")
local font = Font.new()
assert(font:push(), "validated Chinese font can be pushed")
assert(font.ready and font.sample_width == 76 and font.line_height == 20)
font:pop(true)
assert(pushed == 0, "font stack remains balanced")
assert(string.find(font:diagnostic(), "CJK font ready", 1, true))

print("test_font.lua: PASS")
