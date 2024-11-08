const std = @import("std");
const ffi = @import("ffi");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");
const tagged = @import("../../tagged.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "ffi";

inline fn intOutOfRange(comptime T: type, value: anytype) bool {
    return value < std.math.minInt(T) or value > std.math.maxInt(T);
}

inline fn floatOutOfRange(comptime T: type, value: f64) bool {
    return value < -std.math.floatMax(T) or value > std.math.floatMax(T);
}

fn AsType(t: ffi.Type) type {
    return switch (t) {
        .void => void,
        .i8 => i8,
        .u8 => u8,
        .i16 => i16,
        .u16 => u16,
        .i32 => i32,
        .u32 => u32,
        .i64 => i64,
        .u64 => u64,
        .float => f32,
        .double => f64,
        .pointer => *anyopaque,
    };
}

const LuaPointer = struct {
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    size: ?usize = null,
    ref: ?i32 = null,
    local_ref: ?i32 = null,
    destroyed: bool,
    retained: bool = false,
    type: PointerType,

    pub const META = "ffi_pointer";

    pub const PointerType = enum {
        Allocated,
        Static,
    };

    pub fn ptrFromBuffer(L: *Luau) !i32 {
        const buf = L.checkBuffer(1);
        if (buf.len < @sizeOf(usize))
            return error.SmallBuffer;

        const ptr = L.newUserdataTagged(LuaPointer, tagged.FFI_POINTER);
        metatable(L);
        L.setMetatable(-2);

        ptr.* = .{
            .ptr = @ptrFromInt(std.mem.readVarInt(usize, buf[0..@sizeOf(usize)], .little)),
            .allocator = L.allocator(),
            .destroyed = false,
            .type = .Static,
        };

        return 1;
    }

    pub fn allocBlockPtr(L: *Luau, size: usize) !*LuaPointer {
        const allocator = L.allocator();

        const mem = try allocator.alloc(u8, size);
        @memset(mem, 0);

        const ptr = L.newUserdataTagged(LuaPointer, tagged.FFI_POINTER);
        metatable(L);
        L.setMetatable(-2);

        ptr.* = .{
            .ptr = @ptrCast(@alignCast(mem.ptr)),
            .allocator = allocator,
            .size = mem.len,
            .destroyed = false,
            .type = .Allocated,
        };

        try retain(ptr, L);

        return ptr;
    }

    pub fn newStaticPtr(L: *Luau, staticPtr: ?*anyopaque, default_retain: bool) !*LuaPointer {
        const ptr = L.newUserdataTagged(LuaPointer, tagged.FFI_POINTER);
        metatable(L);
        L.setMetatable(-2);

        ptr.* = .{
            .ptr = staticPtr,
            .allocator = L.allocator(),
            .destroyed = false,
            .type = .Static,
        };

        if (default_retain)
            try retain(ptr, L);

        return ptr;
    }

    pub fn newStaticPtrWithRef(L: *Luau, staticPtr: ?*anyopaque, idx: i32) !*LuaPointer {
        const ref = try L.ref(idx);

        const ptr = try newStaticPtr(L, staticPtr, true);

        ptr.ref = ref;

        return ptr;
    }

    pub fn getRef(L: *Luau) !i32 {
        const ref_ptr = try value(L, 1);
        const allocator = L.allocator();

        const ref = try L.ref(1);

        const ptr = L.newUserdataTagged(LuaPointer, tagged.FFI_POINTER);
        metatable(L);
        L.setMetatable(-2);

        const mem = try allocator.create(*anyopaque);
        mem.* = @ptrCast(@alignCast(ref_ptr.ptr));

        ptr.* = .{
            .ptr = @ptrCast(@alignCast(mem)),
            .allocator = allocator,
            .ref = ref,
            .destroyed = false,
            .type = .Allocated,
        };

        return 1;
    }

    pub fn retain(ptr: *LuaPointer, L: *Luau) !void {
        if (ptr.local_ref != null)
            return;
        const local = try L.ref(-1);
        ptr.retained = true;
        ptr.local_ref = local;
    }

    pub fn metatable(L: *Luau) void {
        if (L.getMetatableRegistry(META) != .table)
            std.debug.panic("InternalError (FFI Metatable not initialized)", .{});
    }

    pub inline fn is(L: *Luau, idx: i32) bool {
        return L.getUserdataTag(idx) == tagged.FFI_POINTER;
    }

    pub inline fn value(L: *Luau, idx: i32) !*LuaPointer {
        return L.toUserdataTagged(LuaPointer, idx, tagged.FFI_POINTER);
    }

    pub const NamecallMap = std.StaticStringMap(enum {
        Retain,
        Release,
        Drop,
        Offset,
        Read,
        Readi8,
        Readu8,
        Readi16,
        Readu16,
        Readi32,
        Readu32,
        Readi64,
        Readu64,
        Readf32,
        Readf64,
        ReadPtr,
        Write,
        Writei8,
        Writeu8,
        Writei16,
        Writeu16,
        Writei32,
        Writeu32,
        Writei64,
        Writeu64,
        Writef32,
        Writef64,
        WritePtr,
        IsNull,
        SetSize,
        Span,
    }).initComptime(.{
        .{ "retain", .Retain },
        .{ "release", .Release },
        .{ "drop", .Drop },
        .{ "offset", .Offset },
        .{ "read", .Read },
        .{ "write", .Write },
        .{ "readi8", .Readi8 },
        .{ "readu8", .Readu8 },
        .{ "readi16", .Readi16 },
        .{ "readu16", .Readu16 },
        .{ "readi32", .Readi32 },
        .{ "readu32", .Readu32 },
        .{ "readi64", .Readi64 },
        .{ "readu64", .Readu64 },
        .{ "readf32", .Readf32 },
        .{ "readf64", .Readf64 },
        .{ "readPtr", .ReadPtr },
        .{ "writei8", .Writei8 },
        .{ "writeu8", .Writeu8 },
        .{ "writei16", .Writei16 },
        .{ "writeu16", .Writeu16 },
        .{ "writei32", .Writei32 },
        .{ "writeu32", .Writeu32 },
        .{ "writei64", .Writei64 },
        .{ "writeu64", .Writeu64 },
        .{ "writef32", .Writef32 },
        .{ "writef64", .Writef64 },
        .{ "writePtr", .WritePtr },
        .{ "isNull", .IsNull },
        .{ "setSize", .SetSize },
        .{ "span", .Span },
    });

    pub fn method_retain(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        try retain(ptr, L);
        L.pushValue(1);
        return 1;
    }

    pub fn method_release(ptr: *LuaPointer, L: *Luau) i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        ptr.retained = false;
        const local_ref = ptr.local_ref orelse {
            L.pushValue(1);
            return 1;
        };
        L.unref(local_ref);
        ptr.local_ref = null;
        L.pushValue(1);
        return 1;
    }

    pub fn method_drop(ptr: *LuaPointer, L: *Luau) i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        if (ptr.type == .Static)
            L.raiseErrorStr("Cannot drop a static pointer", .{});
        ptr.destroyed = true;
        if (ptr.local_ref) |ref|
            L.unref(ref);
        ptr.local_ref = null;
        if (ptr.ref) |ref|
            L.unref(ref);
        ptr.ref = null;
        return 1;
    }

    pub fn method_offset(ptr: *LuaPointer, L: *Luau) !i32 {
        const offset: usize = @intCast(L.checkInteger(2));
        if (ptr.ptr == null) {
            _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(offset), false);
            return 1;
        }
        const static = try LuaPointer.newStaticPtr(L, @as([*]u8, @ptrCast(ptr.ptr))[offset..], false);

        if (ptr.size) |size| {
            if (size < offset)
                return L.raiseErrorStr("Offset OutOfBounds", .{});
            static.size = size - offset;
        }

        return 1;
    }

    pub fn method_read(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return error.NoAddressAvailable;

        const src_offset: usize = @intFromFloat(L.checkNumber(2));
        const dest_offset: usize = @intFromFloat(L.checkNumber(4));
        var dest_bounds: ?usize = null;
        const dest: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .buffer => {
                    const buf = L.toBuffer(3) catch unreachable;
                    dest_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .userdata => {
                    const other = try LuaPointer.value(L, 3);
                    if (other.destroyed or other.ptr == null)
                        return error.NoAddressAvailable;
                    dest_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
            }
        };
        const len: usize = @intCast(L.checkInteger(5));

        if (dest_bounds) |size| if (size < dest_offset + len)
            return L.raiseErrorStr("Target OutOfBounds", .{});

        if (ptr.size) |size| if (size < src_offset + len)
            return L.raiseErrorStr("Source OutOfBounds", .{});

        const src: [*]u8 = @ptrCast(@alignCast(ptr.ptr));

        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        L.pushValue(3);
        return 1;
    }

    pub fn method_write(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return error.NoAddressAvailable;

        const dest_offset: usize = @intCast(L.checkInteger(2));
        const src_offset: usize = @intFromFloat(L.checkNumber(4));
        var src_bounds: ?usize = null;
        const src: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .buffer => {
                    const buf = L.toBuffer(3) catch unreachable;
                    src_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .userdata => {
                    const other = try LuaPointer.value(L, 3);
                    if (other.destroyed or other.ptr == null)
                        return error.NoAddressAvailable;
                    src_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
            }
        };
        const len: usize = @intCast(L.checkInteger(5));

        if (ptr.size) |size| if (size < dest_offset + len)
            return L.raiseErrorStr("Target OutOfBounds", .{});

        if (src_bounds) |size| if (size < src_offset + len)
            return L.raiseErrorStr("Source OutOfBounds", .{});

        const dest: [*]u8 = @ptrCast(@alignCast(ptr.ptr));
        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        return 0;
    }

    pub fn GenerateReadMethod(comptime ffiType: ffi.Type) fn (ptr: *LuaPointer, L: *Luau) anyerror!i32 {
        return struct {
            fn inner(ptr: *LuaPointer, L: *Luau) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.optInteger(2) orelse 0);

                const len = ffiType.toSize();
                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: [*]u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset..];

                switch (ffiType) {
                    .void => unreachable,
                    .i8, .u8 => L.pushInteger(@intCast(@as(AsType(ffiType), @bitCast(mem[0])))),
                    .i16, .u16, .i32, .u32 => L.pushInteger(@intCast(std.mem.readVarInt(AsType(ffiType), mem[0..@sizeOf(AsType(ffiType))], .little))),
                    .i64 => try L.pushBuffer(mem[0..8]),
                    .u64 => try L.pushBuffer(mem[0..8]),
                    .float => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, mem[0..4], .little))))),
                    .double => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, mem[0..8], .little)))),
                    .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, mem[0..@sizeOf(usize)], .little)), true),
                }

                return 1;
            }
        }.inner;
    }

    pub fn GenerateWriteMethod(comptime ffiType: ffi.Type) fn (ptr: *LuaPointer, L: *Luau) anyerror!i32 {
        return struct {
            fn inner(ptr: *LuaPointer, L: *Luau) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.optInteger(2) orelse 0);

                const len = ffiType.toSize();
                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset .. offset + len];

                switch (ffiType) {
                    .void => unreachable,
                    .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .float, .double => try FFITypeConversion(ffiType, mem, L, 3, 0),
                    .pointer => switch (L.typeOf(-1)) {
                        .userdata => {
                            const lua_ptr = try LuaPointer.value(L, -1);
                            if (lua_ptr.destroyed)
                                return error.NoAddressAvailable;
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                            @memcpy(mem[0..@sizeOf(usize)], &bytes);
                        },
                        else => return error.InvalidArgType,
                    },
                }

                return 1;
            }
        }.inner;
    }

    pub const method_readi8 = GenerateReadMethod(.i8);
    pub const method_readu8 = GenerateReadMethod(.u8);
    pub const method_readi16 = GenerateReadMethod(.i16);
    pub const method_readu16 = GenerateReadMethod(.u16);
    pub const method_readi32 = GenerateReadMethod(.i32);
    pub const method_readu32 = GenerateReadMethod(.u32);
    pub const method_readi64 = GenerateReadMethod(.i64);
    pub const method_readu64 = GenerateReadMethod(.u64);
    pub const method_readf32 = GenerateReadMethod(.float);
    pub const method_readf64 = GenerateReadMethod(.double);
    pub const method_readPtr = GenerateReadMethod(.pointer);

    pub const method_writei8 = GenerateWriteMethod(.i8);
    pub const method_writeu8 = GenerateWriteMethod(.u8);
    pub const method_writei16 = GenerateWriteMethod(.i16);
    pub const method_writeu16 = GenerateWriteMethod(.u16);
    pub const method_writei32 = GenerateWriteMethod(.i32);
    pub const method_writeu32 = GenerateWriteMethod(.u32);
    pub const method_writei64 = GenerateWriteMethod(.i64);
    pub const method_writeu64 = GenerateWriteMethod(.u64);
    pub const method_writef32 = GenerateWriteMethod(.float);
    pub const method_writef64 = GenerateWriteMethod(.double);
    pub const method_writePtr = GenerateWriteMethod(.pointer);

    pub fn method_isNull(ptr: *LuaPointer, L: *Luau) i32 {
        if (ptr.destroyed) {
            L.pushBoolean(true);
            return 1;
        }
        L.pushBoolean(ptr.ptr == null);
        return 1;
    }

    pub fn method_setSize(ptr: *LuaPointer, L: *Luau) i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return L.raiseErrorStr("NoAddressAvailable", .{});
        const size: usize = @intFromFloat(L.checkNumber(2));

        switch (ptr.type) {
            .Allocated => L.raiseErrorStr("Cannot set size of a known size pointer", .{}),
            .Static => {},
        }

        ptr.size = size;

        return 0;
    }

    pub fn method_span(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        const src_offset: usize = @intCast(L.optInteger(2) orelse 0);

        const target: [*c]u8 = @ptrCast(@alignCast(ptr.ptr));

        const bytes: [:0]const u8 = std.mem.span(target[src_offset..]);

        const buf = try L.newBuffer(bytes.len + 1);
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;

        return 1;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaPointer, 1) catch L.raiseErrorStr("Invalid pointer", .{});

        const namecall = L.nameCallAtom() catch return 0;

        return switch (NamecallMap.get(namecall) orelse L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr})) {
            .Retain => try ptr.method_retain(L),
            .Release => ptr.method_release(L),
            .Drop => ptr.method_drop(L),
            .Offset => try ptr.method_offset(L),
            .Read => try ptr.method_read(L),
            .Write => try ptr.method_write(L),
            .Readi8 => try ptr.method_readi8(L),
            .Readu8 => try ptr.method_readu8(L),
            .Readi16 => try ptr.method_readi16(L),
            .Readu16 => try ptr.method_readu16(L),
            .Readi32 => try ptr.method_readi32(L),
            .Readu32 => try ptr.method_readu32(L),
            .Readi64 => try ptr.method_readi64(L),
            .Readu64 => try ptr.method_readu64(L),
            .Readf32 => try ptr.method_readf32(L),
            .Readf64 => try ptr.method_readf64(L),
            .ReadPtr => try ptr.method_readPtr(L),
            .Writei8 => try ptr.method_writei8(L),
            .Writeu8 => try ptr.method_writeu8(L),
            .Writei16 => try ptr.method_writei16(L),
            .Writeu16 => try ptr.method_writeu16(L),
            .Writei32 => try ptr.method_writei32(L),
            .Writeu32 => try ptr.method_writeu32(L),
            .Writei64 => try ptr.method_writei64(L),
            .Writeu64 => try ptr.method_writeu64(L),
            .Writef32 => try ptr.method_writef32(L),
            .Writef64 => try ptr.method_writef64(L),
            .WritePtr => try ptr.method_writePtr(L),
            .IsNull => ptr.method_isNull(L),
            .SetSize => ptr.method_setSize(L),
            .Span => try ptr.method_span(L),
        };
    }

    pub fn __eq(L: *Luau) i32 {
        L.checkType(1, .userdata);
        const ptr1 = L.toUserdata(LuaPointer, 1) catch L.raiseErrorStr("Invalid pointer", .{});

        switch (L.typeOf(2)) {
            .userdata => {
                const ptr2 = value(L, 2) catch {
                    L.pushBoolean(false);
                    return 1;
                };

                L.pushBoolean(ptr1.ptr == ptr2.ptr);

                return 1;
            },
            else => {
                L.pushBoolean(false);
                return 1;
            },
        }
    }

    pub fn __tostring(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = try value(L, 1);

        const allocator = L.allocator();

        const str = try std.fmt.allocPrint(allocator, "<pointer: 0x{x}>", .{@as(usize, @intFromPtr(ptr.ptr))});
        defer allocator.free(str);

        L.pushLString(str);

        return 1;
    }

    pub fn __dtor(L: *Luau, ptr: *LuaPointer) void {
        if (!ptr.destroyed) {
            if (ptr.ref) |ref|
                L.unref(ref);
            switch (ptr.type) {
                .Allocated => {
                    if (!ptr.retained) {
                        ptr.destroyed = true;
                        if (ptr.size) |size|
                            ptr.allocator.free(@as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size])
                        else
                            ptr.allocator.destroy(@as(**anyopaque, @ptrCast(@alignCast(ptr.ptr))));
                    }
                },
                .Static => {},
            }
        }
    }
};

const LuaHandle = struct {
    lib: std.DynLib,
    open: bool,
    declared: std.StringArrayHashMap(ffi.CallableFunction),
    allocated_args: std.StringArrayHashMap([]*anyopaque),

    pub const HandleFunction = struct {
        lib: *LuaHandle,
        callable: *ffi.CallableFunction,
        args: *[]*anyopaque,
    };

    pub fn call_ffi(L: *Luau) !i32 {
        const allocator = L.allocator();
        const ffi_func = L.toUserdata(HandleFunction, Luau.upvalueIndex(2)) catch unreachable;

        const callable = ffi_func.callable;
        const args = ffi_func.args.*;

        if (!ffi_func.lib.open)
            L.raiseErrorStr("Library closed", .{});

        if (@as(usize, @intCast(L.getTop())) != args.len)
            L.raiseErrorStr("Invalid number of arguments", .{});

        var alloclen: usize = 0;
        defer free_ffi_args(allocator, L, callable, 1, args, &alloclen, true);

        try load_ffi_args(allocator, L, callable, 1, args, &alloclen, true);

        const ret = try callable.call(@ptrCast(@alignCast(args)));
        defer callable.free(ret);

        switch (callable.returnType) {
            .ffiType => |ffiType| switch (ffiType) {
                .void => return 0,
                .i8 => L.pushInteger(@intCast(@as(i8, @bitCast(ret[0])))),
                .u8 => L.pushInteger(@intCast(ret[0])),
                .i16 => L.pushInteger(@intCast(std.mem.readVarInt(i16, ret[0..@sizeOf(i16)], .little))),
                .u16 => L.pushInteger(@intCast(std.mem.readVarInt(u16, ret[0..@sizeOf(u16)], .little))),
                .i32 => L.pushInteger(@intCast(std.mem.readVarInt(i32, ret[0..@sizeOf(i32)], .little))),
                .u32 => L.pushInteger(@intCast(std.mem.readVarInt(u32, ret[0..@sizeOf(u32)], .little))),
                .i64, .u64 => try L.pushBuffer(ret),
                .float => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, ret, .little))))),
                .double => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, ret, .little)))),
                .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, ret, .little)), true),
            },
            .structType => try L.pushBuffer(ret),
        }

        return 1;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaHandle, 1) catch L.raiseErrorStr("Invalid handle", .{});

        const namecall = L.nameCallAtom() catch return 0;

        if (!ptr.open)
            L.raiseErrorStr("Library closed", .{});

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            ptr.__dtor();
        } else if (std.mem.eql(u8, namecall, "getSymbol")) {
            const symbol = L.checkString(2);
            const sym_ptr = ptr.lib.lookup(*anyopaque, symbol) orelse {
                L.pushNil();
                return 1;
            };
            _ = try LuaPointer.newStaticPtr(L, sym_ptr, false);
            return 1;
        } else L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr});
        return 0;
    }

    pub fn __dtor(ptr: *LuaHandle) void {
        if (ptr.open) {
            const allocator = ptr.allocated_args.allocator;
            var iter_allocated = ptr.allocated_args.iterator();
            while (iter_allocated.next()) |entry| {
                const arg_type = ptr.declared.get(entry.key_ptr.*) orelse unreachable;
                const args = entry.value_ptr.*;
                for (0..args.len) |i| {
                    const argType = arg_type.argTypes[i];
                    if (ffi.toffiType(argType)) |t| switch (t) {
                        .void => std.debug.panic("Void arg", .{}),
                        .i8 => allocator.destroy(@as(*i8, @ptrCast(args[i]))),
                        .u8 => allocator.destroy(@as(*u8, @ptrCast(args[i]))),
                        .i16 => allocator.destroy(@as(*i16, @ptrCast(@alignCast(args[i])))),
                        .u16 => allocator.destroy(@as(*u16, @ptrCast(@alignCast(args[i])))),
                        .i32 => allocator.destroy(@as(*i32, @ptrCast(@alignCast(args[i])))),
                        .u32 => allocator.destroy(@as(*u32, @ptrCast(@alignCast(args[i])))),
                        .i64 => allocator.destroy(@as(*i64, @ptrCast(@alignCast(args[i])))),
                        .u64 => allocator.destroy(@as(*u64, @ptrCast(@alignCast(args[i])))),
                        .float => allocator.destroy(@as(*f32, @ptrCast(@alignCast(args[i])))),
                        .double => allocator.destroy(@as(*f64, @ptrCast(@alignCast(args[i])))),
                        .pointer => allocator.destroy(@as(**anyopaque, @ptrCast(@alignCast(args[i])))),
                    } else {
                        const mem: [*]u8 = @ptrCast(@alignCast(args[i]));
                        const len = argType.*.size;
                        allocator.free(mem[0..len]);
                    }
                }
                ptr.allocated_args.allocator.free(entry.value_ptr.*);
            }
            ptr.allocated_args.deinit();

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

    pub const NamecallMap = std.StaticStringMap(enum {
        Size,
        Alignment,
        Offset,
        New,
    }).initComptime(.{
        .{ "size", .Size },
        .{ "alignment", .Alignment },
        .{ "offset", .Offset },
        .{ "new", .New },
    });

    pub fn method_size(ptr: *LuaStructType, L: *Luau) !i32 {
        L.pushInteger(@intCast(ptr.type.getSize()));
        return 1;
    }

    pub fn method_alignment(ptr: *LuaStructType, L: *Luau) !i32 {
        L.pushInteger(@intCast(ptr.type.getAlignment()));
        return 1;
    }

    pub fn method_offset(ptr: *LuaStructType, L: *Luau) !i32 {
        const field = L.checkString(2);
        const order = ptr.fields.getIndex(field) orelse L.raiseErrorStr("Unknown field: %s\n", .{field.ptr});
        L.pushInteger(@intCast(ptr.type.offsets[order]));
        return 1;
    }

    pub fn method_new(ptr: *LuaStructType, L: *Luau) !i32 {
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
                .ffiType => |ffiType| {
                    switch (ffiType) {
                        .void => return error.VoidArg,
                        .i8 => try FFITypeConversion(.i8, mem, L, -1, offset),
                        .u8 => try FFITypeConversion(.u8, mem, L, -1, offset),
                        .i16 => try FFITypeConversion(.i16, mem, L, -1, offset),
                        .u16 => try FFITypeConversion(.u16, mem, L, -1, offset),
                        .i32 => try FFITypeConversion(.i32, mem, L, -1, offset),
                        .u32 => try FFITypeConversion(.u32, mem, L, -1, offset),
                        .i64 => try FFITypeConversion(.i64, mem, L, -1, offset),
                        .u64 => try FFITypeConversion(.u64, mem, L, -1, offset),
                        .float => try FFITypeConversion(.float, mem, L, -1, offset),
                        .double => try FFITypeConversion(.double, mem, L, -1, offset),
                        .pointer => switch (L.typeOf(-1)) {
                            .userdata => {
                                const lua_ptr = try LuaPointer.value(L, -1);
                                if (lua_ptr.destroyed)
                                    return error.NoAddressAvailable;
                                var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                                @memcpy(mem[offset .. offset + @sizeOf(usize)], &bytes);
                            },
                            else => return error.InvalidArgType,
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
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaStructType, 1) catch L.raiseErrorStr("Invalid struct", .{});

        const namecall = L.nameCallAtom() catch return 0;

        return switch (NamecallMap.get(namecall) orelse L.raiseErrorStr("Unknown method: %s\n", .{namecall.ptr})) {
            .Size => ptr.method_size(L),
            .Alignment => ptr.method_alignment(L),
            .Offset => ptr.method_offset(L),
            .New => ptr.method_new(L),
        };
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

pub fn FFITypeConversion(
    comptime ffiType: ffi.Type,
    mem: []u8,
    L: *Luau,
    index: comptime_int,
    offset: usize,
) !void {
    const T = AsType(ffiType);
    const isFloat = @typeInfo(T) == .Float;
    switch (L.typeOf(index)) {
        .number => {
            const value = if (isFloat) L.toNumber(index) catch unreachable else fast: {
                if (@bitSizeOf(T) > 32)
                    break :fast @as(u64, @intFromFloat(L.toNumber(index) catch unreachable))
                else
                    break :fast L.toInteger(index) catch unreachable;
            };
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return error.OutOfRange;
            var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, if (isFloat) @floatCast(value) else @intCast(value)));
            @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
        },
        .boolean => {
            const value = L.toBoolean(index);
            var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, if (value) 1 else 0));
            @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
        },
        .buffer => {
            const buf = L.toBuffer(-1) catch unreachable;
            if (buf.len < @sizeOf(T))
                return error.SmallBuffer;
            @memcpy(mem[offset .. offset + @sizeOf(T)], buf[0..@sizeOf(T)]);
        },
        else => return error.InvalidArgType,
    }
}

fn FFILoadTypeConversion(
    comptime ffiType: ffi.Type,
    allocator: std.mem.Allocator,
    args: []*anyopaque,
    arg_idx: usize,
    L: *Luau,
    index: i32,
    use_allocated: bool,
) !void {
    const T = AsType(ffiType);
    const isFloat = @typeInfo(T) == .Float;
    switch (L.typeOf(index)) {
        .number => {
            const value = if (isFloat) L.toNumber(index) catch unreachable else L.toInteger(index) catch unreachable;
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return error.OutOfRange;
            const v_ptr: *T = if (use_allocated) @ptrCast(@alignCast(args[arg_idx])) else try allocator.create(T);
            v_ptr.* = if (isFloat) @floatCast(value) else @intCast(value);
            if (!use_allocated)
                args[arg_idx] = @ptrCast(@alignCast(v_ptr));
        },
        .boolean => {
            const v_ptr: *T = if (use_allocated) @ptrCast(@alignCast(args[arg_idx])) else try allocator.create(T);
            v_ptr.* = if (L.toBoolean(index)) 1 else 0;
            if (!use_allocated)
                args[arg_idx] = @ptrCast(@alignCast(v_ptr));
        },
        .buffer => {
            const buf = L.toBuffer(index) catch unreachable;
            if (buf.len < @sizeOf(T))
                return error.SmallBuffer;
            const v_ptr: *T = if (use_allocated) @ptrCast(@alignCast(args[arg_idx])) else try allocator.create(T);
            v_ptr.* = value: {
                if (isFloat) {
                    break :value switch (ffiType) {
                        .float => @as(f32, @bitCast(std.mem.readVarInt(u32, buf, .little))),
                        .double => @as(f64, @bitCast(std.mem.readVarInt(u64, buf, .little))),
                        else => unreachable,
                    };
                } else {
                    break :value switch (ffiType) {
                        .i8 => @intCast(@as(i8, @bitCast(buf[0]))),
                        .u8 => @intCast(buf[0]),
                        else => std.mem.readVarInt(T, buf, .little),
                    };
                }
            };
            if (!use_allocated)
                args[arg_idx] = @ptrCast(@alignCast(v_ptr));
        },
        else => return error.InvalidArgType,
    }
}

fn load_ffi_args(
    allocator: std.mem.Allocator,
    L: *Luau,
    ffi_func: *ffi.CallableFunction,
    start_idx: usize,
    args: []*anyopaque,
    allocatedLen: *usize,
    pre_allocated: bool,
) !void {
    for (0..args.len) |i| {
        const lua_index: i32 = @intCast(start_idx + i);
        if (ffi.toffiType(ffi_func.argTypes[i])) |t| switch (t) {
            .void => std.debug.panic("Void arg", .{}),
            .i8 => try FFILoadTypeConversion(.i8, allocator, args, i, L, lua_index, pre_allocated),
            .u8 => try FFILoadTypeConversion(.u8, allocator, args, i, L, lua_index, pre_allocated),
            .i16 => try FFILoadTypeConversion(.i16, allocator, args, i, L, lua_index, pre_allocated),
            .u16 => try FFILoadTypeConversion(.u16, allocator, args, i, L, lua_index, pre_allocated),
            .i32 => try FFILoadTypeConversion(.i32, allocator, args, i, L, lua_index, pre_allocated),
            .u32 => try FFILoadTypeConversion(.u32, allocator, args, i, L, lua_index, pre_allocated),
            .i64 => try FFILoadTypeConversion(.i64, allocator, args, i, L, lua_index, pre_allocated),
            .u64 => try FFILoadTypeConversion(.u64, allocator, args, i, L, lua_index, pre_allocated),
            .float => try FFILoadTypeConversion(.float, allocator, args, i, L, lua_index, pre_allocated),
            .double => try FFILoadTypeConversion(.double, allocator, args, i, L, lua_index, pre_allocated),
            .pointer => switch (L.typeOf(lua_index)) {
                .userdata => {
                    const ptr = try LuaPointer.value(L, lua_index);
                    if (ptr.destroyed)
                        return error.NoAddressAvailable;
                    const v_ptr: **allowzero anyopaque = if (pre_allocated) @ptrCast(@alignCast(args[i])) else try allocator.create(*allowzero anyopaque);
                    v_ptr.* = @ptrCast(ptr.ptr);
                    if (!pre_allocated)
                        args[i] = @ptrCast(@alignCast(v_ptr));
                },
                .string => {
                    const str: [:0]const u8 = L.toString(lua_index) catch unreachable;
                    const dup = try allocator.dupeZ(u8, str);
                    errdefer allocator.free(dup);

                    const v_ptr: **anyopaque = if (pre_allocated) @ptrCast(@alignCast(args[i])) else try allocator.create(*anyopaque);
                    v_ptr.* = @ptrCast(dup.ptr);
                    if (!pre_allocated)
                        args[i] = @ptrCast(@alignCast(v_ptr));
                },
                .nil => {
                    const v_ptr: *?*anyopaque = if (pre_allocated) @ptrCast(@alignCast(args[i])) else try allocator.create(?*anyopaque);
                    v_ptr.* = null;
                    if (!pre_allocated)
                        args[i] = @ptrCast(@alignCast(v_ptr));
                },
                else => return error.InvalidArgType,
            },
        } else {
            if (L.typeOf(lua_index) != .buffer)
                return error.InvalidArgType;
            const buf = L.toBuffer(lua_index) catch unreachable;
            if (buf.len != ffi_func.argTypes[i].*.size)
                return error.InvalidStructSize;
            const mem: [*]u8 = if (pre_allocated) @ptrCast(@alignCast(args[i])) else @ptrCast(try allocator.alloc(u8, buf.len));
            @memcpy(mem[0..buf.len], buf);
            if (!pre_allocated)
                args[i] = @ptrCast(@alignCast(mem));
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
    pre_allocated: bool,
) void {
    for (0..allocatedLen.*) |i| {
        const lua_index: i32 = @intCast(start_idx + i);
        if (ffi.toffiType(ffi_func.argTypes[i])) |t| switch (t) {
            .void => std.debug.panic("Void arg", .{}),
            .i8 => if (!pre_allocated) allocator.destroy(@as(*i8, @ptrCast(args[i]))),
            .u8 => if (!pre_allocated) allocator.destroy(@as(*u8, @ptrCast(args[i]))),
            .i16 => if (!pre_allocated) allocator.destroy(@as(*i16, @ptrCast(@alignCast(args[i])))),
            .u16 => if (!pre_allocated) allocator.destroy(@as(*u16, @ptrCast(@alignCast(args[i])))),
            .i32 => if (!pre_allocated) allocator.destroy(@as(*i32, @ptrCast(@alignCast(args[i])))),
            .u32 => if (!pre_allocated) allocator.destroy(@as(*u32, @ptrCast(@alignCast(args[i])))),
            .i64 => if (!pre_allocated) allocator.destroy(@as(*i64, @ptrCast(@alignCast(args[i])))),
            .u64 => if (!pre_allocated) allocator.destroy(@as(*u64, @ptrCast(@alignCast(args[i])))),
            .float => if (!pre_allocated) allocator.destroy(@as(*f32, @ptrCast(@alignCast(args[i])))),
            .double => if (!pre_allocated) allocator.destroy(@as(*f64, @ptrCast(@alignCast(args[i])))),
            .pointer => {
                const ptr_value = @as(**anyopaque, @ptrCast(@alignCast(args[i])));
                switch (L.typeOf(lua_index)) {
                    .string => {
                        const str = L.toString(lua_index) catch unreachable;
                        const dup: [*c]u8 = @ptrCast(ptr_value.*);
                        allocator.free(@as([:0]const u8, dup[0..str.len :0]));
                    },
                    else => {},
                }
                if (!pre_allocated) allocator.destroy(ptr_value);
            },
        } else if (!pre_allocated) {
            const mem: [*]u8 = @ptrCast(@alignCast(args[i]));
            const len = ffi_func.argTypes[i].*.size;
            allocator.free(mem[0..len]);
        }
    }
}

fn alloc_ffi_args(allocator: std.mem.Allocator, args: []ffi.GenType) ![]*anyopaque {
    const alloc_args = try allocator.alloc(*anyopaque, args.len);
    var alloc_len: usize = 0;
    errdefer allocator.free(alloc_args);
    errdefer {
        for (0..alloc_len) |i| {
            switch (args[i]) {
                .ffiType => |t| switch (t) {
                    .void => unreachable,
                    .i8 => allocator.destroy(@as(*i8, @ptrCast(alloc_args[i]))),
                    .u8 => allocator.destroy(@as(*u8, @ptrCast(alloc_args[i]))),
                    .i16 => allocator.destroy(@as(*i16, @ptrCast(@alignCast(alloc_args[i])))),
                    .u16 => allocator.destroy(@as(*u16, @ptrCast(@alignCast(alloc_args[i])))),
                    .i32 => allocator.destroy(@as(*i32, @ptrCast(@alignCast(alloc_args[i])))),
                    .u32 => allocator.destroy(@as(*u32, @ptrCast(@alignCast(alloc_args[i])))),
                    .i64 => allocator.destroy(@as(*i64, @ptrCast(@alignCast(alloc_args[i])))),
                    .u64 => allocator.destroy(@as(*u64, @ptrCast(@alignCast(alloc_args[i])))),
                    .float => allocator.destroy(@as(*f32, @ptrCast(@alignCast(alloc_args[i])))),
                    .double => allocator.destroy(@as(*f64, @ptrCast(@alignCast(alloc_args[i])))),
                    .pointer => allocator.destroy(@as(**anyopaque, @ptrCast(@alignCast(alloc_args[i])))),
                },
                .structType => |t| {
                    const size = t.getSize();
                    allocator.free(@as([*]u8, @ptrCast(@alignCast(alloc_args[i])))[0..size]);
                },
            }
        }
    }

    // Allocate space for the arg types
    for (args, 0..) |arg, i| {
        switch (arg) {
            .ffiType => |t| switch (t) {
                .void => std.debug.panic("Void arg", .{}),
                .i8 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(i8))),
                .u8 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(u8))),
                .i16 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(i16))),
                .u16 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(u16))),
                .i32 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(i32))),
                .u32 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(u32))),
                .i64 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(i64))),
                .u64 => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(u64))),
                .float => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(f32))),
                .double => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(f64))),
                .pointer => alloc_args[i] = @ptrCast(@alignCast(try allocator.create(*anyopaque))),
            },
            .structType => |t| {
                const size = t.getSize();
                alloc_args[i] = @ptrCast(@alignCast((try allocator.alloc(u8, size)).ptr));
            },
        }
        alloc_len += 1;
    }

    return alloc_args;
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

    var ffi_func_map = std.StringArrayHashMap(ffi.CallableFunction).init(allocator);
    var ffi_func_allocated_map = std.StringArrayHashMap([]*anyopaque).init(allocator);

    ptr.* = .{
        .lib = undefined,
        .open = false,
        .declared = ffi_func_map,
        .allocated_args = ffi_func_allocated_map,
    };

    var lib = try std.DynLib.open(path);

    ptr.lib = lib;
    ptr.open = true;

    {
        errdefer {
            var iter = ffi_func_map.iterator();
            var iter_allocated = ffi_func_allocated_map.iterator();
            while (iter_allocated.next()) |entry|
                allocator.free(entry.value_ptr.*);
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

            var ffi_callback = try ffi.CallableFunction.init(allocator, func, symbol_args, symbol_returns);
            errdefer ffi_callback.deinit();

            // Allocate space for the arg types
            const alloc_args = try alloc_ffi_args(allocator, symbol_args);

            // Zig owned string to prevent GC from Lua owned strings
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            try ffi_func_map.put(key, ffi_callback);
            try ffi_func_allocated_map.put(key, alloc_args);
        }
    }

    ptr.declared = ffi_func_map;
    ptr.allocated_args = ffi_func_allocated_map;

    L.newTable();

    L.newTable();
    var iter = ffi_func_map.iterator();
    while (iter.next()) |entry| {
        L.pushLString(entry.key_ptr.*);
        L.pushValue(-4);
        const callable_entry = ptr.declared.getEntry(entry.key_ptr.*) orelse unreachable;
        const args_entry = ptr.allocated_args.getEntry(entry.key_ptr.*) orelse unreachable;
        const data = L.newUserdata(LuaHandle.HandleFunction);
        data.* = .{
            .lib = ptr,
            .args = args_entry.value_ptr,
            .callable = callable_entry.value_ptr,
        };
        L.pushClosure(luau.EFntoZigFn(LuaHandle.call_ffi), "ffi_func", 2);
        L.setTable(-3);
    }
    L.setField(-2, luau.Metamethods.index);

    L.setFieldFn(-1, luau.Metamethods.namecall, LuaHandle.__namecall);
    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setMetatable(-2);

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
            const data = @as(*LuaClosure, @ptrCast(@alignCast(ud.?)));
            if (cif.nargs != data.args.items.len)
                std.debug.panic("Invalid number of arguments", .{});

            const subthread = data.thread.newThread();
            defer data.thread.pop(1);
            data.thread.xPush(subthread, 1);

            for (data.args.items, 0..) |arg_type, i| {
                switch (arg_type) {
                    .ffiType => |t| switch (t) {
                        .void => unreachable,
                        .i8 => subthread.pushInteger(@intCast(@as(*i8, @ptrCast(ffi_args[i])).*)),
                        .u8 => subthread.pushInteger(@intCast(@as(*u8, @ptrCast(ffi_args[i])).*)),
                        .i16 => subthread.pushInteger(@intCast(@as(*i16, @ptrCast(@alignCast(ffi_args[i]))).*)),
                        .u16 => subthread.pushInteger(@intCast(@as(*u16, @ptrCast(@alignCast(ffi_args[i]))).*)),
                        .i32 => subthread.pushInteger(@as(*i32, @ptrCast(@alignCast(ffi_args[i]))).*),
                        .u32 => subthread.pushInteger(@intCast(@as(*u32, @ptrCast(@alignCast(ffi_args[i]))).*)),
                        .i64 => {
                            const bytes: [8]u8 = @bitCast(@as(*i64, @ptrCast(@alignCast(ffi_args[i]))).*);
                            subthread.pushBuffer(&bytes) catch |err| std.debug.panic("Failed: {}", .{err});
                        },
                        .u64 => {
                            const bytes: [8]u8 = @bitCast(@as(*u64, @ptrCast(@alignCast(ffi_args[i]))).*);
                            subthread.pushBuffer(&bytes) catch |err| std.debug.panic("Failed: {}", .{err});
                        },
                        .float => subthread.pushNumber(@floatCast(@as(f32, @bitCast(@as(*u32, @ptrCast(@alignCast(ffi_args[i]))).*)))),
                        .double => subthread.pushNumber(@as(f64, @bitCast(@as(*u64, @ptrCast(@alignCast(ffi_args[i]))).*))),
                        .pointer => _ = LuaPointer.newStaticPtr(subthread, @as(*[*]u8, @ptrCast(@alignCast(ffi_args[i]))).*, true) catch |err| std.debug.panic("Failed: {}", .{err}),
                    },
                    .structType => |t| {
                        const bytes: [*]u8 = @ptrCast(@alignCast(ffi_args[i]));
                        subthread.pushBuffer(bytes[0..t.getSize()]) catch |err| std.debug.panic("Failed: {}", .{err});
                    },
                }
            }

            const has_return = data.returns != .ffiType or data.returns.ffiType != .void;

            subthread.pcall(@intCast(data.args.items.len), if (has_return) 1 else 0, 0) catch {
                std.debug.panic("C Closure Runtime Error: {s}", .{subthread.toString(-1) catch "UnknownError"});
            };

            if (has_return) {
                defer subthread.pop(1);
                if (ffi_ret) |ret_ptr| {
                    switch (data.returns) {
                        .ffiType => |t| switch (t) {
                            .void => unreachable,
                            .i8 => switch (subthread.typeOf(-1)) {
                                .number => {
                                    const value = subthread.toInteger(-1) catch unreachable;
                                    if (value < std.math.minInt(i8) or value > std.math.maxInt(i8))
                                        return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                    @as(*i8, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                },
                                .boolean => @as(*i8, @ptrCast(@alignCast(ret_ptr))).* = if (subthread.toBoolean(-1)) 1 else 0,
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 1)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*i8, @ptrCast(@alignCast(ret_ptr))).* = @intCast(buf[0]);
                                },
                                else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .u8 => switch (subthread.typeOf(-1)) {
                                .number => {
                                    const value = subthread.toInteger(-1) catch unreachable;
                                    if (value < std.math.minInt(u8) or value > std.math.maxInt(u8))
                                        return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                    @as(*u8, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                },
                                .boolean => @as(*u8, @ptrCast(@alignCast(ret_ptr))).* = if (subthread.toBoolean(-1)) 1 else 0,
                                else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .i16 => switch (subthread.typeOf(-1)) {
                                .number => {
                                    const value = subthread.toInteger(-1) catch unreachable;
                                    if (value < std.math.minInt(i16) or value > std.math.maxInt(i16))
                                        return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                    @as(*i16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                },
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 2)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*i16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(std.mem.readVarInt(i16, buf, .little));
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .u16 => switch (subthread.typeOf(-1)) {
                                .number => {
                                    const value = subthread.toInteger(-1) catch unreachable;
                                    if (value < std.math.minInt(u16) or value > std.math.maxInt(u16))
                                        return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                    @as(*u16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(value);
                                },
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 2)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*u16, @ptrCast(@alignCast(ret_ptr))).* = @intCast(std.mem.readVarInt(u16, buf, .little));
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .i32 => switch (subthread.typeOf(-1)) {
                                .number => @as(*i32, @ptrCast(@alignCast(ret_ptr))).* = @intCast(subthread.toInteger(-1) catch unreachable),
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 4)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*i32, @ptrCast(@alignCast(ret_ptr))).* = std.mem.readVarInt(i32, buf, .little);
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .u32 => switch (subthread.typeOf(-1)) {
                                .number => @as(*u32, @ptrCast(@alignCast(ret_ptr))).* = @intCast(subthread.toInteger(-1) catch unreachable),
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 4)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*u32, @ptrCast(@alignCast(ret_ptr))).* = @intCast(std.mem.readVarInt(u32, buf, .little));
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .i64 => switch (subthread.typeOf(-1)) {
                                .number => @as(*i64, @ptrCast(@alignCast(ret_ptr))).* = @intCast(subthread.toInteger(-1) catch unreachable),
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 8)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*i64, @ptrCast(@alignCast(ret_ptr))).* = std.mem.readVarInt(i64, buf, .little);
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .u64 => switch (subthread.typeOf(-1)) {
                                .number => @as(*u64, @ptrCast(@alignCast(ret_ptr))).* = @intCast(subthread.toInteger(-1) catch unreachable),
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 8)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*u64, @ptrCast(@alignCast(ret_ptr))).* = std.mem.readVarInt(u64, buf, .little);
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .float => switch (subthread.typeOf(-1)) {
                                .number => {
                                    const value = subthread.toNumber(-1) catch unreachable;
                                    if (floatOutOfRange(f32, value))
                                        return std.debug.panic("Out of range ('{s}')", .{@tagName(t)});
                                    @as(*f32, @ptrCast(@alignCast(ret_ptr))).* = @floatCast(value);
                                },
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 4)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*f32, @ptrCast(@alignCast(ret_ptr))).* = @as(f32, @bitCast(std.mem.readVarInt(u32, buf, .little)));
                                },
                                else => return std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .double => switch (subthread.typeOf(-1)) {
                                .number => @as(*f64, @ptrCast(@alignCast(ret_ptr))).* = subthread.toNumber(-1) catch unreachable,
                                .buffer => {
                                    const buf = subthread.toBuffer(-1) catch unreachable;
                                    if (buf.len < 8)
                                        return std.debug.panic("Small buffer ('{s}')", .{@tagName(t)});
                                    @as(*f64, @ptrCast(@alignCast(ret_ptr))).* = @as(f64, @bitCast(std.mem.readVarInt(u64, buf, .little)));
                                },
                                else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@tagName(t)}),
                            },
                            .pointer => switch (subthread.typeOf(-1)) {
                                .userdata => {
                                    const ptr = LuaPointer.value(subthread, -1) catch std.debug.panic("Invalid pointer", .{});
                                    if (ptr.destroyed or ptr.ptr == null)
                                        std.debug.panic("No address available", .{});
                                    @as(*[*]u8, @ptrCast(@alignCast(ret_ptr))).* = @ptrCast(ptr.ptr);
                                },
                                .string => std.debug.panic("Unsupported return type (use a pointer to a buffer instead)", .{}),
                                .nil => {
                                    @as(*?*anyopaque, @ptrCast(@alignCast(ret_ptr))).* = null;
                                },
                                else => return std.debug.panic("Invalid return type (expected buffer/nil for '{s}')", .{@tagName(t)}),
                            },
                        },
                        .structType => |t| {
                            if (subthread.typeOf(-1) != .buffer)
                                return std.debug.panic("Invalid return type (expected buffer for struct)", .{});
                            const buf = subthread.toBuffer(-1) catch unreachable;
                            if (buf.len != t.getSize())
                                return std.debug.panic("Invalid return type (expected buffer of size {d} for struct)", .{t.getSize()});
                            @memcpy(@as([*]u8, @ptrCast(@alignCast(ret_ptr))), buf);
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
    _ = try LuaPointer.newStaticPtrWithRef(L, closure_ptr.executable, -3);
    L.setField(-2, "ptr");

    L.pushValue(2);
    L.setField(-2, "callback");
    L.setField(-2, luau.Metamethods.index);

    L.pushValue(-3);
    L.setField(-2, "thread");

    L.setReadOnly(-1, true);

    L.setMetatable(-2);

    return 1;
}

const FFIFunction = struct {
    callable: ffi.CallableFunction,
    args: []*anyopaque,
    ptr: *anyopaque,

    pub fn __dtor(self: *FFIFunction) void {
        const allocator = self.callable.allocator;
        const args = self.args;
        for (0..args.len) |i| {
            const argType = self.callable.argTypes[i];
            if (ffi.toffiType(argType)) |t| switch (t) {
                .void => std.debug.panic("Void arg", .{}),
                .i8 => allocator.destroy(@as(*i8, @ptrCast(args[i]))),
                .u8 => allocator.destroy(@as(*u8, @ptrCast(args[i]))),
                .i16 => allocator.destroy(@as(*i16, @ptrCast(@alignCast(args[i])))),
                .u16 => allocator.destroy(@as(*u16, @ptrCast(@alignCast(args[i])))),
                .i32 => allocator.destroy(@as(*i32, @ptrCast(@alignCast(args[i])))),
                .u32 => allocator.destroy(@as(*u32, @ptrCast(@alignCast(args[i])))),
                .i64 => allocator.destroy(@as(*i64, @ptrCast(@alignCast(args[i])))),
                .u64 => allocator.destroy(@as(*u64, @ptrCast(@alignCast(args[i])))),
                .float => allocator.destroy(@as(*f32, @ptrCast(@alignCast(args[i])))),
                .double => allocator.destroy(@as(*f64, @ptrCast(@alignCast(args[i])))),
                .pointer => allocator.destroy(@as(**anyopaque, @ptrCast(@alignCast(args[i])))),
            } else {
                const mem: [*]u8 = @ptrCast(@alignCast(args[i]));
                const len = argType.*.size;
                allocator.free(mem[0..len]);
            }
        }
        allocator.free(args);

        self.callable.deinit();
    }
};

fn ffi_fn_inner(L: *Luau) !i32 {
    const allocator = L.allocator();
    const ffi_func = L.toUserdata(FFIFunction, Luau.upvalueIndex(1)) catch unreachable;

    const callable = &ffi_func.callable;

    const args = ffi_func.args;

    if (@as(usize, @intCast(L.getTop())) != args.len)
        L.raiseErrorStr("Invalid number of arguments", .{});

    var alloclen: usize = 0;
    defer free_ffi_args(allocator, L, callable, 1, args, &alloclen, true);

    try load_ffi_args(allocator, L, callable, 1, args, &alloclen, true);

    const ret = try callable.call(args);
    defer callable.free(ret);

    switch (callable.returnType) {
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
            .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, ret[0..@sizeOf(usize)], .little)), true),
        },
        .structType => try L.pushBuffer(ret),
    }
    return 1;
}

fn ffi_fn(L: *Luau) !i32 {
    L.checkType(1, .table);
    const src = try LuaPointer.value(L, 2);
    switch (src.type) {
        .Allocated => return error.PointerNotCallable,
        else => {},
    }
    const ptr: *anyopaque = src.ptr orelse return error.NoAddressAvailable;

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

    const ffi_func = try ffi.CallableFunction.init(allocator, ptr, args.items, returns);

    // Allocate space for the arguments
    const alloc_args = try alloc_ffi_args(allocator, args.items);

    const data = L.newUserdataDtor(FFIFunction, FFIFunction.__dtor);

    data.* = .{
        .args = alloc_args,
        .callable = ffi_func,
        .ptr = ptr,
    };

    L.pushClosure(luau.EFntoZigFn(ffi_fn_inner), "ffi_fn", 1);

    return 1;
}

fn ffi_copy(L: *Luau) !i32 {
    const target_offset: usize = @intFromFloat(L.checkNumber(2));
    var target_bounds: ?usize = null;
    const target: [*]u8 = blk: {
        switch (L.typeOf(1)) {
            .buffer => {
                const buf = L.toBuffer(1) catch unreachable;
                target_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .userdata => {
                const ptr = LuaPointer.value(L, 1) catch L.raiseErrorStr("Invalid pointer", .{});
                if (ptr.destroyed or ptr.ptr == null)
                    L.raiseErrorStr("No address available", .{});
                target_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
        }
    };
    const src_offset: usize = @intFromFloat(L.checkNumber(4));
    var src_bounds: ?usize = null;
    const src: [*]u8 = blk: {
        switch (L.typeOf(3)) {
            .buffer => {
                const buf = L.toBuffer(3) catch unreachable;
                src_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .userdata => {
                const ptr = LuaPointer.value(L, 3) catch L.raiseErrorStr("Invalid pointer", .{});
                if (ptr.destroyed or ptr.ptr == null)
                    L.raiseErrorStr("No address available", .{});
                src_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
        }
    };
    const len: usize = @intCast(L.checkInteger(5));

    if (target_bounds) |bounds| if (target_offset + len > bounds)
        L.raiseErrorStr("Target OutOfBounds", .{});

    if (src_bounds) |bounds| if (src_offset + len > bounds)
        L.raiseErrorStr("Source OutOfBounds", .{});

    @memcpy(target[target_offset .. target_offset + len], src[src_offset .. src_offset + len]);

    return 0;
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

fn ffi_alloc(L: *Luau) !i32 {
    const len: usize = @intFromFloat(L.checkNumber(1));
    _ = try LuaPointer.allocBlockPtr(L, len);
    return 1;
}

fn ffi_free(L: *Luau) !i32 {
    const ptr = LuaPointer.value(L, 1) catch L.raiseErrorStr("Invalid pointer", .{});
    if (!ptr.destroyed) {
        const allocator = L.allocator();
        if (ptr.local_ref) |ref| {
            L.unref(ref);
            ptr.local_ref = null;
        }
        if (ptr.ref) |ref|
            L.unref(ref);
        ptr.ref = null;
        switch (ptr.type) {
            .Allocated => {
                ptr.destroyed = true;
                if (ptr.size) |size|
                    allocator.free(@as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size])
                else
                    allocator.destroy(@as(**anyopaque, @ptrCast(@alignCast(ptr.ptr))));
            },
            .Static => {
                if (ptr.size) |size| {
                    allocator.free(@as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size]);
                }
            },
        }
    } else L.raiseErrorStr("Double free", .{});
    return 0;
}

fn ffi_len(L: *Luau) !i32 {
    switch (L.typeOf(1)) {
        .buffer => {
            const buf = L.toBuffer(1) catch unreachable;
            L.pushInteger(@intCast(buf.len));
        },
        .userdata => {
            const ptr = LuaPointer.value(L, 1) catch L.raiseErrorStr("Invalid pointer", .{});
            if (ptr.destroyed or ptr.ptr == null)
                L.raiseErrorStr("No address available", .{});
            if (ptr.size) |size|
                L.pushInteger(@intCast(size))
            else
                L.pushNil();
        },
        else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
    }
    return 1;
}

fn ffi_dupe(L: *Luau) !i32 {
    switch (L.typeOf(1)) {
        .buffer => {
            const buf = L.toBuffer(1) catch unreachable;
            const ptr = try LuaPointer.allocBlockPtr(L, buf.len);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..buf.len],
                buf,
            );
        },
        .userdata => {
            const ptr = try LuaPointer.value(L, 1);
            if (ptr.destroyed or ptr.ptr == null)
                return error.NoAddressAvailable;
            const len = ptr.size orelse L.raiseErrorStr("Unknown sized pointer", .{});
            const dup_ptr = try LuaPointer.allocBlockPtr(L, len);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(dup_ptr.ptr)))[0..len],
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..len],
            );
        },
        else => L.raiseErrorStr("Invalid type (expected buffer or userdata)", .{}),
    }
    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaStructType.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.namecall, LuaStructType.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.pop(1);
    }
    {
        L.newMetatable(LuaPointer.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.eq, LuaPointer.__eq); // metatable.__eq
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaPointer.__namecall); // metatable.__namecall
        L.setFieldFn(-1, luau.Metamethods.tostring, LuaPointer.__tostring); // metatable.__tostring

        L.setUserdataDtor(LuaPointer, tagged.FFI_POINTER, LuaPointer.__dtor);
    }

    L.newTable();

    if (ffi.Supported()) {
        L.setFieldFn(-1, "dlopen", ffi_dlopen);
        L.setFieldFn(-1, "struct", ffi_struct);
        L.setFieldFn(-1, "closure", ffi_closure);
        L.setFieldFn(-1, "fn", ffi_fn);
        L.setFieldBoolean(-1, "supported", true);
    } else {
        L.setFieldFn(-1, "dlopen", ffi_unsupported);
        L.setFieldFn(-1, "struct", ffi_unsupported);
        L.setFieldFn(-1, "closure", ffi_unsupported);
        L.setFieldFn(-1, "fn", ffi_unsupported);
        L.setFieldBoolean(-1, "supported", false);
    }

    L.setFieldFn(-1, "sizeOf", ffi_sizeOf);
    L.setFieldFn(-1, "alignOf", ffi_alignOf);

    L.setFieldFn(-1, "alloc", ffi_alloc);
    L.setFieldFn(-1, "free", ffi_free);
    L.setFieldFn(-1, "copy", ffi_copy);
    L.setFieldFn(-1, "len", ffi_len);
    L.setFieldFn(-1, "dupe", ffi_dupe);

    L.setFieldFn(-1, "getRef", LuaPointer.getRef);
    L.setFieldFn(-1, "createPtr", LuaPointer.ptrFromBuffer);

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
