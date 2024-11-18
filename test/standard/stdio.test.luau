--!strict
local stdio = zune.stdio;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Test", function()
    test("Cursor", function()
        expect(stdio.cursorMove("home", 0)).toBe("\27[H");
        expect(stdio.cursorMove("goto", 0, 0)).toBe("\27[0;0H");
        expect(stdio.cursorMove("up", 0)).toBe("\27[0A");
        expect(stdio.cursorMove("down", 0)).toBe("\27[0B");
        expect(stdio.cursorMove("right", 0)).toBe("\27[0C");
        expect(stdio.cursorMove("left", 0)).toBe("\27[0D");
        expect(stdio.cursorMove("nextline", 0)).toBe("\27[0E");
        expect(stdio.cursorMove("prevline", 0)).toBe("\27[0F");
        expect(stdio.cursorMove("gotocol", 0)).toBe("\27[0G");
    end)
    test("Erase", function()
        expect(stdio.erase("endOf")).toBe("\27[0J");
        expect(stdio.erase("startOf")).toBe("\27[1J");
        expect(stdio.erase("entire")).toBe("\27[2J");
        expect(stdio.erase("savedLines")).toBe("\27[3J");
        expect(stdio.erase("endOfLine")).toBe("\27[0K");
        expect(stdio.erase("startOfLine")).toBe("\27[1K");
        expect(stdio.erase("entireLine")).toBe("\27[2K");
    end)
    test("Style", function()
        expect(stdio.style("bold")).toBe("\27[1m");
        expect(stdio.style("dim")).toBe("\27[2m");
        expect(stdio.style("italic")).toBe("\27[3m");
        expect(stdio.style("underline")).toBe("\27[4m");
        expect(stdio.style("blinking")).toBe("\27[5m");
        expect(stdio.style("inverse")).toBe("\27[7m");
        expect(stdio.style("hidden")).toBe("\27[8m");
        expect(stdio.style("strikethrough")).toBe("\27[9m");
    end)
    test("Reset", function()
        expect(stdio.reset()).toBe("\27[0m");
        expect(stdio.reset("weight")).toBe("\27[22m");
        expect(stdio.reset("italic")).toBe("\27[23m");
        expect(stdio.reset("underline")).toBe("\27[24m");
        expect(stdio.reset("blinking")).toBe("\27[25m");
        expect(stdio.reset("inverse")).toBe("\27[27m");
        expect(stdio.reset("hidden")).toBe("\27[28m");
        expect(stdio.reset("strikethrough")).toBe("\27[29m");
        expect(stdio.reset("color")).toBe("\27[39m");
    end)
    test("Color", function()
        expect(stdio.color("black")).toBe("\27[30m");
        expect(stdio.color("red")).toBe("\27[31m");
        expect(stdio.color("green")).toBe("\27[32m");
        expect(stdio.color("yellow")).toBe("\27[33m");
        expect(stdio.color("blue")).toBe("\27[34m");
        expect(stdio.color("magenta")).toBe("\27[35m");
        expect(stdio.color("cyan")).toBe("\27[36m");
        expect(stdio.color("white")).toBe("\27[37m");
        expect(stdio.color("bblack")).toBe("\27[90m");
        expect(stdio.color("bred")).toBe("\27[91m");
        expect(stdio.color("bgreen")).toBe("\27[92m");
        expect(stdio.color("byellow")).toBe("\27[93m");
        expect(stdio.color("bblue")).toBe("\27[94m");
        expect(stdio.color("bmagenta")).toBe("\27[95m");
        expect(stdio.color("bcyan")).toBe("\27[96m");
        expect(stdio.color("bwhite")).toBe("\27[97m");
    end)
    test("Background Color", function()
        expect(stdio.bgcolor("black")).toBe("\27[40m");
        expect(stdio.bgcolor("red")).toBe("\27[41m");
        expect(stdio.bgcolor("green")).toBe("\27[42m");
        expect(stdio.bgcolor("yellow")).toBe("\27[43m");
        expect(stdio.bgcolor("blue")).toBe("\27[44m");
        expect(stdio.bgcolor("magenta")).toBe("\27[45m");
        expect(stdio.bgcolor("cyan")).toBe("\27[46m");
        expect(stdio.bgcolor("white")).toBe("\27[47m");
        expect(stdio.bgcolor("bblack")).toBe("\27[100m");
        expect(stdio.bgcolor("bred")).toBe("\27[101m");
        expect(stdio.bgcolor("bgreen")).toBe("\27[102m");
        expect(stdio.bgcolor("byellow")).toBe("\27[103m");
        expect(stdio.bgcolor("bblue")).toBe("\27[104m");
        expect(stdio.bgcolor("bmagenta")).toBe("\27[105m");
        expect(stdio.bgcolor("bcyan")).toBe("\27[106m");
        expect(stdio.bgcolor("bwhite")).toBe("\27[107m");
    end)
    test("Color 256", function()
        for i = 0, 255 do
            expect(stdio.color256(i)).toBe("\27[38;5;" .. i .. "m");
        end
    end)
    test("Background Color 256", function()
        for i = 0, 255 do
            expect(stdio.bgcolor256(i)).toBe("\27[48;5;" .. i .. "m");
        end
    end)
    test("True Color", function()
        for r = 0, 255 do
            local g = (r + 64) % 255;
            local b = (r + 128) % 255;
            expect(stdio.trueColor(r, g, b)).toBe("\27[38;2;" .. r .. ";" .. g .. ";" .. b .. "m");
        end
    end)
    test("Background True Color", function()
        for r = 0, 255 do
            local g = (r + 64) % 255;
            local b = (r + 128) % 255;
            expect(stdio.bgtrueColor(r, g, b)).toBe("\27[48;2;" .. r .. ";" .. g .. ";" .. b .. "m");
        end
    end)
    test("Format", function()
        expect(stdio.format("test")).toBe("test");
        expect(stdio.format(123)).toBe("\x1B[96m123\x1B[0m");
        local res : string = stdio.format({[" "] = 1});
        expect(res:sub(28)).toBe(" {\x1B[0m\n    \x1B[2m[\x1B[0m\x1B[32m\" \"\x1B[0m\x1B[2m]\x1B[0m\x1B[2m = \x1B[0m\x1B[96m1\x1B[0m\x1B[2m,\x1B[0m \n\x1B[2m}\x1B[0m");
        expect((res:sub(1,28)):find("\x1B%[2m<table: 0x.+>")).never.toBeNil();
    end)
end)
