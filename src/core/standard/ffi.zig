const std = @import("std");
const ffi = @import("ffi");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "@zcore/ffi";

const LuaPointer = struct {
    ptr: *anyopaque,
};

const LuaHandle = struct {
    lib: std.DynLib,
    open: bool,
    declared: std.StringArrayHashMap(ffi.CallableFunction),

    pub const META = "ffi_dynlib_handle";
    pub const tag = 103; // "ffi" bytes added together divided by 3

    pub fn call_ffi(L: *Luau) !i32 {
        const index_idx = Luau.upvalueIndex(1);
        const ptr_idx = Luau.upvalueIndex(2);

        const index = L.checkString(index_idx);
        const ptr = L.toUserdataTagged(LuaHandle, ptr_idx, LuaHandle.tag) catch L.raiseErrorStr("Invalid handle", .{});

        const allocator = L.allocator();

        const entry = ptr.declared.getEntry(index) orelse std.debug.panic("FFI not found", .{});

        const ffi_func = entry.value_ptr;

        if (@as(usize, @intCast(L.getTop())) != ffi_func.argTypes.len - 1)
            L.raiseErrorStr("Invalid number of arguments", .{});

        const args = try allocator.alloc(*anyopaque, ffi_func.argTypes.len - 1);

        var alloclen: usize = 0;
        defer allocator.free(args);
        defer {
            for (0..alloclen) |i| {
                switch (ffi.toffiType(ffi_func.argTypes[i])) {
                    .void => std.debug.panic("Void arg", .{}),
                    .i8 => allocator.destroy(@as(*i8, @ptrCast(args[i]))),
                    .u8 => allocator.destroy(@as(*u8, @ptrCast(args[i]))),
                    .i16 => allocator.destroy(@as(*i16, @alignCast(@ptrCast(args[i])))),
                    .u16 => allocator.destroy(@as(*u16, @alignCast(@ptrCast(args[i])))),
                    .i32 => allocator.destroy(@as(*i32, @alignCast(@ptrCast(args[i])))),
                    .u32 => allocator.destroy(@as(*u32, @alignCast(@ptrCast(args[i])))),
                    .i64 => allocator.destroy(@as(*i64, @alignCast(@ptrCast(args[i])))),
                    .u64 => allocator.destroy(@as(*u64, @alignCast(@ptrCast(args[i])))),
                    .float => allocator.destroy(@as(*f32, @alignCast(@ptrCast(args[i])))),
                    .double => allocator.destroy(@as(*f64, @alignCast(@ptrCast(args[i])))),
                    .pointer => allocator.destroy(@as(**anyopaque, @alignCast(@ptrCast(args[i])))),
                    else => std.debug.panic("Invalid arg type", .{}),
                }
            }
        }

        for (0..args.len) |i| {
            switch (ffi.toffiType(ffi_func.argTypes[i])) {
                .void => std.debug.panic("Void arg", .{}),
                .i8 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const value = L.toInteger(@intCast(i + 1)) catch unreachable;
                    if (value < -128 or value > 127)
                        return error.OutOfRange;
                    const v_ptr = try allocator.create(i8);
                    v_ptr.* = @intCast(value);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .u8 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const value = L.toInteger(@intCast(i + 1)) catch unreachable;
                    if (value < 0 or value > 255)
                        return error.OutOfRange;
                    const v_ptr = try allocator.create(u8);
                    v_ptr.* = @intCast(value);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .i16 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const value = L.toInteger(@intCast(i + 1)) catch unreachable;
                    if (value < -32768 or value > 32767)
                        return error.OutOfRange;
                    const v_ptr = try allocator.create(i16);
                    v_ptr.* = @intCast(value);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .u16 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const value = L.toInteger(@intCast(i + 1)) catch unreachable;
                    if (value < 0 or value > 65535)
                        return error.OutOfRange;
                    const v_ptr = try allocator.create(u16);
                    v_ptr.* = @intCast(value);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .i32 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const v_ptr = try allocator.create(i32);
                    v_ptr.* = @intCast(L.toInteger(@intCast(i + 1)) catch unreachable);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .u32 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const v_ptr = try allocator.create(u32);
                    v_ptr.* = @intCast(L.toInteger(@intCast(i + 1)) catch unreachable);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .i64 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const v_ptr = try allocator.create(i64);
                    v_ptr.* = @intCast(L.toInteger(@intCast(i + 1)) catch unreachable);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .u64 => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const v_ptr = try allocator.create(u64);
                    v_ptr.* = @intCast(L.toInteger(@intCast(i + 1)) catch unreachable);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .float => {
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    const value = L.toNumber(@intCast(i + 1)) catch unreachable;
                    const large: u64 = @bitCast(value);
                    if (large > 0x7f800000 or large < 0xff800000)
                        return error.OutOfRange;
                    const v_ptr = try allocator.create(f32);
                    v_ptr.* = @floatCast(value);
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .double => {
                    const v_ptr = try allocator.create(f64);
                    if (L.typeOf(@intCast(i + 1)) != .number)
                        return error.InvalidArgType;
                    v_ptr.* = L.toNumber(@intCast(i + 1)) catch unreachable;
                    args[i] = @alignCast(@ptrCast(v_ptr));
                },
                .pointer => {
                    switch (L.typeOf(@intCast(i + 1))) {
                        .userdata => {
                            return error.InvalidArgType;
                        },
                        .buffer => {
                            const buf = L.toBuffer(@intCast(i + 1)) catch unreachable;
                            const ptr_int = std.mem.readVarInt(usize, buf, .little);
                            if (ptr_int == 0)
                                return error.NullPtr;
                            const v_ptr = try allocator.create(*anyopaque);
                            v_ptr.* = @ptrFromInt(ptr_int);
                            args[i] = @alignCast(@ptrCast(v_ptr));
                        },
                        .string => {
                            const str: [:0]const u8 = L.toString(@intCast(i + 1)) catch unreachable;
                            const v_ptr = try allocator.create(*anyopaque);
                            v_ptr.* = @constCast(@ptrCast(str.ptr));
                            args[i] = @alignCast(@ptrCast(v_ptr));
                        },
                        .number => {
                            const num = L.toNumber(@intCast(i + 1)) catch unreachable;
                            if (num != 0)
                                return error.NumberAsPointer;
                            const v_ptr = try allocator.create(*allowzero anyopaque);
                            v_ptr.* = @ptrFromInt(0);
                            args[i] = @alignCast(@ptrCast(v_ptr));
                        },
                        else => return error.InvalidArgType,
                    }
                },
                else => std.debug.panic("Invalid arg type", .{}),
            }
            alloclen += 1;
        }

        const ret = try ffi_func.call(@alignCast(@ptrCast(args)));
        defer ffi_func.free(ret);

        switch (ffi_func.returnType) {
            .ffiType => |ffiType| switch (ffiType) {
                .void => return 0,
                .i8 => L.pushInteger(@intCast(@as(i8, @intCast(ret[0])))),
                .u8 => L.pushInteger(@intCast(ret[0])),
                .i16 => L.pushInteger(@intCast(std.mem.readVarInt(i16, ret, .little))),
                .u16 => L.pushInteger(@intCast(std.mem.readVarInt(u16, ret, .little))),
                .i32 => L.pushInteger(@intCast(std.mem.readVarInt(i32, ret, .little))),
                .u32 => L.pushInteger(@intCast(std.mem.readVarInt(u32, ret, .little))),
                .i64 => try L.pushBuffer(ret),
                .u64 => try L.pushBuffer(ret),
                .float => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, ret, .little))))),
                .double => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, ret, .little)))),
                .pointer => try L.pushBuffer(ret),
                else => std.debug.panic("Invalid return type", .{}),
            },
            .structType => |structType| {
                _ = structType;
                std.debug.panic("Struct return type not supported, yet", .{});
            },
        }

        return 1;
    }

    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const index = L.checkString(2);
        const ptr = L.toUserdataTagged(LuaHandle, 1, LuaHandle.tag) catch L.raiseErrorStr("Invalid handle", .{});

        _ = ptr.declared.get(index) orelse L.raiseErrorStr("Unknown ffi member: %s\n", .{index.ptr});

        L.pushValue(2);
        L.pushValue(1);
        L.pushClosure(luau.EFntoZigFn(call_ffi), "ffi_func", 2);

        return 1;
    }

    pub fn __namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdataTagged(LuaHandle, 1, LuaHandle.tag) catch L.raiseErrorStr("Invalid handle", .{});

        const namecall = L.nameCallAtom() catch return 0;

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            ptr.__dtor();
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    pub fn __dtor(ptr: *LuaHandle) void {
        if (ptr.open) {
            var iter = ptr.declared.iterator();
            while (iter.next()) |entry| {
                ptr.declared.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            ptr.declared.deinit();

            ptr.lib.close();
        }
        ptr.open = false;
    }
};

const SymbolFunction = struct {
    returns_type: ffi.Type,
    args_type: []ffi.Type,
};

const FFITypeSize = std.meta.fields(ffi.Type).len;
fn convertToFFIType(number: i32) !ffi.Type {
    if (number < 0 or @as(u32, @intCast(number)) > FFITypeSize)
        return error.InvalidReturnType;
    return @enumFromInt(number);
}

fn ffi_dlopen(L: *Luau) !i32 {
    const path = L.checkString(1);

    const allocator = L.allocator();

    L.checkType(2, .table);

    var func_map = std.StringArrayHashMap(SymbolFunction).init(allocator);
    defer func_map.deinit();
    defer {
        var iter = func_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.value_ptr.args_type);
    }

    L.pushNil();
    while (L.next(2)) : (L.pop(1)) {
        if (L.typeOf(-2) != .string)
            return error.InvalidName;
        if (L.typeOf(-1) != .table)
            return error.InvalidValue;

        const name = L.toString(-2) catch unreachable;

        if (L.getField(-1, "returns") != .number)
            return error.InvalidReturnType;
        const returns_type = try convertToFFIType(L.toInteger(-1) catch unreachable);
        L.pop(1); // drop: returns

        if (L.getField(-1, "args") != .table)
            return error.InvalidArgs;

        const args_len = L.objLen(-1);

        const args = try allocator.alloc(ffi.Type, @intCast(args_len));
        errdefer allocator.free(args);

        var order: usize = 0;
        L.pushNil();
        while (L.next(-2)) : (L.pop(1)) {
            if (L.typeOf(-2) != .number)
                return error.InvalidArgOrder;
            if (L.typeOf(-1) != .number)
                return error.InvalidArgType;

            const index = L.toInteger(-2) catch unreachable;
            if (index != order + 1)
                return error.InvalidArgOrder;

            args[order] = try convertToFFIType(L.toInteger(-1) catch unreachable);
            if (args[order] == .void)
                return error.VoidArg;
            order += 1;
        }
        L.pop(1); // drop: args

        try func_map.put(name, .{
            .returns_type = returns_type,
            .args_type = args,
        });
    }

    const ptr = L.newUserdataDtor(LuaHandle, LuaHandle.__dtor);
    L.setUserdataTag(-1, LuaHandle.tag);

    if (L.getMetatableRegistry(LuaHandle.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (FFI Metatable not initialized)", .{});

    var ffi_func_map = std.StringArrayHashMap(ffi.CallableFunction).init(allocator);

    ptr.* = .{ .lib = undefined, .open = false, .declared = ffi_func_map };

    var lib = try std.DynLib.open(path);

    ptr.* = .{ .lib = lib, .open = true, .declared = ffi_func_map };

    {
        errdefer {
            var iter = ffi_func_map.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
        }
        var iter = func_map.iterator();
        while (iter.next()) |entry| {
            const namez = try allocator.dupeZ(u8, entry.key_ptr.*);
            defer allocator.free(namez);
            const func = lib.lookup(*anyopaque, namez) orelse {
                std.debug.print("Symbol not found: {s}\n", .{entry.key_ptr.*});
                return error.SymbolNotFound;
            };

            const symbol_returns = entry.value_ptr.returns_type;
            const symbol_args = entry.value_ptr.args_type;

            const args = try allocator.alloc(ffi.GenType, symbol_args.len);
            defer allocator.free(args);

            for (symbol_args, 0..) |arg, i|
                args[i] = .{ .ffiType = arg };

            var ffi_callback = try ffi.CallableFunction.init(allocator, func, args, .{ .ffiType = symbol_returns });
            errdefer ffi_callback.deinit();

            // Zig owned string to prevent GC from Lua owned strings
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try ffi_func_map.put(key, ffi_callback);
        }
    }

    ptr.declared = ffi_func_map;

    return 1;
}

// fn ffi_dlclose(L: *Luau) i32 {
//     L.checkType(1, .userdata);
//     const ptr = L.toUserdataTagged(LuaHandle, 1, LuaHandle.tag) catch L.raiseErrorStr("Invalid handle", .{});

//     ptr.__dtor();

//     return 0;
// }

fn ffi_intFromPtr(L: *Luau) i32 {
    const dest = L.checkBuffer(1);
    if (@sizeOf(usize) != dest.len)
        L.raiseErrorStr("Invalid buffer size", .{});

    const source = L.checkBuffer(2);

    const bytes: [@sizeOf(usize)]u8 = @bitCast(@intFromPtr(source.ptr));

    @memcpy(dest, bytes[0..@sizeOf(usize)]);

    L.pushValue(1);

    return 1;
}

fn ffi_writeIntoPtr(L: *Luau) !i32 {
    const dest = L.checkBuffer(1);
    const dest_offset: usize = @intCast(L.checkInteger(2));
    const source = L.checkBuffer(3);
    const source_offset: usize = @intCast(L.checkInteger(4));
    const len: usize = @intCast(L.checkInteger(5));

    if (source_offset + len > source.len)
        L.raiseErrorStr("Invalid buffer size", .{});

    const target: [*]u8 = @ptrFromInt(std.mem.readVarInt(usize, dest, .little));

    @memcpy(target[dest_offset .. dest_offset + len], source[source_offset .. source_offset + len]);

    return 0;
}

fn ffi_valueFromPtr(L: *Luau) !i32 {
    const buf = L.checkBuffer(1);
    if (@sizeOf(usize) != buf.len)
        L.raiseErrorStr("Invalid buffer size", .{});

    const t = try convertToFFIType(L.checkInteger(2));
    if (t == .void)
        L.raiseErrorStr("Void type not supported", .{});

    const ptr: [*]u8 = @ptrFromInt(std.mem.readVarInt(usize, buf, .little));

    switch (t) {
        .i8 => L.pushInteger(@intCast(@as(i8, @intCast(ptr[0])))),
        .u8 => L.pushInteger(@intCast(ptr[0])),
        .i16 => L.pushInteger(@intCast(std.mem.readVarInt(i16, ptr[0..2], .little))),
        .u16 => L.pushInteger(@intCast(std.mem.readVarInt(u16, ptr[0..2], .little))),
        .i32 => L.pushInteger(@intCast(std.mem.readVarInt(i32, ptr[0..4], .little))),
        .u32 => L.pushInteger(@intCast(std.mem.readVarInt(u32, ptr[0..4], .little))),
        .i64 => try L.pushBuffer(ptr[0..8]),
        .u64 => try L.pushBuffer(ptr[0..8]),
        .float => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, ptr[0..4], .little))))),
        .double => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, ptr[0..8], .little)))),
        .pointer => {
            const bytes: [@sizeOf(usize)]u8 = @bitCast(@intFromPtr(@as(*[*]u8, @alignCast(@ptrCast(ptr))).*));
            try L.pushBuffer(bytes[0..@sizeOf(usize)]);
        },
        else => L.raiseErrorStr("Invalid type", .{}),
    }

    return 1;
}

fn ffi_eqlPtr(L: *Luau) i32 {
    const ptr1 = L.checkBuffer(1);
    const ptr2 = L.checkBuffer(2);

    const res = blk: {
        if (ptr1.len != ptr2.len)
            break :blk false;

        if (@sizeOf(usize) != ptr1.len)
            break :blk false;

        break :blk std.mem.eql(u8, ptr1, ptr2);
    };

    L.pushBoolean(res);

    return 1;
}

fn ffi_sizeOf(L: *Luau) !i32 {
    const t = try convertToFFIType(L.checkInteger(1));
    L.pushInteger(@intCast(t.toSize()));
    return 1;
}

fn ffi_alignOf(L: *Luau) i32 {
    L.raiseErrorStr("ffi struct alignment not supported, yet", .{});
    return 0;
}

fn ffi_unsupported(L: *Luau) i32 {
    L.raiseErrorStr("ffi is not supported on this platform", .{});
    return 0;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaHandle.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaHandle.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaHandle.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newTable();

    if (ffi.Supported()) {
        L.setFieldFn(-1, "dlopen", ffi_dlopen);
        L.setFieldBoolean(-1, "supported", true);
    } else {
        L.setFieldFn(-1, "dlopen", ffi_unsupported);
        L.setFieldBoolean(-1, "supported", false);
    }

    L.setFieldFn(-1, "intFromPtr", ffi_intFromPtr);
    L.setFieldFn(-1, "writeIntoPtr", ffi_writeIntoPtr);
    L.setFieldFn(-1, "valueFromPtr", ffi_valueFromPtr);
    L.setFieldFn(-1, "eqlPtr", ffi_eqlPtr);
    L.setFieldFn(-1, "sizeOf", ffi_sizeOf);
    L.setFieldFn(-1, "alignOf", ffi_alignOf);

    L.newTable();
    inline for (std.meta.fields(ffi.Type)) |field| {
        if (comptime std.mem.eql(u8, field.name, "unknownReturn"))
            continue;
        L.pushString(field.name);
        L.pushInteger(field.value);
        L.setTable(-3);
    }
    L.setField(-2, "types");

    switch (builtin.os.tag) {
        .linux => L.pushString("so"),
        .macos => L.pushString("dylib"),
        .windows => L.pushString("dll"),
        else => L.pushString(""),
    }
    L.setField(-2, "suffix");

    switch (builtin.os.tag) {
        .windows => L.pushString(""),
        else => L.pushString("lib"),
    }
    L.setField(-2, "prefix");

    luaHelper.registerModule(L, LIB_NAME);
}

test "ffi" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"ffi.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total >= 0);
}
