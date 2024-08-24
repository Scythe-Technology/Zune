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