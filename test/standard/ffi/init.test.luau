--!strict
local ffi = require("@zcore/ffi");
local process = require("@zcore/process");
local testing = require("@zcore/testing");

local test = testing.test;
local expect = testing.expect;
local describe = testing.describe;

expect(ffi).toBe(
    expect.similar({
        dlopen = expect.type("function"),
        sizeOf = expect.type("function"),
        alignOf = expect.type("function"),
        eqlPtr = expect.type("function"),
        intFromPtr = expect.type("function"),
        valueFromPtr = expect.type("function"),
        writeIntoPtr = expect.type("function"),
        prefix = expect.type("string"),
        suffix = expect.type("string"),
        supported = expect.type("boolean"),
        types = expect.similar({
            void = expect.type("number"),
            i8 = expect.type("number"),
            u8 = expect.type("number"),
            i16 = expect.type("number"),
            u16 = expect.type("number"),
            i32 = expect.type("number"),
            u32 = expect.type("number"),
            i64 = expect.type("number"),
            u64 = expect.type("number"),
            float = expect.type("number"),
            double = expect.type("number"),
            pointer = expect.type("number"),
        }),
    })
);

if (process.os == "windows") then
    expect(ffi.prefix).toBe("");
    expect(ffi.suffix).toBe("dll");
elseif (process.os == "linux") then
    expect(ffi.prefix).toBe("lib");
    expect(ffi.suffix).toBe("so");
elseif (process.os == "macos") then
    expect(ffi.prefix).toBe("lib");
    expect(ffi.suffix).toBe("dylib");
else
    error("Unsupported OS: " .. process.os);
end

-- Workaround for Windows tests, test sample library
local static_suffix = ffi.suffix;
if (process.os == "windows") then
    static_suffix = "lib";
end

describe("FFI", function()
    if (not ffi.supported) then
        warn("Skipping 'FFI' tests (Not Supported)");
        return; -- Skip
    end
    describe("dlopen", function()
        test("Sample Library (No Decls)", function()
            local lib = ffi.dlopen(`./zig-out/{ffi.prefix}sample.{static_suffix}`, {});
            expect(lib).toBe(expect.type("userdata"));
            lib:close();
        end);
        test("Fail", function()
            expect(function()
                ffi.dlopen(`./zig-out/{ffi.prefix}invalid.{static_suffix}`, {});
            end).toThrow("FileNotFound");
        end);
    end)

    describe("Sample Library", function()
        local lib = ffi.dlopen(`./zig-out/{ffi.prefix}sample.{static_suffix}`, {
            add = {
                returns = ffi.types.i32,
                args = {ffi.types.i32, ffi.types.i32},
            },
            add_ptr = {
                returns = ffi.types.void,
                args = {ffi.types.pointer, ffi.types.i32},
            },
            add_ptr_ptr = {
                returns = ffi.types.void,
                args = {ffi.types.pointer, ffi.types.i32},
            },

            new_i32 = {
                returns = ffi.types.pointer,
                args = {},
            },
            free_i32 = {
                returns = ffi.types.void,
                args = {ffi.types.pointer},
            },
        });
        expect(lib).toBe(expect.type("userdata"));

        test("Symbol<i32 add(i32 i32)>", function()
            expect(lib.add(1, 2)).toBe(3);
        end)

        test("Symbol<void add_ptr(*i32, i32)>", function()
            local out = buffer.create(ffi.sizeOf(ffi.types.i32));
            local ptr = buffer.create(ffi.sizeOf(ffi.types.pointer));
            ffi.intFromPtr(ptr, out);
            lib.add_ptr(ptr, 1);
            
            expect(buffer.readi32(out, 0)).toBe(1);

            lib.add_ptr(ptr, 6);

            expect(buffer.readi32(out, 0)).toBe(7);
        end)
        test("Symbol<void add_ptr_ptr(**i32, i32)>", function()
            local out = buffer.create(ffi.sizeOf(ffi.types.i32));

            local ptr = buffer.create(ffi.sizeOf(ffi.types.pointer));
            ffi.intFromPtr(ptr, out);
            local ptr_ptr = ffi.intFromPtr(buffer.create(ffi.sizeOf(ffi.types.pointer)), ptr);

            lib.add_ptr_ptr(ptr_ptr, 1);
            
            expect(ffi.valueFromPtr(ptr, ffi.types.i32)).toBe(1);
            expect(buffer.readi32(out, 0)).toBe(1);

            lib.add_ptr_ptr(ptr_ptr, 6);

            expect(ffi.valueFromPtr(ptr, ffi.types.i32)).toBe(7);
            expect(buffer.readi32(out, 0)).toBe(7);
        end)

        describe("External Memory Management", function()
            local ptr = nil;
            test("Symbol<*i32 new_i32()>", function()
                ptr = lib.new_i32();
                expect(ptr).toBe(expect.type("buffer"));
                expect(buffer.len(ptr)).toBe(ffi.sizeOf(ffi.types.pointer));

                expect(ffi.valueFromPtr(ptr, ffi.types.i32)).toBe(123);

                local src = buffer.create(ffi.sizeOf(ffi.types.i32));
                buffer.writei32(src, 0, 42);
                ffi.writeIntoPtr(ptr, 0, src, 0, ffi.sizeOf(ffi.types.i32));

                expect(ffi.valueFromPtr(ptr, ffi.types.i32)).toBe(42);
            end)

            test("Symbol<void free_i32(*i32)>", function()
                assert(ptr, "Pointer is nil");
                lib.free_i32(ptr);
            end)
        end)

        lib:close();
    end)
end);
