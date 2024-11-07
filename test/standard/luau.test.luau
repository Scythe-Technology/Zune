--!strict
local luau = zune.luau;
local testing = zune.testing;

local describe = testing.describe;
local expect = testing.expect;
local test = testing.test;

local function makeLine(line : number)
    return string.rep("\n", line - 1);
end

describe("Compile", function()
    test("Basic", function()
        local bytecode = luau.compile("print('Hello, World!')");
        expect(bytecode).toBe("\x06\x03\x02\x05print\rHello, World!\x00\x01\x02\x00\x00\x01\x02\x00\x06A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x05\x01\x02\x00\x15\x00\x02\x01\x16\x00\x01\x00\x03\x03\x01\x04\x00\x00\x00@\x03\x02\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
    end)

    test("Options", function()
        local bytecode = luau.compile("print('Hello!')", {
            optimization_level = 0,
            debug_level = 0,
            coverage_level = 2,
        });
        local bytecode2 = luau.compile("print('Hello!')", {
            optimization_level = 1,
            debug_level = 1,
            coverage_level = 0,
        });
        expect(bytecode).toBe("\x06\x03\x02\x05print\x06Hello!\x00\x01\x02\x00\x00\x01\x02\x00\tA\x00\x00\x00E\x00\x00\x00E\x00\x00\x00\a\x00\x00F\x00\x00\x00\x00E\x00\x00\x00\x05\x01\x01\x00\x15\x00\x02\x01\x16\x00\x01\x00\x02\x03\x01\x03\x02\x00\x01\x00\x00\x00\x00");
        expect(bytecode2).toBe("\x06\x03\x02\x05print\x06Hello!\x00\x01\x02\x00\x00\x01\x02\x00\x06A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x05\x01\x02\x00\x15\x00\x02\x01\x16\x00\x01\x00\x03\x03\x01\x04\x00\x00\x00@\x03\x02\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        expect(bytecode).never.toBe(bytecode2);
    end)

    test("Error Basic", function()
        expect(function()
            local _ = luau.compile(makeLine(1).."a");
        end).toThrow(":1: Incomplete statement: expected assignment or a function call");
    end)

    test("Error Basic (Line)", function()
        expect(function()
            luau.compile(makeLine(1234).."a");
        end).toThrow(":1234: Incomplete statement: expected assignment or a function call");
    end)
end)

local function returnStringBytecode(str : string)
    return `\x06\x03\x01{string.char(#str)}{str}\x00\x01\x01\x00\x00\x01\x02\x00\x03A\x00\x00\x00\x05\x00\x00\x00\x16\x00\x02\x00\x01\x03\x01\x00\x01\x00\x01\x18\x00\x00\x00\x01\x00\x00\x00\x00\x00`
end

local function timeFunction(f: () -> ())
    local start = os.clock();
    f();
    return os.clock() - start;
end

describe("Load", function()
    local bytecode = luau.compile("return 'Hello, World!'");
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
        local bCode = luau.compile("return a");
        expect(bCode).toBe("\x06\x03\x01\x01a\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local func = luau.load(bCode, {
            env = {
                a = "Foo",
            }
        });
        expect(func).toBe(expect.type("function"));
        expect(func()).toBe("Foo");
    end)

    test("Options (2)", function()
        local bCode = luau.compile("return a()");
        expect(bCode).toBe("\x06\x03\x01\x01a\x00\x01\x01\x00\x00\x01\x02\x00\x05A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x15\x00\x01\x00\x16\x00\x00\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
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
        local bCode = luau.compile([[
            local size = 2e5;
            local buf = buffer.create(size);
            for i = 1, size do
                buffer.writeu8(buf, i - 1, i);
            end
        ]]);
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
        local bCode = luau.compile("return require");
        expect(bCode).toBe("\x06\x03\x01\arequire\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
        local func = luau.load(bCode, {
            chunkName = "test",
        });
        expect(func).toBe(expect.type("function"));
        expect(getfenv(func)).toBe(getfenv());
        expect(func()).toBe(require);
    end)

    test("Environment (2)", function()
        local bCode = luau.compile("return require");
        expect(bCode).toBe("\x06\x03\x01\arequire\x00\x01\x01\x00\x00\x01\x02\x00\x04A\x00\x00\x00\f\x00\x01\x00\x00\x00\x00@\x16\x00\x02\x00\x02\x03\x01\x04\x00\x00\x00@\x00\x01\x00\x01\x18\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00");
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