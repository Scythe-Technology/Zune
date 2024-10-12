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

    pub fn call_ffi(L: *Luau) !i32 {
        const index_idx = Luau.upvalueIndex(1);
        const ptr_idx = Luau.upvalueIndex(2);

        const index = L.checkString(index_idx);
        const ptr = L.toUserdata(LuaHandle, ptr_idx) catch L.raiseErrorStr("Invalid handle", .{});

        const allocator = L.allocator();

        const entry = ptr.declared.getEntry(index) orelse std.debug.panic("FFI not found", .{});

        const ffi_func = entry.value_ptr;

        if (@as(usize, @intCast(L.getTop())) != ffi_func.argTypes.len - 1)
            L.raiseErrorStr("Invalid number of arguments", .{});

        const args = try allocator.alloc(*anyopaque, ffi_func.argTypes.len - 1);

        var alloclen: usize = 0;
        defer allocator.free(args);
        defer free_ffi_args(allocator, L, ffi_func, 1, args, &alloclen);

        try load_ffi_args(allocator, L, ffi_func, 1, args, &alloclen);

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
            },
            .structType => try L.pushBuffer(ret),
        }

        return 1;
    }

    pub fn __index(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const index = L.checkString(2);
        const ptr = L.toUserdata(LuaHandle, 1) catch L.raiseErrorStr("Invalid handle", .{});

        _ = ptr.declared.get(index) orelse L.raiseErrorStr("Unknown ffi member: %s\n", .{index.ptr});

        L.pushValue(2);
        L.pushValue(1);
        L.pushClosure(luau.EFntoZigFn(call_ffi), "ffi_func", 2);

        return 1;
    }

    pub fn __namecall(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaHandle, 1) catch L.raiseErrorStr("Invalid handle", .{});

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

const LuaClosure = struct {
    closure: *ffi.CallbackClosure,
    args: std.ArrayList(ffi.GenType),
    returns: ffi.GenType,
    thread: *Luau,

    pub fn __dtor(ptr: *LuaClosure) void {
        ptr.closure.deinit();
        ptr.args.deinit();
        ptr.args.allocator.destroy(ptr.closure);
    }
};

const LuaStructType = struct {
    type: ffi.Struct,
    fields: std.StringArrayHashMap(ffi.GenType),

    pub const META = "ffi_struct_type";

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaStructType, 1) catch L.raiseErrorStr("Invalid struct", .{});

        const namecall = L.nameCallAtom() catch return 0;

        if (std.mem.eql(u8, namecall, "size")) {
            L.pushInteger(@intCast(ptr.type.getSize()));
            return 1;
        } else if (std.mem.eql(u8, namecall, "alignment")) {
            L.pushInteger(@intCast(ptr.type.getAlignment()));
            return 1;
        } else if (std.mem.eql(u8, namecall, "offset")) {
            const field = L.checkString(2);
            const order = ptr.fields.getIndex(field) orelse L.raiseErrorStr("Unknown field: %s\n", .{field.ptr});
            L.pushInteger(@intCast(ptr.type.offsets[order]));
            return 1;
        } else if (std.mem.eql(u8, namecall, "new")) {
            L.checkType(2, .table);
            const allocator = L.allocator();

            const mem = try allocator.alloc(u8, ptr.type.getSize());
            defer allocator.free(mem);

            @memset(mem, 0);

            for (ptr.fields.keys(), 0..) |field, order| {
                defer L.pop(1);
                L.pushLString(field);
                if (luau.isNoneOrNil(L.getTable(2)))
                    return error.MissingField;
                const offset = ptr.type.offsets[order];

                switch (ptr.fields.get(field) orelse unreachable) {
                    .ffiType => |t| {
                        switch (t) {
                            .void => return error.VoidArg,
                            .i8 => {
                                switch (L.typeOf(-1)) {
                                    .number => {
                                        const value = L.toInteger(-1) catch unreachable;
                                        if (value < -128 or value > 127)
                                            return error.OutOfRange;
                                        var bytes: [1]u8 = @bitCast(@as(i8, @intCast(value)));
                                        @memcpy(mem[offset .. offset + 1], &bytes);
                                    },
                                    .boolean => {
                                        var bytes: [1]u8 = @bitCast(@as(i8, if (L.toBoolean(-1)) 1 else 0));
                                        @memcpy(mem[offset .. offset + 1], &bytes);
                                    },
                                    else => return error.InvalidArgType,
                                }
                            },
                            .u8 => {
                                switch (L.typeOf(-1)) {
                                    .number => {
                                        const value = L.toInteger(-1) catch unreachable;
                                        if (value < 0 or value > 255)
                                            return error.OutOfRange;
                                        var bytes: [1]u8 = @bitCast(@as(u8, @intCast(value)));
                                        @memcpy(mem[offset .. offset + 1], &bytes);
                                    },
                                    .boolean => {
                                        var bytes: [1]u8 = @bitCast(@as(u8, if (L.toBoolean(-1)) 1 else 0));
                                        @memcpy(mem[offset .. offset + 1], &bytes);
                                    },
                                    else => return error.InvalidArgType,
                                }
                            },
                            .i16 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                if (value < -32768 or value > 32767)
                                    return error.OutOfRange;
                                var bytes: [2]u8 = @bitCast(@as(i16, @intCast(value)));
                                @memcpy(mem[offset .. offset + 2], &bytes);
                            },
                            .u16 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                if (value < 0 or value > 65535)
                                    return error.OutOfRange;
                                var bytes: [2]u8 = @bitCast(@as(u16, @intCast(value)));
                                @memcpy(mem[offset .. offset + 2], &bytes);
                            },
                            .i32 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                var bytes: [4]u8 = @bitCast(@as(i32, @intCast(value)));
                                @memcpy(mem[offset .. offset + 4], &bytes);
                            },
                            .u32 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                var bytes: [4]u8 = @bitCast(@as(u32, @intCast(value)));
                                @memcpy(mem[offset .. offset + 4], &bytes);
                            },
                            .i64 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                var bytes: [8]u8 = @bitCast(@as(i64, @intCast(value)));
                                @memcpy(mem[offset .. offset + 8], &bytes);
                            },
                            .u64 => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toInteger(-1) catch unreachable;
                                var bytes: [8]u8 = @bitCast(@as(u64, @intCast(value)));
                                @memcpy(mem[offset .. offset + 8], &bytes);
                            },
                            .float => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toNumber(-1) catch unreachable;
                                const large: u64 = @bitCast(value);
                                if (large >= 0x7f800000 and large <= 0x7fffffff)
                                    return error.OutOfRange;
                                var bytes: [4]u8 = @bitCast(@as(f32, @floatCast(value)));
                                @memcpy(mem[offset .. offset + 4], &bytes);
                            },
                            .double => {
                                if (L.typeOf(-1) != .number)
                                    return error.InvalidArgType;
                                const value = L.toNumber(-1) catch unreachable;
                                var bytes: [8]u8 = @bitCast(value);
                                @memcpy(mem[offset .. offset + 8], &bytes);
                            },
                            .pointer => {
                                switch (L.typeOf(-1)) {
                                    .buffer => {
                                        const buf = L.toBuffer(-1) catch unreachable;
                                        if (buf.len != @sizeOf(usize))
                                            return error.InvalidArgType;
                                        const ptr_int = std.mem.readVarInt(usize, buf, .little);
                                        var bytes: [@sizeOf(usize)]u8 = @bitCast(ptr_int);
                                        @memcpy(mem[offset .. offset + @sizeOf(usize)], &bytes);
                                    },
                                    else => return error.InvalidArgType,
                                }
                            },
                        }
                    },
                    .structType => |t| {
                        if (L.typeOf(-1) != .buffer)
                            return error.InvalidArgType;
                        const value = L.toBuffer(-1) catch unreachable;
                        if (value.len != t.getSize())
                            return error.InvalidArgType;
                        @memcpy(mem[offset .. offset + t.getSize()], value);
                    },
                }
            }

            try L.pushBuffer(mem);

            return 1;
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    pub fn __dtor(ptr: *LuaStructType) void {
        var iter = ptr.fields.iterator();
        while (iter.next()) |entry|
            ptr.fields.allocator.free(entry.key_ptr.*);
        ptr.fields.deinit();
        ptr.type.deinit();
    }
};

const SymbolFunction = struct {
    returns_type: ffi.GenType,
    args_type: []ffi.GenType,
};

const FFITypeSize = std.meta.fields(ffi.Type).len;
fn convertToFFIType(number: i32) !ffi.Type {
    if (number < 0 or @as(u32, @intCast(number)) > FFITypeSize)
        return error.InvalidReturnType;
    return @enumFromInt(number);
}

fn isFFIType(L: *Luau, idx: i32) bool {
    switch (L.typeOf(idx)) {
        .number => {
            const n = L.toInteger(idx) catch unreachable;
            return n >= 0 and @as(u32, @intCast(n)) < FFITypeSize;
        },
        .userdata => return is_ffi_struct(L, idx),
        else => return false,
    }
}

fn toFFIType(L: *Luau, idx: i32) !ffi.GenType {
    switch (L.typeOf(idx)) {
        .number => return .{
            .ffiType = try convertToFFIType(L.toInteger(idx) catch unreachable),
        },
        .userdata => {
            const lua_struct = L.toUserdata(LuaStructType, idx) catch unreachable;
            return .{
                .structType = lua_struct.*.type,
            };
        },
        else => return error.InvalidType,
    }
}

fn load_ffi_args(
    allocator: std.mem.Allocator,
    L: *Luau,
    ffi_func: *ffi.CallableFunction,
    start_idx: usize,
    args: []*anyopaque,
    allocatedLen: *usize,
) !void {
    for (0..args.len) |i| {
        const lua_index: i32 = @intCast(start_idx + i);
        if (ffi.toffiType(ffi_func.argTypes[i])) |t| switch (t) {
            .void => std.debug.panic("Void arg", .{}),
            .i8 => {
                switch (L.typeOf(lua_index)) {
                    .number => {
                        const value = L.toInteger(lua_index) catch unreachable;
                        if (value < -128 or value > 127)
                            return error.OutOfRange;
                        const v_ptr = try allocator.create(i8);
                        v_ptr.* = @intCast(value);
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    .boolean => {
                        const v_ptr = try allocator.create(i8);
                        v_ptr.* = if (L.toBoolean(lua_index)) 1 else 0;
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    else => return error.InvalidArgType,
                }
            },
            .u8 => {
                switch (L.typeOf(lua_index)) {
                    .number => {
                        const value = L.toInteger(lua_index) catch unreachable;
                        if (value < 0 or value > 255)
                            return error.OutOfRange;
                        const v_ptr = try allocator.create(u8);
                        v_ptr.* = @intCast(value);
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    .boolean => {
                        const v_ptr = try allocator.create(u8);
                        v_ptr.* = if (L.toBoolean(lua_index)) 1 else 0;
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    else => return error.InvalidArgType,
                }
            },
            .i16 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const value = L.toInteger(lua_index) catch unreachable;
                if (value < -32768 or value > 32767)
                    return error.OutOfRange;
                const v_ptr = try allocator.create(i16);
                v_ptr.* = @intCast(value);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .u16 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const value = L.toInteger(lua_index) catch unreachable;
                if (value < 0 or value > 65535)
                    return error.OutOfRange;
                const v_ptr = try allocator.create(u16);
                v_ptr.* = @intCast(value);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .i32 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const v_ptr = try allocator.create(i32);
                v_ptr.* = @intCast(L.toInteger(lua_index) catch unreachable);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .u32 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const v_ptr = try allocator.create(u32);
                v_ptr.* = @intCast(L.toInteger(lua_index) catch unreachable);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .i64 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const v_ptr = try allocator.create(i64);
                v_ptr.* = @intCast(L.toInteger(lua_index) catch unreachable);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .u64 => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const v_ptr = try allocator.create(u64);
                v_ptr.* = @intCast(L.toInteger(lua_index) catch unreachable);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .float => {
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                const value = L.toNumber(lua_index) catch unreachable;
                const large: u64 = @bitCast(value);
                if (large >= 0x7f800000 and large <= 0x7fffffff)
                    return error.OutOfRange;
                const v_ptr = try allocator.create(f32);
                v_ptr.* = @floatCast(value);
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .double => {
                const v_ptr = try allocator.create(f64);
                if (L.typeOf(lua_index) != .number)
                    return error.InvalidArgType;
                v_ptr.* = L.toNumber(lua_index) catch unreachable;
                args[i] = @alignCast(@ptrCast(v_ptr));
            },
            .pointer => {
                switch (L.typeOf(lua_index)) {
                    .userdata => {
                        return error.InvalidArgType;
                    },
                    .buffer => {
                        const buf = L.toBuffer(lua_index) catch unreachable;
                        if (buf.len != @sizeOf(usize))
                            return error.InvalidArgType;
                        const ptr_int = std.mem.readVarInt(usize, buf, .little);
                        if (ptr_int == 0)
                            return error.NullPtr;
                        const v_ptr = try allocator.create(*anyopaque);
                        v_ptr.* = @ptrFromInt(ptr_int);
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    .string => {
                        const str: [:0]const u8 = L.toString(lua_index) catch unreachable;
                        const dup = try allocator.dupeZ(u8, str);
                        errdefer allocator.free(dup);
                        const v_ptr = try allocator.create(*anyopaque);
                        v_ptr.* = @ptrCast(dup.ptr);
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    .nil => {
                        const v_ptr = try allocator.create(?*anyopaque);
                        v_ptr.* = null;
                        args[i] = @alignCast(@ptrCast(v_ptr));
                    },
                    else => return error.InvalidArgType,
                }
            },
        } else {
            if (L.typeOf(lua_index) != .buffer)
                return error.InvalidArgType;
            const buf = L.toBuffer(lua_index) catch unreachable;
            if (buf.len != ffi_func.argTypes[i].*.size)
                return error.InvalidStructSize;
            const mem = try allocator.dupe(u8, buf);
            errdefer allocator.free(mem);
            args[i] = @alignCast(@ptrCast(mem.ptr));
        }
        allocatedLen.* += 1;
    }
}

fn free_ffi_args(
    allocator: std.mem.Allocator,
    L: *Luau,
    ffi_func: *ffi.CallableFunction,
    start_idx: usize,
    args: []*anyopaque,
    allocatedLen: *const usize,
) void {
    for (0..allocatedLen.*) |i| {
        const lua_index: i32 = @intCast(start_idx + i);
        if (ffi.toffiType(ffi_func.argTypes[i])) |t| switch (t) {
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
            .pointer => {
                const ptr_value = @as(**anyopaque, @alignCast(@ptrCast(args[i])));
                switch (L.typeOf(lua_index)) {
                    .string => {
                        const str = L.toString(lua_index) catch unreachable;
                        const dup: [*c]u8 = @ptrCast(ptr_value.*);
                        allocator.free(@as([:0]const u8, dup[0..str.len :0]));
                    },
                    else => {},
                }
                allocator.destroy(ptr_value);
            },
        } else {
            const mem: [*]u8 = @alignCast(@ptrCast(args[i]));
            const len = ffi_func.argTypes[i].*.size;
            allocator.free(mem[0..len]);
        }
    }
}

fn ffi_struct(L: *Luau) !i32 {
    L.checkType(1, .table);

    const allocator = L.allocator();

    var struct_map = std.StringArrayHashMap(ffi.GenType).init(allocator);
    errdefer struct_map.deinit();
    errdefer {
        var iter = struct_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
    }

    var order: i32 = 1;
    L.pushNil();
    while (L.next(1)) {
        if (L.typeOf(-2) != .number)
            return error.InvalidIndex;
        const index = L.toInteger(-2) catch unreachable;
        if (index != order)
            return error.InvalidIndexOrder;

        if (L.typeOf(-1) != .table)
            return error.InvalidValue;

        L.pushNil();
        if (!L.next(-2))
            return error.InvalidValue;

        if (L.typeOf(-2) != .string)
            return error.InvalidFieldName;
        const name = L.toString(-2) catch unreachable;

        if (!isFFIType(L, -1))
            return error.InvalidFieldType;

        {
            const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
            errdefer allocator.free(name_copy);
            try struct_map.put(name_copy, try toFFIType(L, -1));
        }

        L.pop(1);

        if (L.next(-2))
            return error.ExtraFieldsFound;

        order += 1;
        L.pop(1);
    }

    const data = L.newUserdataDtor(LuaStructType, LuaStructType.__dtor);

    if (L.getMetatableRegistry(LuaStructType.META) == .table)
        L.setMetatable(-2)
    else
        std.debug.panic("InternalError (FFI Metatable not initialized)", .{});

    data.* = .{
        .type = try ffi.Struct.init(allocator, struct_map.values()),
        .fields = struct_map,
    };

    return 1;
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

        _ = L.getField(-1, "returns");
        if (!isFFIType(L, -1))
            return error.InvalidReturnType;
        const returns_ffi_type = try toFFIType(L, -1);
        L.pop(1); // drop: returns

        if (L.getField(-1, "args") != .table)
            return error.InvalidArgs;

        const args_len = L.objLen(-1);

        const args = try allocator.alloc(ffi.GenType, @intCast(args_len));
        errdefer allocator.free(args);

        var order: usize = 0;
        L.pushNil();
        while (L.next(-2)) : (L.pop(1)) {
            if (L.typeOf(-2) != .number)
                return error.InvalidArgOrder;
            if (!isFFIType(L, -1))
                return error.InvalidArgType;

            const index = L.toInteger(-2) catch unreachable;
            if (index != order + 1)
                return error.InvalidArgOrder;

            args[order] = try toFFIType(L, -1);
            if (args[order] == .ffiType and args[order].ffiType == .void)
                return error.VoidArg;
            order += 1;
        }
        L.pop(1); // drop: args

        try func_map.put(name, .{
            .returns_type = returns_ffi_type,
            .args_type = args,
        });
    }

    const ptr = L.newUserdataDtor(LuaHandle, LuaHandle.__dtor);

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
                args[i] = arg;

            var ffi_callback = try ffi.CallableFunction.init(allocator, func, args, symbol_returns);
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

fn ffi_closure(L: *Luau) !i32 {
    L.checkType(1, .table);
    L.checkType(2, .function);

    const allocator = L.allocator();

    var returns: ffi.GenType = .{ .ffiType = .void };
    var args = std.ArrayList(ffi.GenType).init(allocator);
    errdefer args.deinit();

    _ = L.getField(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    returns = try toFFIType(L, -1);
    L.pop(1);

    if (L.getField(1, "args") != .table)
        return error.InvalidArgs;

    var order: usize = 0;
    L.pushNil();
    while (L.next(-2)) {
        if (L.typeOf(-2) != .number)
            return error.InvalidArgOrder;
        if (!isFFIType(L, -1))
            return error.InvalidArgType;

        const index = L.toInteger(-2) catch unreachable;
        if (index != order + 1)
            return error.InvalidArgOrder;

        const t = try toFFIType(L, -1);

        if (t == .ffiType and t.ffiType == .void)
            return error.VoidArg;

        try args.append(t);

        order += 1;
        L.pop(1);
    }

    const callback_handler = struct {
        fn inner(cif: ffi.CallInfo, ffi_args: []?*anyopaque, ffi_ret: ?*anyopaque, ud: ?*anyopaque) void {
            if (ud == null)
                std.debug.panic("Invalid userdata", .{});
            const data = @as(*LuaClosure, @alignCast(@ptrCast(ud.?)));
            if (cif.nargs != data.args.items.len)
                std.debug.panic("Invalid number of arguments", .{});

            data.thread.pushValue(1);

            for (data.args.items, 0..) |arg_type, i| {
                switch (arg_type) {
                    .ffiType => |t| switch (t) {
                        .void => unreachable,
                        .i8 => data.thread.pushInteger(@intCast(@as(*i8, @ptrCast(ffi_args[i])).*)),
                        .u8 => data.thread.pushInteger(@intCast(@as(*u8, @ptrCast(ffi_args[i])).*)),
                        .i16 => data.thread.pushInteger(@intCast(@as(*i16, @alignCast(@ptrCast(ffi_args[i]))).*)),
                        .u16 => data.thread.pushInteger(@intCast(@as(*u16, @alignCast(@ptrCast(ffi_args[i]))).*)),
                        .i32 => data.thread.pushInteger(@as(*i32, @alignCast(@ptrCast(ffi_args[i]))).*),
                        .u32 => data.thread.pushInteger(@intCast(@as(*u32, @alignCast(@ptrCast(ffi_args[i]))).*)),
                        .i64 => {
                            const bytes: [8]u8 = @bitCast(@as(*i64, @alignCast(@ptrCast(ffi_args[i]))).*);
                            data.thread.pushBuffer(&bytes) catch |err| std.debug.panic("Failed: {}", .{err});
                        },
                        .u64 => {
                            const bytes: [8]u8 = @bitCast(@as(*u64, @alignCast(@ptrCast(ffi_args[i]))).*);
                            data.thread.pushBuffer(&bytes) catch |err| std.debug.panic("Failed: {}", .{err});
                        },
                        .float => data.thread.pushNumber(@floatCast(@as(f32, @bitCast(@as(*u32, @alignCast(@ptrCast(ffi_args[i]))).*)))),
                        .double => data.thread.pushNumber(@as(f64, @bitCast(@as(*u64, @alignCast(@ptrCast(ffi_args[i]))).*))),
                        .pointer => {
                            const bytes: [@sizeOf(usize)]u8 = @bitCast(@intFromPtr(@as(*[*]u8, @alignCast(@ptrCast(ffi_args[i]))).*));
                            data.thread.pushBuffer(bytes[0..@sizeOf(usize)]) catch |err| std.debug.panic("Failed: {}", .{err});
                        },
                    },
                    .structType => |t| {
                        const bytes: *[*]u8 = @alignCast(@ptrCast(ffi_args[i]));
                        data.thread.pushBuffer(bytes.*[0..t.getSize()]) catch |err| std.debug.panic("Failed: {}", .{err});
                    },
                }
            }

            const has_return = if (data.returns == .ffiType and data.returns.ffiType == .void) false else true;

            data.thread.pcall(@intCast(data.args.items.len), if (has_return) 1 else 0, 0) catch {
                std.debug.panic("C Closure Runtime Error: {s}", .{data.thread.toString(-1) catch "UnknownError"});
            };

            if (has_return) {
                defer data.thread.pop(1);
                if (ffi_ret) |ret_ptr| {
                    switch (data.returns) {
                        .ffiType => |t| switch (t) {
                            .void => unreachable,
                            .i8 => {
                                switch (data.thread.typeOf(-1)) {
                                    .number => {
                                        const value = data.thread.toInteger(-1) catch unreachable;
                                        if (value < -128 or value > 127)
                                            return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                        @as(*i8, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                    },
                                    .boolean => {
                                        @as(*i8, @ptrCast(@alignCast(ret_ptr))).* = if (data.thread.toBoolean(-1)) 1 else 0;
                                    },
                                    else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                                }
                            },
                            .u8 => {
                                switch (data.thread.typeOf(-1)) {
                                    .number => {
                                        const value = data.thread.toInteger(-1) catch unreachable;
                                        if (value < 0 or value > 255)
                                            return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                        @as(*u8, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                    },
                                    .boolean => {
                                        @as(*u8, @ptrCast(@alignCast(ret_ptr))).* = if (data.thread.toBoolean(-1)) 1 else 0;
                                    },
                                    else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                                }
                            },
                            .i16 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                const value = data.thread.toInteger(-1) catch unreachable;
                                if (value < -32768 or value > 32767)
                                    return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                @as(*i16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                            },
                            .u16 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                const value = data.thread.toInteger(-1) catch unreachable;
                                if (value < 0 or value > 65535)
                                    return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                @as(*u16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                            },
                            .i32 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                @as(*i32, @ptrCast(@alignCast(ret_ptr))).* = @intCast(data.thread.toInteger(-1) catch unreachable);
                            },
                            .u32 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                @as(*u32, @ptrCast(@alignCast(ret_ptr))).* = @intCast(data.thread.toInteger(-1) catch unreachable);
                            },
                            .i64 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                @as(*i64, @ptrCast(@alignCast(ret_ptr))).* = @intCast(data.thread.toInteger(-1) catch unreachable);
                            },
                            .u64 => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                @as(*u64, @ptrCast(@alignCast(ret_ptr))).* = @intCast(data.thread.toInteger(-1) catch unreachable);
                            },
                            .float => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                const value = data.thread.toNumber(-1) catch unreachable;
                                const large: u64 = @bitCast(value);
                                if (large >= 0x7f800000 and large <= 0x7fffffff)
                                    return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                @as(*f32, @ptrCast(@alignCast(ret_ptr))).* = @floatCast(value);
                            },
                            .double => {
                                if (data.thread.typeOf(-1) != .number)
                                    return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)});
                                @as(*f64, @ptrCast(@alignCast(ret_ptr))).* = data.thread.toNumber(-1) catch unreachable;
                            },
                            .pointer => {
                                switch (data.thread.typeOf(-1)) {
                                    .buffer => {
                                        const buf = data.thread.toBuffer(-1) catch unreachable;
                                        if (buf.len != @sizeOf(usize))
                                            return std.debug.panic("Invalid return type (expected buffer of size {d} for '{s}')", .{ @sizeOf(usize), @tagName(t) });
                                        const ptr_int = std.mem.readVarInt(usize, buf, .little);
                                        if (ptr_int == 0)
                                            return std.debug.panic("Null pointer", .{});
                                        @as(*[*]u8, @ptrCast(@alignCast(ret_ptr))).* = @ptrFromInt(ptr_int);
                                    },
                                    .string => std.debug.panic("Unsupported return type (use a pointer to a buffer instead)", .{}),
                                    .nil => {
                                        @as(*?*anyopaque, @ptrCast(@alignCast(ret_ptr))).* = null;
                                    },
                                    else => return std.debug.panic("Invalid return type (expected buffer/nil for '{s}')", .{@tagName(t)}),
                                }
                            },
                        },
                        .structType => |t| {
                            if (data.thread.typeOf(-1) != .buffer)
                                return std.debug.panic("Invalid return type (expected buffer for struct)", .{});
                            const buf = data.thread.toBuffer(-1) catch unreachable;
                            if (buf.len != t.getSize())
                                return std.debug.panic("Invalid return type (expected buffer of size {d} for struct)", .{t.getSize()});
                            @memcpy(@as(*[*]u8, @ptrCast(@alignCast(ret_ptr))).*, buf);
                        },
                    }
                }
            }
        }
    }.inner;

    const closure_ptr = try allocator.create(ffi.CallbackClosure);
    {
        errdefer allocator.destroy(closure_ptr);

        closure_ptr.* = try ffi.CallbackClosure.init(allocator, ffi.toCClosureFn(callback_handler), args.items, returns);
    }

    const thread = L.newThread();
    L.xPush(thread, 2);

    const data = L.newUserdataDtor(LuaClosure, LuaClosure.__dtor);

    data.* = .{
        .args = args,
        .closure = closure_ptr,
        .returns = returns,
        .thread = thread,
    };

    try closure_ptr.prep(data);

    L.newTable();

    L.newTable();
    const bytes: [@sizeOf(usize)]u8 = @bitCast(@intFromPtr(closure_ptr.executable));
    try L.pushBuffer(&bytes);
    L.setField(-2, "ptr");
    L.setField(-2, luau.Metamethods.index);

    L.setMetatable(-2);

    return 1;
}

fn ffi_call(L: *Luau) !i32 {
    L.checkType(1, .table);
    const src = L.checkBuffer(2);
    if (@sizeOf(usize) != src.len)
        return error.InvalidBuffer;

    const ptr: *anyopaque = @ptrFromInt(std.mem.readVarInt(usize, src, .little));

    const allocator = L.allocator();

    var returns: ffi.GenType = .{ .ffiType = .void };
    var args = std.ArrayList(ffi.GenType).init(allocator);
    defer args.deinit();

    _ = L.getField(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    returns = try toFFIType(L, -1);
    L.pop(1);

    if (L.getField(1, "args") != .table)
        return error.InvalidArgs;

    var order: usize = 0;
    L.pushNil();
    while (L.next(-2)) {
        if (L.typeOf(-2) != .number)
            return error.InvalidArgOrder;
        if (!isFFIType(L, -1))
            return error.InvalidArgType;

        const index = L.toInteger(-2) catch unreachable;
        if (index != order + 1)
            return error.InvalidArgOrder;

        const t = try toFFIType(L, -1);

        if (t == .ffiType and t.ffiType == .void)
            return error.VoidArg;

        try args.append(t);

        order += 1;
        L.pop(1);
    }

    var ffi_func = try ffi.CallableFunction.init(allocator, ptr, args.items, returns);
    defer ffi_func.deinit();

    const ffi_args = try allocator.alloc(*anyopaque, ffi_func.argTypes.len - 1);

    var alloclen: usize = 0;
    defer allocator.free(ffi_args);
    defer free_ffi_args(allocator, L, &ffi_func, 3, ffi_args, &alloclen);

    try load_ffi_args(allocator, L, &ffi_func, 3, ffi_args, &alloclen);

    const ret = try ffi_func.call(ffi_args);
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
        },
        .structType => try L.pushBuffer(ret),
    }
    return 1;
}

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

fn ffi_readFromPtr(L: *Luau) !i32 {
    const source = L.checkBuffer(1);
    const source_offset: usize = @intCast(L.checkInteger(2));
    const dest = L.checkBuffer(3);
    const dest_offset: usize = @intCast(L.checkInteger(4));
    const len: usize = @intCast(L.checkInteger(5));

    const target: [*]u8 = @ptrFromInt(std.mem.readVarInt(usize, source, .little));

    @memcpy(dest[dest_offset .. dest_offset + len], target[source_offset .. source_offset + len]);

    return 1;
}

fn ffi_spanFromPtr(L: *Luau) !i32 {
    const source = L.checkBuffer(1);
    const source_offset: usize = @intCast(L.checkInteger(2));

    const target: [*c]u8 = @ptrFromInt(std.mem.readVarInt(usize, source, .little));

    const bytes: [:0]const u8 = std.mem.span(target[source_offset..]);

    try L.pushBuffer(bytes);

    return 1;
}

fn ffi_valueFromPtr(L: *Luau) !i32 {
    const buf = L.checkBuffer(1);
    if (@sizeOf(usize) != buf.len)
        L.raiseErrorStr("Invalid buffer size", .{});

    if (!isFFIType(L, 2))
        L.raiseErrorStr("Invalid type", .{});

    const ffi_type = try toFFIType(L, 2);
    if (ffi_type == .ffiType and ffi_type.ffiType == .void)
        L.raiseErrorStr("Void type not supported", .{});

    const ptr: [*]u8 = @ptrFromInt(std.mem.readVarInt(usize, buf, .little));

    switch (ffi_type) {
        .ffiType => |t| switch (t) {
            .void => unreachable,
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
        },
        .structType => |t| {
            const mem = ptr[0..t.getSize()];
            try L.pushBuffer(mem);
        },
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
    const t = try toFFIType(L, 1);
    L.pushInteger(@intCast(t.getSize()));
    return 1;
}

fn ffi_alignOf(L: *Luau) !i32 {
    const t = try toFFIType(L, 1);
    L.pushInteger(@intCast(t.getAlignment()));
    return 1;
}

fn ffi_unsupported(L: *Luau) i32 {
    L.raiseErrorStr("ffi is not supported on this platform", .{});
    return 0;
}

fn is_ffi_struct(L: *Luau, idx: i32) bool {
    if (L.typeOf(idx) != .userdata)
        return false;
    if (!L.getMetatable(idx))
        return false;
    defer L.pop(2);
    if (L.getMetatableRegistry(LuaStructType.META) != .table)
        std.debug.panic("InternalError (FFI Metatable not initialized)", .{});
    return L.equal(-2, -1);
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaHandle.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.index, LuaHandle.__index); // metatable.__index
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaHandle.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    {
        L.newMetatable(LuaStructType.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.namecall, LuaStructType.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }

    L.newTable();

    if (ffi.Supported()) {
        L.setFieldFn(-1, "dlopen", ffi_dlopen);
        L.setFieldFn(-1, "struct", ffi_struct);
        L.setFieldFn(-1, "closure", ffi_closure);
        L.setFieldFn(-1, "call", ffi_call);
        L.setFieldBoolean(-1, "supported", true);
    } else {
        L.setFieldFn(-1, "dlopen", ffi_unsupported);
        L.setFieldFn(-1, "struct", ffi_unsupported);
        L.setFieldFn(-1, "closure", ffi_unsupported);
        L.setFieldFn(-1, "call", ffi_unsupported);
        L.setFieldBoolean(-1, "supported", false);
    }

    L.setFieldFn(-1, "intFromPtr", ffi_intFromPtr);
    L.setFieldFn(-1, "writeIntoPtr", ffi_writeIntoPtr);
    L.setFieldFn(-1, "readFromPtr", ffi_readFromPtr);
    L.setFieldFn(-1, "spanFromPtr", ffi_spanFromPtr);
    L.setFieldFn(-1, "valueFromPtr", ffi_valueFromPtr);
    L.setFieldFn(-1, "eqlPtr", ffi_eqlPtr);
    L.setFieldFn(-1, "sizeOf", ffi_sizeOf);
    L.setFieldFn(-1, "alignOf", ffi_alignOf);

    L.newTable();
    inline for (std.meta.fields(ffi.Type)) |field| {
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
