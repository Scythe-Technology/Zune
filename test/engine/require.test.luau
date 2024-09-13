local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Require", function()
    test("Good", function()
        local successGood, resultGood = pcall(require, "samples/simpleLib");
        expect(successGood).toBeTruthy();
        expect(resultGood).toBe(expect.any("table"));
        expect(resultGood.size).toBe(32);
        expect(resultGood.buffer).toBe(expect.any("buffer"));
        
        local successModuleGood, resultModuleGood = pcall(require, "@zcore/fs");
        expect(successModuleGood).toBeTruthy();
        expect(resultModuleGood).toBe(expect.any("table"));
    end)

    test("Bad", function()
        local successBad, resultBad = pcall(require, "samples/simpleLib2");
        expect(successBad).toBeFalsy();
        expect(resultBad).toBe("FileNotFound");
        
        local successBad2, resultBad2 = pcall(require, "/simpleLib");
        expect(successBad2).toBeFalsy();
        expect(resultBad2).toBe("FileNotFound");

        local successModuleBad, resultModuleBad = pcall(require, "@unknown/module");
        expect(successModuleBad).toBeFalsy();
        expect(resultModuleBad).toBe("ModuleNotFound");
    end)
end)

test("Validating Require Context", function()
    expect(_FILE).never.toBeNil();
    expect(_FILE:find("require%.test%.luau")).never.toBeNil();
end)

test("Require Buffer", function()
    expect(require(("generated/v1"))).toBe(expect.type("buffer"));
end)

test("Require Number", function()
    expect(require(("generated/v2"))).toBe(1);
end)

test("Require String", function()
    expect(require(("generated/v3"))).toBe("Hello, World!");
end)

test("Require Boolean", function()
    expect(require(("generated/v4"))).toBe(true);
end)

test("Require Blank", function()
    local ok, err = pcall(require, ("generated/blank"));
    expect(ok).toBeFalsy();
    assert((string.find(err, "module must return one value")) ~= nil);
end)

test("Require TooMany", function()
    local ok, err = pcall(require, ("generated/toomany"));
    expect(ok).toBeFalsy();
    assert((string.find(err, "module must return one value")) ~= nil);
end)
