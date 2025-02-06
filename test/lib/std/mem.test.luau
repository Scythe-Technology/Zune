--!strict
local testing = zune.testing;

local test = testing.test;
local expect = testing.expect;
local describe = testing.describe;

local mem = require("@std/mem");

describe("sliceOwned", function()
    test("Example", function()
        local b = buffer.fromstring("Hello")
        local slice = mem.sliceOwned(b, 2, 2)
        expect(buffer.tostring(slice)).toBe("ll")
    end)
    test("None", function()
        local b = buffer.create(0)
        local slice = mem.sliceOwned(b, 0, 0)
        expect(buffer.len(slice)).toBe(0)
    end)
    test("Single", function()
        local b = buffer.fromstring("H")
        local slice = mem.sliceOwned(b, 0, 1)
        expect(buffer.tostring(slice)).toBe("H")
    end)
    test("One", function()
        local b = buffer.fromstring("Hello")
        local slice = mem.sliceOwned(b, 0, 1)
        expect(buffer.tostring(slice)).toBe("H")
    end)
    test("No Size", function()
        local b = buffer.fromstring("Hello")
        local slice = mem.sliceOwned(b, 1)
        expect(buffer.tostring(slice)).toBe("ello")
    end)
end)

describe("reverse", function()
    test("Example", function()
        local b = buffer.fromstring("Hello")
        mem.reverse(b, 0, 5)
        expect(buffer.tostring(b)).toBe("olleH")
    end)
    test("None", function()
        local b = buffer.create(0)
        mem.reverse(b, 0, 0)
        expect(buffer.len(b)).toBe(0)
    end)
    test("Single", function()
        local b = buffer.fromstring("H")
        mem.reverse(b, 0, 1)
        expect(buffer.tostring(b)).toBe("H")
    end)
end)

describe("joinOwned", function()
    test("Example", function()
        local b = {
            buffer.fromstring("Hello"),
            buffer.fromstring("World!")
        }
        local joined = mem.joinOwned(buffer.fromstring(", "), b)
        expect(buffer.tostring(joined)).toBe("Hello, World!")
    end)
    test("None", function()
        local b = {}
        local joined = mem.joinOwned(nil, b)
        expect(buffer.len(joined)).toBe(0)
    end)
    test("Single", function()
        local b = {
            buffer.fromstring("Hello")
        }
        local joined = mem.joinOwned(nil, b)
        expect(buffer.tostring(joined)).toBe("Hello")
    end)
    test("No separator", function()
        local b = {
            buffer.fromstring("Hello"),
            buffer.fromstring("World!")
        }
        local joined = mem.joinOwned(nil, b)
        expect(buffer.tostring(joined)).toBe("HelloWorld!")
    end)
end)

return nil;
