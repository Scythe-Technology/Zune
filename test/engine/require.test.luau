local task = zune.task;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

describe("Require", function()
    describe("Good", function()
        test("Known File", function()
            local ok, res = pcall(require, "./samples/simpleLib");
            expect(ok).toBeTruthy();
            expect(res).toBe(expect.any("table"));
            expect(res.size).toBe(32);
            expect(res.buffer).toBe(expect.any("buffer"));
        end)
    end)

    describe("Bad", function()
        test("Bad Syntax", function()
            local ok, res = pcall(require, "samples/simpleLib2");
            expect(ok).toBeFalsy();
            expect(res).toBe(`must have either "@", "./", or "../" prefix`);
        end)

        test("Bad Syntax #2", function()
            local ok, res = pcall(require, "./samples/simpleLib2.luau");
            expect(ok).toBeFalsy();
            expect(res).toBe(`RedundantFileExtension`);
        end)

        local SEP = if (zune.process.os == "windows") then "\\" else "/";
        test("Name Conflict", function()
            local ok, res = pcall(require, "./generated/duplicate");
            expect(ok).toBeFalsy();
            expect(res).toBe(`module name conflicted.\n\n- generated{SEP}duplicate.luau\n- generated{SEP}duplicate.lua`);
        end)

        test("Name Conflict #2", function()
            local ok, res = pcall(require, "./generated/duplicate2");
            expect(ok).toBeFalsy();
            expect(res).toBe(`module name conflicted.\n\n- generated{SEP}duplicate2.luau\n- generated{SEP}duplicate2.lua\n- generated{SEP}duplicate2{SEP}init.luau`);
        end)

        test("Unknown File", function()
            local ok, res = pcall(require, "./samples/simpleLib2");
            expect(ok).toBeFalsy();
            expect(res).toBe("FileNotFound");
        end)

        test("Unknown File #2", function()
            local ok, res = pcall(require, "./simpleLib");
            expect(ok).toBeFalsy();
            expect(res).toBe("FileNotFound");
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
        expect(_FILE.name:find("require%.test%.luau")).never.toBeNil();
    end)
    
    test("Require Buffer", function()
        expect(require("./generated/v1")).toBe(expect.type("buffer"));
    end)
    
    test("Require Number", function()
        expect(require("./generated/v2")).toBe(1);
    end)
    
    test("Require String", function()
        expect(require("./generated/v3")).toBe("Hello, World!");
    end)
    
    test("Require Boolean", function()
        expect(require("./generated/v4")).toBe(true);
    end)

    test("Require Async", function()
        expect(require("./generated/v5")).toBe(true);
    end)

    test("Require Async Queue", function()
        local a, b, c;
        local start = os.clock();
        task.spawn(function()
            a = require("./generated/v6")
        end)
        task.spawn(function()
            b = require("./generated/v6")
        end)
        task.spawn(function()
            c = require("./generated/v6")
        end)
        local res = require("./generated/v6");
        expect(os.clock() - start).toBeCloseTo(1, 0);

        expect(a).toBe(res);
        expect(b).toBe(res);
        expect(c).toBe(res);
    end)

    test("Require Async Error", function()
        local success, err = pcall(require, ("./generated/yielderror"));
        expect(success).toBe(false);
        expect(err).toBe("requested module failed to load");
    end)
    
    test("Require Blank", function()
        local res = require(("./generated/blank"))::any;
        expect(res).toBe(nil);
    end)
    
    test("Require TooMany", function()
        local ok, err = pcall(require, ("./generated/toomany"));
        expect(ok).toBeFalsy();
        assert((string.find(err, "module must return one value")) ~= nil);
    end)

    test("Require Yield TooMany", function()
        local ok, err = pcall(require, ("./generated/yieldtoomany"));
        expect(ok).toBeFalsy();
        assert((string.find(err, "module must return one value")) ~= nil);
    end)
end)

describe("Require .lua", function()
    test("Require Module", function()
        expect(require("./legacy")).toBe(expect.similar({
            "Legacy"
        }));
    end)
    test("Require A", function()
        expect(require("./legacy/A")).toBe("A-Legacy");
    end)
end)

describe("Aliases", function()
    test("@Dev", function()
        local dev = require("@dev")::any;
        expect(dev).toBe(expect.similar({
            Boolean = true,
            Number = 1,
            String = "string",
        }));
    end)
    
    test("@Module", function()
        local module = require("@module")::any;
        expect(module).toBe(expect.type("string"));
        expect(module).toBe("FullModule");
    end)

    test("@Module/sub", function()
        local module = require("@module/sub")::any;
        expect(module).toBe(expect.similar({
            foo = expect.type("function"),
            bar = expect.type("function"),
        }));
        expect(module.foo()).toBe("foo");
        expect(module.bar()).toBe("bar");
    end)

    test("@Sub2/kool", function()
        local module = require("@sub2/kool")::any;
        expect(module).toBe("Sub library");
    end)

    test("@Sub/foo (sub-directory, overridden)", function()
        local module = require("@sub/foo")::any;
        expect(module).toBe("The bar exam");
    end)

    test("@Kool (sub-directory .luaurc defined)", function()
        local module = require("@kool")::any;
        expect(module).toBe("Sub library");
    end)

    test("@Foo (sub-directory x2, .luaurc defined)", function()
        local module = require("@foo")::any;
        expect(module).toBe("The bar exam");
    end)
end)
