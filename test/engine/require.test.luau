local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Require", function()
    describe("Good", function()
        test("Known File", function()
            local ok, res = pcall(require, "samples/simpleLib");
            expect(ok).toBeTruthy();
            expect(res).toBe(expect.any("table"));
            expect(res.size).toBe(32);
            expect(res.buffer).toBe(expect.any("buffer"));
        end)

        test("Known Module", function()
            local ok, res = pcall(require, "@zcore/fs");
            expect(ok).toBeTruthy();
            expect(res).toBe(expect.any("table"));
        end)
    end)

    describe("Bad", function()
        test("Unknown File", function()
            local ok, res = pcall(require, "samples/simpleLib2");
            expect(ok).toBeFalsy();
            expect(res).toBe("FileNotFound");
        end)

        test("Unknown File #2", function()
            local ok, res = pcall(require, "/simpleLib");
            expect(ok).toBeFalsy();
            expect(res).toBe("FileNotFound");
        end)

        test("Unknown Module", function()
            local ok, res = pcall(require, "@zcore/some-unknown-module");
            expect(ok).toBeFalsy();
            expect(res).toBe("ModuleNotFound");
        end)

        test("Unknown Alias", function()
            local ok, res = pcall(require, "@unknown/module");
            expect(ok).toBeFalsy();
            expect(res).toBe("NoAlias");
        end)
    end)
end)

describe("Require Many Value", function()
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
end)

describe("Aliases", function()
    test("@Dev", function()
        local dev = require("@dev");
        expect(dev).toBe(expect.similar({
            Boolean = true,
            Number = 1,
            String = "string",
        }));
    end)
    
    test("@Module", function()
        local module = require("@module");
        expect(module).toBe(expect.type("string"));
        expect(module).toBe("FullModule");
    end)

    test("@Module/sub", function()
        local module = require("@module/sub");
        expect(module).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }));
        expect(module.foo()).toBe("foo");
        expect(module.bar()).toBe("bar");
    end)
    
end)
