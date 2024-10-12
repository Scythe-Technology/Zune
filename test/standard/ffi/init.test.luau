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
        struct = expect.type("function"),
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

    describe("struct", function()
        test("Foo Structure", function()
            local Foo_struct = ffi.struct({
                { x = ffi.types.i32 },
                { y = ffi.types.i32 },
            });

            expect(Foo_struct:size()).toBe(8);
            expect(Foo_struct:alignment()).toBe(4);
            expect(Foo_struct:offset("x")).toBe(0);
            expect(Foo_struct:offset("y")).toBe(4);

            do
                local buf = Foo_struct:new {
                    x = 1,
                    y = 2,
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(1);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(2);
            end

            do
                local buf = Foo_struct:new {
                    x = 2_147_483_647,
                    y = -2_147_483_648,
                };

                expect(buffer.len(buf)).toBe(Foo_struct:size());
    
                expect(buffer.readi32(buf, Foo_struct:offset("x"))).toBe(2_147_483_647);
                expect(buffer.readi32(buf, Foo_struct:offset("y"))).toBe(-2_147_483_648);
            end
        end)

        test("Float Structure", function()
            local Float_struct = ffi.struct({
                { x = ffi.types.float },
                -- [...] padded by 4 bytes
                { y = ffi.types.double },
            });

            expect(Float_struct:size()).toBe(16);
            expect(Float_struct:alignment()).toBe(8);
            expect(Float_struct:offset("x")).toBe(0);
            expect(Float_struct:offset("y")).toBe(8);

            do
                local buf = Float_struct:new {
                    x = 3.4028234663852886e38,
                    y = 1.7976931348623158e308,
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(1.7976931348623158e308);
            end

            do
                local buf = Float_struct:new {
                    x = -3.4028234663852886e38,
                    y = -1.7976931348623158e308,
                };

                expect(buffer.len(buf)).toBe(Float_struct:size());
    
                expect(buffer.readf32(buf, Float_struct:offset("x"))).toBe(-3.4028234663852886e38);
                expect(buffer.readf64(buf, Float_struct:offset("y"))).toBe(-1.7976931348623158e308);
            end
        end)

        test("Deep Structure", function()
            local a_struct = ffi.struct({
                { x = ffi.types.i32 },
                { y = ffi.types.i32 },
            });
            local b_struct = ffi.struct({
                { tag = ffi.types.i32 },
                { data = a_struct },
            });

            local buf = b_struct:new {
                tag = 1,
                data = a_struct:new {
                    x = 1,
                    y = 2,
                },
            }
            
            expect(buffer.len(buf)).toBe(b_struct:size());
            expect(buffer.readi32(buf, b_struct:offset("tag"))).toBe(1);
            expect(buffer.readi32(buf, b_struct:offset("data") + a_struct:offset("x"))).toBe(1);
            expect(buffer.readi32(buf, b_struct:offset("data") + a_struct:offset("y"))).toBe(2);
        end)

        test("Invalid Structure", function()
            expect(function()
                ffi.struct({
                    { x = ffi.types.i32 },
                    { y = ffi.types.i32 },
                    { [3] = ffi.types.i32 },
                });
            end).toThrow("InvalidFieldName");
            expect(function()
                ffi.struct({
                    { x = ffi.types.i32 },
                    { y = ffi.types.i32 },
                    { z = ffi.types.i32, b = ffi.types.i32 },
                });
            end).toThrow("ExtraFieldsFound");
        end)
    end)

    describe("Sample Library", function()
        local foo_struct = ffi.struct({
            { x = ffi.types.i32 },
            { y = ffi.types.i32 },
        });

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

            check_string = {
                returns = ffi.types.u8,
                args = {ffi.types.pointer},
            },
            check_struct = {
                returns = ffi.types.u8,
                args = {foo_struct},
            },
            check_nullptr = {
                returns = ffi.types.u8,
                args = {ffi.types.pointer},
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

        test("Symbol<void check_string(const char*)>", function()
            expect(lib.check_string("hello")).toBe(1);
            expect(lib.check_string("Hello")).toBe(0);
        end)

        test("Symbol<void check_struct(Foo)>", function()
            do
                local buf = foo_struct:new {
                    x = 1,
                    y = 2,
                };

                expect(lib.check_struct(buf)).toBe(1);
            end

            do
                local buf = foo_struct:new {
                    x = 2,
                    y = 2,
                };
    
                expect(lib.check_struct(buf)).toBe(0);
            end
        end)

        test("Symbol<void check_nullptr(*void)>", function()
            expect(lib.check_nullptr(nil)).toBe(1);

            -- When buffer to refer to a pointer, the pointer cannot be null, better to use "nil"
            expect(function()
                lib.check_nullptr(buffer.create(ffi.sizeOf(ffi.types.pointer)));
            end).toThrow("NullPtr");

            local dummy_value = buffer.create(0);
            local ptr = ffi.intFromPtr(buffer.create(ffi.sizeOf(ffi.types.pointer)), dummy_value);
            expect(lib.check_nullptr(ptr)).toBe(0);
            expect(lib.check_nullptr("")).toBe(0);
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
