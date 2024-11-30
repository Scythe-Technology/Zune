--!strict
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

assert(type(describe) == "function", `Should be function, got {type(describe)}`);
assert(type(expect) == "table", `Should be table, got {type(expect)}`);
assert(type(test) == "function", `Should be function, got {type(test)}`);

describe("Test Scope", function()
    test("test", function()
    end)
    test("long", function()
        local start = os.clock() + 0.05;
        while start > os.clock() do end
    end)
    test("test error", function()
        local ok, err = pcall(error, "err");
        expect(ok).toBe(false);
        expect(err).toBe("err");
    end)
    test("test case", function()
        local ok, err = pcall(function()
            expect(1).toBe(2);
        end)
        expect(ok).toBe(false);
        expect(err:find("[string \"testing.test.luau\"]:26: Expected", 1, true)).toBe(1);
    end)
    test("test failed", function()
        expect(1).never.toBe(1);
    end)
    describe("SubScope", function()
        test("test", function()
        end)
        test("long", function()
            local start = os.clock() + 0.05;
            while start > os.clock() do end
        end)
        test("test error", function()
            local ok, err = pcall(error, "err");
            expect(ok).toBe(false);
            expect(err).toBe("err");
        end)
        test("test case", function()
            local ok, err = pcall(function()
                expect(1).toBe(2);
            end)
            expect(ok).toBe(false);
            expect(err:find("[string \"testing.test.luau\"]:48: Expected", 1, true)).toBe(1);
        end)
        test("test failed", function()
            expect(1).never.toBe(1);
        end)
    end)

    test("test stacktrace", function()
        getfenv();
        local function test()
            local function test2()
                local function test3()
                    error("err");
                end
                test3();
            end
            test2();
        end
        test();
    end)
end)

assert(testing.running, `Should be true, got {testing.running}`);
assert(type(testing._start) == "number", `Should be number, got {testing._start}`);
