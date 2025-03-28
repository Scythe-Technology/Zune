--!strict
local testing = zune.testing;

local test = testing.test;
local expect = testing.expect;

local ansi = require("@std/ansi");

test("Cursor", function()
    expect(ansi.cursorMove("home")).toBe("\27[H");
    expect(ansi.cursorMove("goto", 0, 0)).toBe("\27[0;0H");
    expect(ansi.cursorMove("up", 0)).toBe("\27[0A");
    expect(ansi.cursorMove("down", 0)).toBe("\27[0B");
    expect(ansi.cursorMove("right", 0)).toBe("\27[0C");
    expect(ansi.cursorMove("left", 0)).toBe("\27[0D");
    expect(ansi.cursorMove("nextline", 0)).toBe("\27[0E");
    expect(ansi.cursorMove("prevline", 0)).toBe("\27[0F");
    expect(ansi.cursorMove("gotocol", 0)).toBe("\27[0G");
end)
test("Erase", function()
    expect(ansi.erase("endOf")).toBe("\27[0J");
    expect(ansi.erase("startOf")).toBe("\27[1J");
    expect(ansi.erase("entire")).toBe("\27[2J");
    expect(ansi.erase("savedLines")).toBe("\27[3J");
    expect(ansi.erase("endOfLine")).toBe("\27[0K");
    expect(ansi.erase("startOfLine")).toBe("\27[1K");
    expect(ansi.erase("entireLine")).toBe("\27[2K");
end)
test("Style", function()
    expect(ansi.bold).toBe("\27[1m");
    expect(ansi.dim).toBe("\27[2m");
    expect(ansi.italic).toBe("\27[3m");
    expect(ansi.underline).toBe("\27[4m");
    expect(ansi.blink).toBe("\27[5m");
    expect(ansi.inverse).toBe("\27[7m");
    expect(ansi.hidden).toBe("\27[8m");
    expect(ansi.strikethrough).toBe("\27[9m");
end)
test("Reset", function()
    expect(ansi.reset).toBe("\27[0m");
    expect(ansi.reset_bold).toBe("\27[22m");
    expect(ansi.reset_dim).toBe("\27[22m");
    expect(ansi.reset_italic).toBe("\27[23m");
    expect(ansi.reset_underline).toBe("\27[24m");
    expect(ansi.reset_blink).toBe("\27[25m");
    expect(ansi.reset_inverse).toBe("\27[27m");
    expect(ansi.reset_hidden).toBe("\27[28m");
    expect(ansi.reset_strikethrough).toBe("\27[29m");
    expect(ansi.reset_color).toBe("\27[39m");
end)
test("Color", function()
    expect(ansi.black).toBe("\27[30m");
    expect(ansi.red).toBe("\27[31m");
    expect(ansi.green).toBe("\27[32m");
    expect(ansi.yellow).toBe("\27[33m");
    expect(ansi.blue).toBe("\27[34m");
    expect(ansi.magenta).toBe("\27[35m");
    expect(ansi.cyan).toBe("\27[36m");
    expect(ansi.white).toBe("\27[37m");
    expect(ansi.bright_black).toBe("\27[90m");
    expect(ansi.bright_red).toBe("\27[91m");
    expect(ansi.bright_green).toBe("\27[92m");
    expect(ansi.bright_yellow).toBe("\27[93m");
    expect(ansi.bright_blue).toBe("\27[94m");
    expect(ansi.bright_magenta).toBe("\27[95m");
    expect(ansi.bright_cyan).toBe("\27[96m");
    expect(ansi.bright_white).toBe("\27[97m");
end)
test("Background Color", function()
    expect(ansi.bg.black).toBe("\27[40m");
    expect(ansi.bg.red).toBe("\27[41m");
    expect(ansi.bg.green).toBe("\27[42m");
    expect(ansi.bg.yellow).toBe("\27[43m");
    expect(ansi.bg.blue).toBe("\27[44m");
    expect(ansi.bg.magenta).toBe("\27[45m");
    expect(ansi.bg.cyan).toBe("\27[46m");
    expect(ansi.bg.white).toBe("\27[47m");
    expect(ansi.bg.bright_black).toBe("\27[100m");
    expect(ansi.bg.bright_red).toBe("\27[101m");
    expect(ansi.bg.bright_green).toBe("\27[102m");
    expect(ansi.bg.bright_yellow).toBe("\27[103m");
    expect(ansi.bg.bright_blue).toBe("\27[104m");
    expect(ansi.bg.bright_magenta).toBe("\27[105m");
    expect(ansi.bg.bright_cyan).toBe("\27[106m");
    expect(ansi.bg.bright_white).toBe("\27[107m");
end)
test("Color 256", function()
    for i = 0, 255 do
        expect(ansi.color256(i)).toBe("\27[38;5;" .. i .. "m");
    end
end)
test("Background Color 256", function()
    for i = 0, 255 do
        expect(ansi.bg.color256(i)).toBe("\27[48;5;" .. i .. "m");
    end
end)
test("True Color", function()
    for r = 0, 255 do
        local g = (r + 64) % 255;
        local b = (r + 128) % 255;
        expect(ansi.trueColor(r, g, b)).toBe("\27[38;2;" .. r .. ";" .. g .. ";" .. b .. "m");
    end
end)
test("Background True Color", function()
    for r = 0, 255 do
        local g = (r + 64) % 255;
        local b = (r + 128) % 255;
        expect(ansi.bg.trueColor(r, g, b)).toBe("\27[48;2;" .. r .. ";" .. g .. ";" .. b .. "m");
    end
end)

return nil;
