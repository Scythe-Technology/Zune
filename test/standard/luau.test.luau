--!strict
local luau = require("@zcore/luau");
local testing = require("@zcore/testing");

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function makeLine(line : number)
    return string.rep("\n", line - 1);
end

describe("Compile", function()
    test("Basic", function()
        local ok, bytecode = luau.compile("print('Hello, World!')");
        expect(ok).toBe(true);
        expect(bytecode).toBe("\5\2\2\5\112\114\105\110\116\13\72\101\108\108\111\44\32\87\111\114\108\100\33\1\2\0\0\1\2\0\6\65\0\0\0\12\0\1\0\0\0\0\64\5\1\2\0\21\0\2\1\22\0\1\0\3\3\1\4\0\0\0\64\3\2\0\1\0\1\24\0\0\0\0\0\0\1\0\0\0\0\0");
    end)

    test("Options", function()
        local ok, bytecode = luau.compile("print('Hello!')", {
            optimization_level = 0,
            debug_level = 0,
            coverage_level = 2,
        });
        local ok2, bytecode2 = luau.compile("print('Hello!')", {
            optimization_level = 1,
            debug_level = 1,
            coverage_level = 0,
        });
        expect(ok).toBe(true);
        expect(ok2).toBe(true);
        expect(bytecode).toBe("\5\2\2\5\112\114\105\110\116\6\72\101\108\108\111\33\1\2\0\0\1\2\0\9\65\0\0\0\69\0\0\0\69\0\0\0\7\0\0\70\0\0\0\0\69\0\0\0\5\1\1\0\21\0\2\1\22\0\1\0\2\3\1\3\2\0\1\0\0\0\0");
        expect(bytecode2).toBe("\5\2\2\5\112\114\105\110\116\6\72\101\108\108\111\33\1\2\0\0\1\2\0\6\65\0\0\0\12\0\1\0\0\0\0\64\5\1\2\0\21\0\2\1\22\0\1\0\3\3\1\4\0\0\0\64\3\2\0\1\0\1\24\0\0\0\0\0\0\1\0\0\0\0\0");
        expect(bytecode).never.toBe(bytecode2);
    end)

    test("Error Basic", function()
        local ok, err = luau.compile(makeLine(1).."a");
        expect(ok).toBe(false);
        expect(err).toBe(expect.type("string"));
        expect(err).toBe(":1: Incomplete statement: expected assignment or a function call");
    end)

    test("Error Basic (Line)", function()
        local ok, err = luau.compile(makeLine(1234).."a");
        expect(ok).toBe(false);
        expect(err).toBe(expect.type("string"));
        expect(err).toBe(":1234: Incomplete statement: expected assignment or a function call");
    end)
end)

local function returnStringBytecode(str : string)
    return `\5\2\1{string.char(#str)}{str}\1\1\0\0\1\2\0\3\65\0\0\0\5\0\0\0\22\0\2\0\1\3\1\0\1\0\1\24\0\0\0\1\0\0\0\0\0`
end

local function timeFunction(f: () -> ())
    local start = os.clock();
    f();
    return os.clock() - start;
end

describe("Load", function()
    local bytecodeOk, bytecode = luau.compile("return 'Hello, World!'");
    expect(bytecodeOk).toBe(true);
    expect(bytecode).toBe(returnStringBytecode "Hello, World!");
    
    test("Basic", function()
        local func = luau.load(bytecode);
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello, World!");
    end)

    test("Basic", function()
        local func = luau.load(bytecode);
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello, World!");
    end)

    test("Options", function()
        local bOk, bCode = luau.compile("return a");
        expect(bOk).toBe(true);
        expect(bCode).toBe("\5\2\1\1\97\1\1\0\0\1\2\0\4\65\0\0\0\12\0\1\0\0\0\0\64\22\0\2\0\2\3\1\4\0\0\0\64\0\1\0\1\24\0\0\0\0\1\0\0\0\0\0");
        local func = luau.load(bCode, {
            env = {
                a = "Foo",
            }
        });
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Foo");
    end)

    test("Options (2)", function()
        local bOk, bCode = luau.compile("return a()");
        expect(bOk).toBe(true);
        expect(bCode).toBe("\5\2\1\1\97\1\1\0\0\1\2\0\5\65\0\0\0\12\0\1\0\0\0\0\64\21\0\1\0\22\0\0\0\2\3\1\4\0\0\0\64\0\1\0\1\24\0\0\0\0\0\1\0\0\0\0\0");
        local func = luau.load(bCode, {
            chunkName = "test",
        });
        expect(func).toBe(expect.type("function"));
        expect(func).toThrow(`attempt to call a nil value`);
    end)

    describe("CodeGen", function()
        local function native()
            local size = 2e5;
            local buf = buffer.create(size);
            for i = 1, size do
                buffer.writeu8(buf, i - 1, i);
            end
        end
        local bOk, bCode = luau.compile([[
            local size = 2e5;
            local buf = buffer.create(size);
            for i = 1, size do
                buffer.writeu8(buf, i - 1, i);
            end
        ]]);
        expect(bOk).toBe(true);
        local safeNativeTime = timeFunction(native);
        test("Basic (NCG Enabled)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = true;
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 1);
        end)

        test("New Environment (NCG Enabled)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = true;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 1);
        end)

        getfenv(); -- Force unsafe environment

        local UnsafeNativeTime = timeFunction(native);

        test("Basic (NCG Disabled)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = false;
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, 0.25);
        end)

        test("New Environment (NCG Disabled)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = false;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, 0); -- could be much faster, since it is a stripped environment
        end)

        test("Basic (NCG Enabled, Unsafe)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = true;
            });
            expect(func).toBe(expect.type("function"));
            -- Should be slower than the safe native time, because the global environment is unsafe
            expect(timeFunction(func)).toBeCloseTo(UnsafeNativeTime, 0.25);
        end)

        test("New Environment (NCG Enabled, Unsafe)", function()
            local func = luau.load(bCode, {
                nativeCodeGen = true;
                env = {
                    buffer = buffer,
                };
            });
            expect(func).toBe(expect.type("function"));
            -- Should be faster than the unsafe native time, because the environment is safe (custom table)
            expect(timeFunction(func)).toBeCloseTo(safeNativeTime, 1);
        end)
    end)

    test("Environment", function()
        local bOk, bCode = luau.compile("return require");
        expect(bOk).toBe(true);
        expect(bCode).toBe("\5\2\1\7\114\101\113\117\105\114\101\1\1\0\0\1\2\0\4\65\0\0\0\12\0\1\0\0\0\0\64\22\0\2\0\2\3\1\4\0\0\0\64\0\1\0\1\24\0\0\0\0\1\0\0\0\0\0");
        local func = luau.load(bCode, {
            chunkName = "test",
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv(func)).toBe(getfenv());
        expect(func()).toBe(require);
    end)

    test("Environment (2)", function()
        local bOk, bCode = luau.compile("return require");
        expect(bOk).toBe(true);
        expect(bCode).toBe("\5\2\1\7\114\101\113\117\105\114\101\1\1\0\0\1\2\0\4\65\0\0\0\12\0\1\0\0\0\0\64\22\0\2\0\2\3\1\4\0\0\0\64\0\1\0\1\24\0\0\0\0\1\0\0\0\0\0");
        local env = {};
        local func = luau.load(bCode, {
            chunkName = "test",
            env = env,
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv()).never.toBe(env); -- make sure load didn't change the environment
        expect(getfenv(func)).toBe(env); -- make sure the environment is the one we passed
        expect(func()).toBe(nil);
    end)

    test("Literal", function()
        local func = luau.load(returnStringBytecode "Hello!");
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Hello!");
    end)
end)