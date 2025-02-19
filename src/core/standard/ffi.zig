const std = @import("std");
const tinycc = @import("tinycc");
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("../../zune.zig");
const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");
const tagged = @import("../../tagged.zig");

const VM = luau.VM;

pub const LIB_NAME = "ffi";

const cpu_endian = builtin.cpu.arch.endian();

const Hash = std.crypto.hash.sha3.Sha3_256;

var TAGGED_FFI_POINTERS = std.StringArrayHashMap(u32).init(Zune.DEFAULT_ALLOCATOR);
var CACHED_C_COMPILATON = std.StringHashMap(*CallableFunction).init(Zune.DEFAULT_ALLOCATOR);

inline fn intOutOfRange(comptime T: type, value: anytype) bool {
    return value < std.math.minInt(T) or value > std.math.maxInt(T);
}

inline fn floatOutOfRange(comptime T: type, value: f64) bool {
    return value < -std.math.floatMax(T) or value > std.math.floatMax(T);
}

pub const DataType = struct {
    size: usize,
    alignment: u29,
    kind: TypeKind,

    pub const Types = enum {
        void,
        i8,
        i16,
        i32,
        i64,
        u8,
        u16,
        u32,
        u64,
        f32,
        f64,
        pointer,
        @"struct",

        pub fn asType(comptime self: Types) type {
            switch (self) {
                .void => return void,
                .i8 => return i8,
                .i16 => return i16,
                .i32 => return i32,
                .i64 => return i64,
                .u8 => return u8,
                .u16 => return u16,
                .u32 => return u32,
                .u64 => return u64,
                .f32 => return f32,
                .f64 => return f64,
                .pointer => return *anyopaque,
                .@"struct" => return [*]u8,
            }
        }

        pub fn typeName(comptime self: Types) []const u8 {
            switch (self) {
                .void => return "void",
                .i8 => return "signed char",
                .i16 => return "signed short",
                .i32 => return "signed int",
                .i64 => return "signed long long",
                .u8 => return "unsigned char",
                .u16 => return "unsigned short",
                .u32 => return "unsigned int",
                .u64 => return "unsigned long long",
                .f32 => return "float",
                .f64 => return "double",
                .pointer => return "void*",
                .@"struct" => return "struct",
            }
        }
    };

    pub const TypeKind = union(Types) {
        void: void,
        i8: void,
        i16: void,
        i32: void,
        i64: void,
        u8: void,
        u16: void,
        u32: void,
        u64: void,
        f32: void,
        f64: void,
        pointer: struct {
            tag: u32,
        },
        @"struct": void,
    };
};

pub const DataTypes = struct {
    pub const Types = struct {
        pub const type_void = DataType{ .size = 0, .alignment = 0, .kind = .void };

        pub const type_i8 = DataType{ .size = 1, .alignment = 1, .kind = .i8 };
        pub const type_i16 = DataType{ .size = 2, .alignment = 2, .kind = .i16 };
        pub const type_i32 = DataType{ .size = 4, .alignment = 4, .kind = .i32 };
        pub const type_i64 = DataType{ .size = 8, .alignment = 8, .kind = .i64 };

        pub const type_u8 = DataType{ .size = 1, .alignment = 1, .kind = .u8 };
        pub const type_u16 = DataType{ .size = 2, .alignment = 2, .kind = .u16 };
        pub const type_u32 = DataType{ .size = 4, .alignment = 4, .kind = .u32 };
        pub const type_u64 = DataType{ .size = 8, .alignment = 8, .kind = .u64 };

        pub const type_float = DataType{ .size = 4, .alignment = 4, .kind = .f32 };
        pub const type_double = DataType{ .size = 8, .alignment = 8, .kind = .f64 };
        pub const type_pointer = DataType{ .size = 8, .alignment = 8, .kind = .{ .pointer = .{ .tag = 0 } } };
    };

    pub const order: []const *const DataType = &.{
        &Types.type_void,  &Types.type_i8,     &Types.type_i16,
        &Types.type_i32,   &Types.type_i64,    &Types.type_u8,
        &Types.type_u16,   &Types.type_u32,    &Types.type_u64,
        &Types.type_float, &Types.type_double, &Types.type_pointer,
    };

    pub fn generateCTypeName(datatype: DataType, writer: anytype, id: usize, comptime pointer: bool) !void {
        const suffix = if (pointer) "*" else "";
        switch (datatype.kind) {
            .void => try writer.writeAll("void" ++ suffix),
            .i8 => try writer.writeAll("char" ++ suffix),
            .i16 => try writer.writeAll("short" ++ suffix),
            .i32 => try writer.writeAll("int" ++ suffix),
            .i64 => try writer.writeAll("long long" ++ suffix),
            .u8 => try writer.writeAll("unsigned char" ++ suffix),
            .u16 => try writer.writeAll("unsigned short" ++ suffix),
            .u32 => try writer.writeAll("unsigned int" ++ suffix),
            .u64 => try writer.writeAll("unsigned long long" ++ suffix),
            .f32 => try writer.writeAll("float" ++ suffix),
            .f64 => try writer.writeAll("double" ++ suffix),
            .pointer => try writer.writeAll("void*" ++ suffix),
            .@"struct" => try writer.print("struct anon_{d}" ++ suffix, .{id}),
        }
    }
};

fn alignForward(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(@as(usize, alignment - 1));
}

pub fn makeStruct(allocator: std.mem.Allocator, fields: []const DataType) !struct { DataType, []usize } {
    var offset: usize = 0;
    var alignment: u29 = 1;
    var offsets = try allocator.alloc(usize, fields.len);
    errdefer allocator.free(offsets);
    for (fields, 0..) |field, i| {
        alignment = @max(alignment, field.alignment);
        offset = alignForward(offset, field.alignment);
        offsets[i] = offset;
        offset += field.size;
    }
    const size = alignForward(offset, alignment);
    return .{ .{
        .size = size,
        .alignment = alignment,
        .kind = .@"struct",
    }, offsets };
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

    pub fn ptrFromBuffer(L: *VM.lua.State) !i32 {
        const buf = L.Lcheckbuffer(1);
        if (buf.len < @sizeOf(usize))
            return error.SmallBuffer;

        const ptr = L.newuserdatataggedwithmetatable(LuaPointer, tagged.FFI_POINTER);

        ptr.* = .{
            .ptr = @ptrFromInt(std.mem.readVarInt(usize, buf[0..@sizeOf(usize)], cpu_endian)),
            .allocator = luau.getallocator(L),
            .destroyed = false,
            .type = .Static,
        };

        return 1;
    }

    pub fn allocBlockPtr(L: *VM.lua.State, size: usize) !*LuaPointer {
        const allocator = luau.getallocator(L);

        const mem = try allocator.alloc(u8, size);
        @memset(mem, 0);

        const ptr = L.newuserdatataggedwithmetatable(LuaPointer, tagged.FFI_POINTER);

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

    pub fn newStaticPtr(L: *VM.lua.State, staticPtr: ?*anyopaque, default_retain: bool) !*LuaPointer {
        const ptr = L.newuserdatataggedwithmetatable(LuaPointer, tagged.FFI_POINTER);

        ptr.* = .{
            .ptr = staticPtr,
            .allocator = luau.getallocator(L),
            .destroyed = false,
            .type = .Static,
        };

        if (default_retain)
            try retain(ptr, L);

        return ptr;
    }

    pub fn newStaticPtrWithRef(L: *VM.lua.State, staticPtr: ?*anyopaque, idx: i32) !*LuaPointer {
        const ref = L.ref(idx) orelse return error.Fail;

        const ptr = try newStaticPtr(L, staticPtr, true);

        ptr.ref = ref;

        return ptr;
    }

    pub fn getRef(L: *VM.lua.State) !i32 {
        const ref_ptr = value(L, 1) orelse return error.Failed;
        const allocator = luau.getallocator(L);

        const ptr = L.newuserdatataggedwithmetatable(LuaPointer, tagged.FFI_POINTER);

        const mem = try allocator.create(*anyopaque);
        mem.* = @ptrCast(@alignCast(ref_ptr.ptr));

        ptr.* = .{
            .ptr = @ptrCast(@alignCast(mem)),
            .allocator = allocator,
            .destroyed = false,
            .type = .Allocated,
        };

        try retain(ptr, L);

        return 1;
    }

    pub fn retain(ptr: *LuaPointer, L: *VM.lua.State) !void {
        if (ptr.local_ref != null) {
            ptr.retained = true;
            return;
        }
        const local = L.ref(-1) orelse return error.Fail;
        ptr.retained = true;
        ptr.local_ref = local;
    }

    pub inline fn is(L: *VM.lua.State, idx: i32) bool {
        return L.getUserdataTag(idx) == tagged.FFI_POINTER;
    }

    pub inline fn value(L: *VM.lua.State, idx: i32) ?*LuaPointer {
        return L.touserdatatagged(LuaPointer, idx, tagged.FFI_POINTER);
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

    pub fn method_retain(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        L.pushvalue(1);
        try retain(ptr, L);
        return 1;
    }

    pub fn method_release(ptr: *LuaPointer, L: *VM.lua.State) i32 {
        ptr.retained = false;
        if (ptr.local_ref) |ref|
            L.unref(ref);
        ptr.local_ref = null;
        L.pushvalue(1);
        return 1;
    }

    pub fn method_drop(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        if (ptr.type == .Static)
            return L.Zerror("Cannot drop a static pointer");
        ptr.destroyed = true;
        if (ptr.local_ref) |ref|
            L.unref(ref);
        ptr.local_ref = null;
        if (ptr.ref) |ref|
            L.unref(ref);
        ptr.ref = null;
        return 1;
    }

    pub fn method_offset(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        const offset: usize = @intCast(try L.Zcheckvalue(i32, 2, null));
        if (ptr.ptr == null) {
            _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(offset), false);
            return 1;
        }
        if (ptr.size) |size|
            if (size < offset)
                return L.Zerror("Offset OutOfBounds");

        const static = try LuaPointer.newStaticPtr(L, @as([*]u8, @ptrCast(ptr.ptr))[offset..], false);

        if (ptr.size) |size|
            static.size = size - offset;

        return 1;
    }

    pub fn method_read(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return error.NoAddressAvailable;

        const src_offset: usize = @intFromFloat(L.Lchecknumber(2));
        const dest_offset: usize = @intFromFloat(L.Lchecknumber(4));
        var dest_bounds: ?usize = null;
        const dest: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .Buffer => {
                    const buf = L.tobuffer(3) orelse unreachable;
                    dest_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .Userdata => {
                    const other = LuaPointer.value(L, 3) orelse return error.Fail;
                    if (other.destroyed or other.ptr == null)
                        return error.NoAddressAvailable;
                    dest_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => return L.Zerror("Invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

        if (dest_bounds) |size| if (size < dest_offset + len)
            return L.Zerror("Target OutOfBounds");

        if (ptr.size) |size| if (size < src_offset + len)
            return L.Zerror("Source OutOfBounds");

        const src: [*]u8 = @ptrCast(@alignCast(ptr.ptr));

        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        L.pushvalue(3);
        return 1;
    }

    pub fn method_write(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return error.NoAddressAvailable;

        const dest_offset: usize = @intCast(try L.Zcheckvalue(i32, 2, null));
        const src_offset: usize = @intFromFloat(try L.Zcheckvalue(f64, 4, null));
        var src_bounds: ?usize = null;
        const src: [*]u8 = blk: {
            switch (L.typeOf(3)) {
                .Buffer => {
                    const buf = L.tobuffer(3) orelse unreachable;
                    src_bounds = buf.len;
                    break :blk @ptrCast(@alignCast(buf.ptr));
                },
                .Userdata => {
                    const other = LuaPointer.value(L, 3) orelse return error.Fail;
                    if (other.destroyed or other.ptr == null)
                        return error.NoAddressAvailable;
                    src_bounds = other.size;
                    break :blk @ptrCast(@alignCast(ptr.ptr));
                },
                else => return L.Zerror("Invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

        if (ptr.size) |size| if (size < dest_offset + len)
            return L.Zerror("Target OutOfBounds");

        if (src_bounds) |size| if (size < src_offset + len)
            return L.Zerror("Source OutOfBounds");

        const dest: [*]u8 = @ptrCast(@alignCast(ptr.ptr));
        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        return 0;
    }

    pub fn GenerateReadMethod(comptime T: type) fn (ptr: *LuaPointer, L: *VM.lua.State) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot read void type");
        const ti = @typeInfo(T);
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.Loptinteger(2, 0));

                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: [*]u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset..];

                switch (ti) {
                    .float => switch (len) {
                        4 => L.pushnumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, mem[0..len], cpu_endian))))),
                        8 => L.pushnumber(@as(f64, @bitCast(std.mem.readVarInt(u64, mem[0..len], cpu_endian)))),
                        else => unreachable,
                    },
                    .int => switch (len) {
                        1 => L.pushinteger(@intCast(@as(T, @bitCast(mem[0])))),
                        2...4 => L.pushinteger(@intCast(std.mem.readVarInt(T, mem[0..len], cpu_endian))),
                        8 => L.Zpushbuffer(mem[0..len]),
                        else => return error.Unsupported,
                    },
                    .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, mem[0..@sizeOf(usize)], cpu_endian)), false),
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    pub fn GenerateWriteMethod(comptime T: type) fn (ptr: *LuaPointer, L: *VM.lua.State) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot write void type");
        const ti = @typeInfo(T);
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.Loptinteger(2, 0));

                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset .. offset + len];

                switch (ti) {
                    .int, .float => try FFITypeConversion(T, mem, L, 3, 0),
                    .pointer => switch (L.typeOf(-1)) {
                        .Userdata => {
                            const lua_ptr = LuaPointer.value(L, -1) orelse return error.Fail;
                            if (lua_ptr.destroyed)
                                return error.NoAddressAvailable;
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                            @memcpy(mem[0..@sizeOf(usize)], &bytes);
                        },
                        else => return error.InvalidArgType,
                    },
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    pub const method_readi8 = GenerateReadMethod(i8);
    pub const method_readu8 = GenerateReadMethod(u8);
    pub const method_readi16 = GenerateReadMethod(i16);
    pub const method_readu16 = GenerateReadMethod(u16);
    pub const method_readi32 = GenerateReadMethod(i32);
    pub const method_readu32 = GenerateReadMethod(u32);
    pub const method_readi64 = GenerateReadMethod(i64);
    pub const method_readu64 = GenerateReadMethod(u64);
    pub const method_readf32 = GenerateReadMethod(f32);
    pub const method_readf64 = GenerateReadMethod(f64);
    pub const method_readPtr = GenerateReadMethod(*anyopaque);

    pub const method_writei8 = GenerateWriteMethod(i8);
    pub const method_writeu8 = GenerateWriteMethod(u8);
    pub const method_writei16 = GenerateWriteMethod(i16);
    pub const method_writeu16 = GenerateWriteMethod(u16);
    pub const method_writei32 = GenerateWriteMethod(i32);
    pub const method_writeu32 = GenerateWriteMethod(u32);
    pub const method_writei64 = GenerateWriteMethod(i64);
    pub const method_writeu64 = GenerateWriteMethod(u64);
    pub const method_writef32 = GenerateWriteMethod(f32);
    pub const method_writef64 = GenerateWriteMethod(f64);
    pub const method_writePtr = GenerateWriteMethod(*anyopaque);

    pub fn method_isNull(ptr: *LuaPointer, L: *VM.lua.State) i32 {
        if (ptr.destroyed) {
            L.pushboolean(true);
            return 1;
        }
        L.pushboolean(ptr.ptr == null);
        return 1;
    }

    pub fn method_setSize(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return L.Zerror("NoAddressAvailable");
        const size = L.Lchecknumber(2);
        if (size < 0)
            return L.Zerror("Size cannot be negative");

        const length: usize = @intFromFloat(size);

        switch (ptr.type) {
            .Allocated => return L.Zerror("Cannot set size of a known size pointer"),
            .Static => {
                if (ptr.size) |_|
                    return L.Zerror("Cannot set size of a known size pointer");
            },
        }

        ptr.size = length;

        return 0;
    }

    pub fn method_span(ptr: *LuaPointer, L: *VM.lua.State) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        const src_offset: usize = @intCast(L.Loptinteger(2, 0));

        const target: [*c]u8 = @ptrCast(@alignCast(ptr.ptr));

        const bytes: [:0]const u8 = std.mem.span(target[src_offset..]);

        const buf = L.newbuffer(bytes.len + 1);
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;

        return 1;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdata(LuaPointer, 1) orelse return L.Zerror("Invalid pointer");

        const namecall = L.namecallstr() orelse return 0;

        return switch (NamecallMap.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall})) {
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

    pub fn __eq(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr1 = L.touserdata(LuaPointer, 1) orelse return L.Zerror("Invalid pointer");

        switch (L.typeOf(2)) {
            .Userdata => {
                const ptr2 = value(L, 2) orelse {
                    L.pushboolean(false);
                    return 1;
                };

                L.pushboolean(ptr1.ptr == ptr2.ptr);

                return 1;
            },
            else => {
                L.pushboolean(false);
                return 1;
            },
        }
    }

    pub fn __tostring(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = value(L, 1) orelse return error.Failed;

        const allocator = luau.getallocator(L);

        const str = try std.fmt.allocPrint(allocator, "<pointer: 0x{x}>", .{@as(usize, @intFromPtr(ptr.ptr))});
        defer allocator.free(str);

        L.pushlstring(str);

        return 1;
    }

    pub fn __dtor(L: *VM.lua.State, ptr: *LuaPointer) void {
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

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdata(LuaHandle, 1) orelse return L.Zerror("Invalid handle");

        const namecall = L.namecallstr() orelse return 0;

        if (!ptr.open)
            return L.Zerror("Library closed");

        // TODO: prob should switch to static string map
        if (std.mem.eql(u8, namecall, "close")) {
            ptr.__dtor();
        } else if (std.mem.eql(u8, namecall, "getSymbol")) {
            const symbol = try L.Zcheckvalue([:0]const u8, 2, null);
            const sym_ptr = ptr.lib.lookup(*anyopaque, symbol) orelse {
                L.pushnil();
                return 1;
            };
            _ = try LuaPointer.newStaticPtr(L, sym_ptr, false);
            return 1;
        } else return L.Zerrorf("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn __dtor(ptr: *LuaHandle) void {
        if (ptr.open)
            ptr.lib.close();
        ptr.open = false;
    }
};

const FunctionSymbol = struct {
    returns: DataType,
    args: []const DataType,
};

const CompiledSymbol = struct {
    type: FunctionSymbol,
    state: *tinycc.TCCState,
    block: tinycc.DynMem,

    pub fn free(self: CompiledSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.type.args);
        self.block.free();
        self.state.deinit();
    }
};

const CallableFunction = struct {
    pointers: usize,
    references: usize,
    sym: CompiledSymbol,

    hash: ?[]const u8,

    pub fn deinit(self: *CallableFunction) void {
        const allocator = Zune.DEFAULT_ALLOCATOR;
        self.sym.free(allocator);
        if (self.hash) |hash| {
            _ = CACHED_C_COMPILATON.fetchRemove(hash);
            allocator.free(hash);
        }
        allocator.destroy(self);
    }

    pub fn unref(self: *CallableFunction) void {
        self.references -= 1;
        if (self.references == 0)
            self.deinit();
    }

    pub fn ref(self: *CallableFunction) void {
        self.references += 1;
    }

    pub fn getSymbol(self: *CallableFunction) *const anyopaque {
        return self.sym.state.get_symbol("call_fn_ffi").?; // checked at compilation
    }
};

fn hashFunctionSignature(out: *[Hash.digest_length]u8, returns: DataType, args: []const DataType) void {
    const size_len = @sizeOf(usize) + 1;
    var buffer: [size_len]u8 = undefined;

    var hash = Hash.init(.{});

    std.mem.writeInt(usize, buffer[0 .. size_len - 1], returns.size, .little);
    switch (returns.kind) {
        inline else => |_, T| std.mem.writeInt(u8, buffer[size_len - 1 .. size_len], @intFromEnum(T), .little),
    }
    hash.update(&buffer);

    for (args) |arg| {
        std.mem.writeInt(usize, buffer[0 .. size_len - 1], arg.size, .little);
        switch (arg.kind) {
            inline else => |_, T| std.mem.writeInt(u8, buffer[size_len - 1 .. size_len], @intFromEnum(T), .little),
        }
        hash.update(&buffer);
    }
    hash.final(out);
}

fn compileCallableFunction(returns: DataType, args: []const DataType) !CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;
    const state = try tinycc.new();
    errdefer state.deinit();

    state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
    state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();

    const pointers = try dynamicLoadImport(&source, state, returns, args);

    try source.append('\n');
    try generateSourceFromSymbol(&source, returns, args);

    const block = state.compileStringOnceAlloc(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    errdefer block.free();

    _ = state.get_symbol("call_fn_ffi") orelse return error.BadCompilation;

    return .{
        .sym = .{
            .state = state,
            .block = block,
            .type = .{
                .returns = returns,
                .args = try allocator.dupe(DataType, args),
            },
        },
        .pointers = pointers,
        .references = 0,
        .hash = null,
    };
}

fn fetchCallableFunction(returns: DataType, args: []const DataType) !*CallableFunction {
    const allocator = Zune.DEFAULT_ALLOCATOR;
    var hash: [Hash.digest_length]u8 = undefined;
    hashFunctionSignature(&hash, returns, args);

    if (CACHED_C_COMPILATON.getEntry(&hash)) |entry| {
        entry.value_ptr.*.ref();
        return entry.value_ptr.*;
    }

    var code = compileCallableFunction(returns, args) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    errdefer code.deinit();

    const code_ptr = try allocator.create(CallableFunction);
    errdefer allocator.destroy(code_ptr);

    const hash_key = try allocator.dupe(u8, &hash);
    errdefer allocator.free(hash_key);

    code.hash = hash_key;
    code_ptr.* = code;

    try CACHED_C_COMPILATON.put(hash_key, code_ptr);

    code_ptr.ref();

    return code_ptr;
}

const LuaClosure = struct {
    allocator: std.mem.Allocator,
    callinfo: *CallInfo,
    thread: *VM.lua.State,
    ptr: *anyopaque,
    sym: CompiledSymbol,

    callable: *anyopaque,

    pub const CallInfo = struct {
        args: c_uint,
        thread: *VM.lua.State,
        type: FunctionSymbol,
    };

    pub fn __dtor(self: *LuaClosure) void {
        self.allocator.destroy(self.callinfo);
        self.sym.free(self.allocator);
    }
};

const LuaStructType = struct {
    type: DataType,
    offsets: []usize,
    fields_map: std.StringArrayHashMap(DataType),

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

    pub fn method_size(self: *LuaStructType, L: *VM.lua.State) !i32 {
        L.pushinteger(@intCast(self.type.size));
        return 1;
    }

    pub fn method_alignment(self: *LuaStructType, L: *VM.lua.State) !i32 {
        L.pushinteger(@intCast(self.type.alignment));
        return 1;
    }

    pub fn method_offset(self: *LuaStructType, L: *VM.lua.State) !i32 {
        const field = try L.Zcheckvalue([]const u8, 2, null);
        const order = self.fields_map.getIndex(field) orelse return L.Zerrorf("Unknown field: {s}", .{field});
        L.pushinteger(@intCast(self.offsets[order]));
        return 1;
    }

    pub fn method_new(self: *LuaStructType, L: *VM.lua.State) !i32 {
        try L.Zchecktype(2, .Table);
        const allocator = luau.getallocator(L);

        const mem = try allocator.alloc(u8, self.type.size);
        defer allocator.free(mem);

        @memset(mem, 0);

        for (self.fields_map.keys(), self.fields_map.values(), 0..) |field, field_value, order| {
            defer L.pop(1);
            L.pushlstring(field);
            if (L.gettable(2).isnoneornil())
                return error.MissingField;
            const offset = self.offsets[order];
            const field_type = field_value;
            switch (field_type.kind) {
                .void => return error.InvalidArgType,
                .pointer => switch (L.typeOf(-1)) {
                    .Userdata => {
                        const lua_ptr = LuaPointer.value(L, -1) orelse return error.Failed;
                        if (lua_ptr.destroyed)
                            return error.NoAddressAvailable;
                        var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(lua_ptr.ptr)));
                        @memcpy(mem[offset .. offset + @sizeOf(usize)], &bytes);
                    },
                    else => return error.InvalidArgType,
                },
                .@"struct" => {
                    if (L.typeOf(-1) != .Buffer)
                        return error.InvalidArgType;
                    const value = L.tobuffer(-1) orelse unreachable;
                    if (value.len != field_type.size)
                        return error.InvalidArgType;
                    @memcpy(mem[offset .. offset + field_type.size], value);
                },
                inline else => |_, T| try FFITypeConversion(T.asType(), mem, L, -1, offset),
            }
        }

        L.Zpushbuffer(mem);

        return 1;
    }

    pub fn __namecall(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const ptr = L.touserdata(LuaStructType, 1) orelse return L.Zerror("Invalid struct");

        const namecall = L.namecallstr() orelse return 0;

        return switch (NamecallMap.get(namecall) orelse return L.Zerrorf("Unknown method: {s}", .{namecall})) {
            .Size => ptr.method_size(L),
            .Alignment => ptr.method_alignment(L),
            .Offset => ptr.method_offset(L),
            .New => ptr.method_new(L),
        };
    }

    pub fn __dtor(_: *VM.lua.State, self: *LuaStructType) void {
        const allocator = self.fields_map.allocator;
        var iter = self.fields_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
        allocator.free(self.offsets);
        self.fields_map.deinit();
    }
};

const FFITypeSize = std.meta.fields(DataType).len;
fn convertToFFIType(number: i32) !DataType {
    if (number < 0 or @as(u32, @intCast(number)) > FFITypeSize)
        return error.InvalidReturnType;
    return @enumFromInt(number);
}

fn isFFIType(L: *VM.lua.State, idx: i32) bool {
    switch (L.typeOf(idx)) {
        .Userdata => {
            _ = L.touserdatatagged(LuaStructType, idx, tagged.FFI_STRUCT) orelse return false;
            return true;
        },
        .LightUserdata => {
            _ = L.tolightuserdatatagged(DataType, idx, tagged.FFI_STRUCT) orelse return false;
            return true;
        },
        else => return false,
    }
}

fn toFFIType(L: *VM.lua.State, idx: i32) !DataType {
    switch (L.typeOf(idx)) {
        .Userdata => {
            const lua_struct = L.touserdatatagged(LuaStructType, idx, tagged.FFI_STRUCT) orelse return error.InvalidFFIType;
            return lua_struct.*.type;
        },
        .LightUserdata => {
            const datatype = L.tolightuserdatatagged(DataType, idx, tagged.FFI_STRUCT) orelse return error.InvalidFFIType;
            return datatype.*;
        },
        else => return error.InvalidType,
    }
}

pub fn FFITypeConversion(
    comptime T: type,
    mem: []u8,
    L: *VM.lua.State,
    index: comptime_int,
    offset: usize,
) !void {
    const ti = @typeInfo(T);
    if (ti != .int and ti != .float)
        @compileError("Unsupported type");
    const isFloat = ti == .float;
    switch (L.typeOf(index)) {
        .Number => {
            const value = if (isFloat) L.tonumber(index) orelse unreachable else fast: {
                if (@bitSizeOf(T) > 32)
                    break :fast @as(u64, @intFromFloat(L.tonumber(index) orelse unreachable))
                else
                    break :fast L.tointeger(index) orelse unreachable;
            };
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return error.OutOfRange;
            var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, if (isFloat) @floatCast(value) else @intCast(value)));
            @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
        },
        .Boolean => {
            const value = L.toboolean(index);
            var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, if (value) 1 else 0));
            @memcpy(mem[offset .. offset + @sizeOf(T)], &bytes);
        },
        .Buffer => {
            const buf = L.tobuffer(-1) orelse unreachable;
            if (buf.len < @sizeOf(T))
                return error.SmallBuffer;
            @memcpy(mem[offset .. offset + @sizeOf(T)], buf[0..@sizeOf(T)]);
        },
        else => return error.InvalidArgType,
    }
}

const ffi_c_interface = struct {
    fn FFIArgumentLoad(comptime T: type) fn (L: *VM.lua.State, index: i32) callconv(.C) T {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const isFloat = ti == .float;
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, index: i32) callconv(.C) T {
                switch (L.typeOf(index)) {
                    .Number => {
                        const value = if (isFloat) L.tonumber(index).? else L.tointeger(index).?;
                        if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                            return L.LerrorL("Value OutOfRange", .{});
                        return if (isFloat) @floatCast(value) else @intCast(value);
                    },
                    .Boolean => {
                        return @as(T, if (L.toboolean(index) == true) 1 else 0);
                    },
                    .Buffer => {
                        const lua_buf = L.tobuffer(index).?;
                        if (lua_buf.len < size)
                            return L.LerrorL("Buffer Too Small", .{});
                        if (isFloat) {
                            if (size == 4)
                                return @bitCast(std.mem.readVarInt(u32, lua_buf[0..size], cpu_endian));
                            return @as(f64, @bitCast(std.mem.readVarInt(u64, lua_buf[0..size], cpu_endian)));
                        } else return std.mem.readVarInt(T, lua_buf[0..size], cpu_endian);
                    },
                    else => L.LerrorL("Invalid Argument Type", .{}),
                }
            }
        }.inner;
    }

    fn FFIArgumentPush(comptime T: type) fn (L: *VM.lua.State, value: T) callconv(.C) void {
        const ti = @typeInfo(T);
        if (ti != .int and ti != .float)
            @compileError("Unsupported type");
        const isFloat = ti == .float;
        const size = @sizeOf(T);
        return struct {
            fn inner(L: *VM.lua.State, value: T) callconv(.C) void {
                switch (size) {
                    1...4 => {
                        if (isFloat)
                            L.pushnumber(@floatCast(value))
                        else
                            L.pushinteger(@intCast(value));
                    },
                    8 => {
                        if (isFloat)
                            L.pushnumber(value)
                        else
                            L.Zpushbuffer(&@as([8]u8, @bitCast(value)));
                    },
                    else => @compileError("Unsupported size"),
                }
            }
        }.inner;
    }

    pub const checki8 = FFIArgumentLoad(i8);
    pub const checku8 = FFIArgumentLoad(u8);
    pub const checki16 = FFIArgumentLoad(i16);
    pub const checku16 = FFIArgumentLoad(u16);
    pub const checki32 = FFIArgumentLoad(i32);
    pub const checku32 = FFIArgumentLoad(u32);
    pub const checki64 = FFIArgumentLoad(i64);
    pub const checku64 = FFIArgumentLoad(u64);
    pub const checkf32 = FFIArgumentLoad(f32);
    pub const checkf64 = FFIArgumentLoad(f64);

    pub const pushi8 = FFIArgumentPush(i8);
    pub const pushu8 = FFIArgumentPush(u8);
    pub const pushi16 = FFIArgumentPush(i16);
    pub const pushu16 = FFIArgumentPush(u16);
    pub const pushi32 = FFIArgumentPush(i32);
    pub const pushu32 = FFIArgumentPush(u32);
    pub const pushi64 = FFIArgumentPush(i64);
    pub const pushu64 = FFIArgumentPush(u64);
    pub const pushf32 = FFIArgumentPush(f32);
    pub const pushf64 = FFIArgumentPush(f64);

    pub fn pushpointer(L: *VM.lua.State, ptr: ?*anyopaque) callconv(.c) void {
        _ = LuaPointer.newStaticPtr(L, ptr, false) catch L.LerrorL("Failed to create pointer", .{});
    }

    pub fn pushmem(L: *VM.lua.State, ptr: [*c]u8, size: usize) callconv(.c) void {
        L.Zpushbuffer(ptr[0..size]);
    }
};

fn ffi_struct(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);

    const allocator = luau.getallocator(L);

    var struct_map = std.StringArrayHashMap(DataType).init(allocator);
    errdefer struct_map.deinit();
    errdefer {
        var iter = struct_map.iterator();
        while (iter.next()) |entry|
            allocator.free(entry.key_ptr.*);
    }

    var order: i32 = 1;
    L.pushnil();
    while (L.next(1)) {
        if (L.typeOf(-2) != .Number)
            return error.InvalidIndex;
        const index = L.tointeger(-2) orelse unreachable;
        if (index != order)
            return error.InvalidIndexOrder;

        if (L.typeOf(-1) != .Table)
            return error.InvalidValue;

        L.pushnil();
        if (!L.next(-2))
            return error.InvalidValue;

        if (L.typeOf(-2) != .String)
            return error.InvalidFieldName;
        const name = L.tostring(-2) orelse unreachable;

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

    const data = L.newuserdatataggedwithmetatable(LuaStructType, tagged.FFI_STRUCT);

    const datatype, const offsets = try makeStruct(allocator, struct_map.values());

    data.* = .{
        .type = datatype,
        .offsets = offsets,
        .fields_map = struct_map,
    };

    return 1;
}

fn generateExported(source: *std.ArrayList(u8), name: []const u8, ret_type: []const u8, symbol_args: []const []const u8) !void {
    const writer = source.writer();

    try writer.print((if (builtin.os.tag == .windows) "__declspec(dllimport) " else "extern "), .{});
    try writer.print("{s} {s}", .{ ret_type, name });

    if (symbol_args.len > 0) {
        try source.appendSlice("(");
        for (symbol_args, 0..) |arg, i| {
            if (i != 0)
                try source.appendSlice(", ");
            try writer.print("{s}", .{arg});
        }
        try source.appendSlice(")");
    }

    try source.appendSlice(";\n");
}

fn generateTypeFromSymbol(source: *std.ArrayList(u8), symbol: DataType, order: usize, comptime pointer: bool) !void {
    const writer = source.writer();

    if (order == 0) {
        if (symbol.kind == .@"struct")
            try writer.print("struct anon_ret" ++ if (pointer) "*" else "", .{})
        else
            try DataTypes.generateCTypeName(symbol, writer, 0, pointer);
    } else {
        try DataTypes.generateCTypeName(symbol, writer, order - 1, pointer);
    }
}

fn generateTypesFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []const DataType) !void {
    const writer = source.writer();
    if (symbol_returns.kind == .@"struct")
        try writer.print("struct anon_ret {{ unsigned char _[{d}]; }};\n", .{symbol_returns.size});

    for (symbol_args, 0..) |arg, i| {
        if (arg.kind != .@"struct")
            continue;

        try writer.print("struct anon_{d} {{ unsigned char _[{d}]; }};\n", .{ i, arg.size });
    }

    try source.appendSlice("typedef ");
    try generateTypeFromSymbol(source, symbol_returns, 0, false);
    try source.appendSlice(" (*Fn)(");
    for (symbol_args, 0..) |arg, i| {
        if (i != 0)
            try source.appendSlice(", ");
        try generateTypeFromSymbol(source, arg, i + 1, false);
    }
    try source.appendSlice(");");
    try source.append('\n');
}

fn generateSourceFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []const DataType) !void {
    const writer = source.writer();

    try generateTypesFromSymbol(source, symbol_returns, symbol_args);

    try source.appendSlice("void call_fn_ffi(void* L, Fn fn, void** pointers) {\n  ");
    if (symbol_returns.size > 0) {
        try generateTypeFromSymbol(source, symbol_returns, 0, false);
        try source.appendSlice(" ret = ");
    }
    try source.appendSlice("fn(");
    if (symbol_args.len > 0) {
        var order: usize = 0;
        for (symbol_args, 0..) |arg, i| {
            if (i != 0)
                try source.append(',');
            switch (arg.kind) {
                .void => return error.VoidParameter,
                .pointer => {
                    defer order += 1;
                    try writer.print("\n    (", .{});
                    try generateTypeFromSymbol(source, arg, i + 1, false);
                    try writer.print(")pointers[{d}]", .{order});
                },
                .@"struct" => {
                    defer order += 1;
                    try writer.print("\n    *((", .{});
                    try generateTypeFromSymbol(source, arg, i + 1, true);
                    try writer.print(")pointers[{d}])", .{order});
                },
                inline else => |_, T| try writer.print("\n    lua_ffi_check{s}(L, {d})", .{ @tagName(T), i + 1 }),
            }
        }
        try source.appendSlice("\n  ");
    }
    try source.appendSlice(");\n");

    switch (symbol_returns.kind) {
        .void => {},
        .@"struct" => try writer.print("  lua_ffi_pushmem(L, (unsigned char*)&ret, {d});\n", .{symbol_returns.size}),
        inline else => |_, T| try writer.print("  lua_ffi_push{s}(L, ret);\n", .{@tagName(T)}),
    }

    try source.appendSlice("}\n");
}

fn dynamicLoadImport(source: *std.ArrayList(u8), state: *tinycc.TCCState, returns: DataType, args: []const DataType) !usize {
    const types_len = @typeInfo(ffi_c_interface).@"struct".decls.len;
    var loaded_fn: [types_len]bool = ([_]bool{false} ** types_len);
    var pointers: usize = 0;
    for (args) |arg| {
        switch (arg.kind) {
            .void => return error.VoidParameter,
            .pointer, .@"struct" => {
                defer pointers += 1;
            },
            inline else => |_, T| {
                const declname = "check" ++ @tagName(T);
                inline for (@typeInfo(ffi_c_interface).@"struct".decls, 0..) |decl, i| {
                    if (std.mem.eql(u8, decl.name, declname)) {
                        const checkfn = @field(ffi_c_interface, decl.name);
                        if (loaded_fn[i])
                            break;
                        loaded_fn[i] = true;
                        try generateExported(source, "lua_ffi_" ++ declname, T.typeName(), &.{ "void*", "unsigned int" });
                        _ = state.add_symbol("lua_ffi_" ++ declname, @ptrCast(@alignCast(&checkfn)));
                        break;
                    }
                }
            },
        }
    }

    switch (returns.kind) {
        .void => {},
        .@"struct" => {
            try generateExported(source, "lua_ffi_pushmem", "void", &.{ "void*", "unsigned char*", "unsigned long long" });
            _ = state.add_symbol("lua_ffi_pushmem", @ptrCast(@alignCast(&ffi_c_interface.pushmem)));
        },
        inline else => |_, T| {
            const declname = "push" ++ @tagName(T);
            const pushfn = @field(ffi_c_interface, declname);
            try generateExported(source, "lua_ffi_" ++ declname, "void", &.{ "void*", T.typeName() });
            _ = state.add_symbol("lua_ffi_" ++ declname, @ptrCast(@alignCast(&pushfn)));
        },
    }

    return pointers;
}

fn ffi_dlopen(L: *VM.lua.State) !i32 {
    const path = try L.Zcheckvalue([]const u8, 1, null);

    const allocator = luau.getallocator(L);

    try L.Zchecktype(2, .Table);

    var func_map = std.StringArrayHashMap(FunctionSymbol).init(allocator);
    defer func_map.deinit();
    defer {
        var iter = func_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.args);
        }
    }

    L.pushnil();
    while (L.next(2)) : (L.pop(1)) {
        if (L.typeOf(-2) != .String)
            return error.InvalidName;
        if (L.typeOf(-1) != .Table)
            return error.InvalidValue;

        const name = L.tostring(-2) orelse unreachable;

        _ = L.getfield(-1, "returns");
        if (!isFFIType(L, -1))
            return error.InvalidReturnType;
        const returns_ffi_type = try toFFIType(L, -1);
        L.pop(1); // drop: returns

        if (L.getfield(-1, "args") != .Table)
            return error.InvalidArgs;

        const args_len = L.objlen(-1);

        const args = try allocator.alloc(DataType, @intCast(args_len));
        errdefer allocator.free(args);

        var order: usize = 0;
        L.pushnil();
        while (L.next(-2)) : (L.pop(1)) {
            if (L.typeOf(-2) != .Number)
                return error.InvalidArgOrder;
            if (!isFFIType(L, -1))
                return error.InvalidArgType;

            const index = L.tointeger(-2) orelse unreachable;
            if (index != order + 1)
                return error.InvalidArgOrder;

            args[order] = try toFFIType(L, -1);
            if (args[order].size == 0)
                return error.VoidArg;

            order += 1;
        }
        L.pop(1); // drop: args

        const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
        errdefer allocator.free(name_copy);
        try func_map.put(name_copy, .{
            .returns = returns_ffi_type,
            .args = args,
        });
    }

    const ptr = L.newuserdatadtor(LuaHandle, LuaHandle.__dtor);

    ptr.* = .{
        .lib = undefined,
        .open = false,
    };

    var lib = try std.DynLib.open(path);

    ptr.lib = lib;
    ptr.open = true;

    L.createtable(0, 2);

    L.createtable(0, @intCast(func_map.count()));
    while (func_map.pop()) |entry| {
        const key = entry.key;
        const value = entry.value;
        defer allocator.free(key);
        defer allocator.free(value.args);
        const namez = try allocator.dupeZ(u8, key);
        defer allocator.free(namez);
        const func = lib.lookup(*anyopaque, namez) orelse {
            std.debug.print("Symbol not found: {s}\n", .{key});
            return error.SymbolNotFound;
        };

        const code = try fetchCallableFunction(value.returns, value.args);
        errdefer code.unref();

        const pointers = code.pointers;

        // Allocate space for the pointers
        const ffi_pointers: ?[]*allowzero anyopaque = if (pointers > 0) try allocator.alloc(*allowzero anyopaque, pointers) else null;
        errdefer if (ffi_pointers) |arr| allocator.free(arr);

        // Zig owned string to prevent GC from Lua owned strings
        L.pushlstring(key);

        const data = L.newuserdatadtor(FFIFunction, FFIFunction.__dtor);
        data.* = .{
            .allocator = allocator,
            .pointers = ffi_pointers,
            .lib = ptr,
            .callable = @ptrCast(@alignCast(code.getSymbol())),
            .code = code,
            .ptr = func,
        };
        L.pushvalue(-5);
        L.pushcclosure(VM.zapi.toCFn(FFIFunction.fn_inner), "ffi_func", 2);
        L.settable(-3);
    }
    L.setfield(-2, luau.Metamethods.index);

    L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaHandle.__namecall);
    L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

    _ = L.setmetatable(-2);

    return 1;
}

fn FFIReturnTypeConversion(
    comptime T: type,
    ret_ptr: *anyopaque,
    L: *VM.lua.State,
) void {
    const isFloat = @typeInfo(T) == .float;
    const size = @sizeOf(T);
    const mem = @as([*]u8, @ptrCast(@alignCast(ret_ptr)))[0..size];
    switch (L.typeOf(-1)) {
        .Number => {
            const value = if (isFloat) L.tonumber(-1) orelse unreachable else L.tointeger(-1) orelse unreachable;
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return std.debug.panic("Out of range ('{s}')", .{@typeName(T)});
            var bytes: [size]u8 = @bitCast(@as(T, if (isFloat) @floatCast(value) else @intCast(value)));
            @memcpy(mem, &bytes);
        },
        .Boolean => {
            var bytes: [size]u8 = @bitCast(@as(T, if (L.toboolean(-1) == true) 1 else 0));
            @memcpy(mem, &bytes);
        },
        .Buffer => {
            const lua_buf = L.tobuffer(-1) orelse unreachable;
            if (lua_buf.len < size)
                return std.debug.panic("Small buffer ('{s}')", .{@typeName(T)});
            @memcpy(mem, lua_buf[0..size]);
        },
        else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@typeName(T)}),
    }
}

fn FFIPushPtrType(
    comptime T: type,
    L: *VM.lua.State,
    ptr: *anyopaque,
) void {
    switch (@typeInfo(T)) {
        .int => |int| {
            if (int.bits > 32) {
                const bytes: [@divExact(int.bits, 8)]u8 = @bitCast(@as(*T, @ptrCast(@alignCast(ptr))).*);
                L.Zpushbuffer(&bytes);
                return;
            }
            if (int.signedness == .signed)
                L.pushinteger(@intCast(@as(*T, @ptrCast(@alignCast(ptr))).*))
            else
                L.pushunsigned(@intCast(@as(*T, @ptrCast(@alignCast(ptr))).*));
        },
        .float => {
            if (T == f32)
                L.pushnumber(@floatCast(@as(T, @bitCast(@as(*u32, @ptrCast(@alignCast(ptr))).*))))
            else
                L.pushnumber(@as(T, @bitCast(@as(*u64, @ptrCast(@alignCast(ptr))).*)));
        },
        else => @compileError("Unsupported type"),
    }
}

fn ffi_closure_inner(cif: *LuaClosure.CallInfo, extern_args: [*]?*anyopaque, ret: ?*anyopaque) callconv(.c) void {
    const args = extern_args[0..cif.args];

    const subthread = cif.thread.newthread();
    defer cif.thread.pop(1);
    cif.thread.xpush(subthread, 1);

    for (cif.type.args, 0..) |arg_type, i| {
        switch (arg_type.kind) {
            .void => unreachable,
            .pointer => _ = LuaPointer.newStaticPtr(subthread, @as(*[*]u8, @ptrCast(@alignCast(args[i]))).*, false) catch |err| std.debug.panic("Failed: {}", .{err}),
            .@"struct" => {
                const bytes: [*]u8 = @ptrCast(@alignCast(args[i]));
                subthread.Zpushbuffer(bytes[0..arg_type.size]);
            },
            inline else => |_, tag| FFIPushPtrType(tag.asType(), subthread, args[i].?),
        }
    }

    const has_return = cif.type.returns.size > 0;

    _ = subthread.pcall(@intCast(args.len), if (has_return) 1 else 0, 0).check() catch {
        std.debug.panic("C Closure Runtime Error: {s}", .{subthread.tostring(-1) orelse "UnknownError"});
    };

    if (ret) |ret_ptr| {
        defer subthread.pop(1);
        switch (cif.type.returns.kind) {
            .void => unreachable,
            .pointer => switch (subthread.typeOf(-1)) {
                .Userdata => {
                    const ptr = LuaPointer.value(subthread, -1) orelse std.debug.panic("Invalid pointer", .{});
                    if (ptr.destroyed or ptr.ptr == null)
                        std.debug.panic("No address available", .{});
                    @as(*[*]u8, @ptrCast(@alignCast(ret_ptr))).* = @ptrCast(ptr.ptr);
                },
                .String => std.debug.panic("Unsupported return type (use a pointer to a buffer instead)", .{}),
                .Nil => {
                    @as(*?*anyopaque, @ptrCast(@alignCast(ret_ptr))).* = null;
                },
                else => return std.debug.panic("Invalid return type (expected buffer/nil for '*anyopaque')", .{}),
            },
            .@"struct" => {
                if (subthread.typeOf(-1) != .Buffer)
                    return std.debug.panic("Invalid return type (expected buffer for struct)", .{});
                const buf = subthread.tobuffer(-1) orelse unreachable;
                if (buf.len != cif.type.returns.size)
                    return std.debug.panic("Invalid return type (expected buffer of size {d} for struct)", .{cif.type.returns.size});
                @memcpy(@as([*]u8, @ptrCast(@alignCast(ret_ptr))), buf);
            },
            inline else => |_, T| FFIReturnTypeConversion(T.asType(), ret_ptr, subthread),
        }
    }
}

fn ffi_closure(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    try L.Zchecktype(2, .Function);

    const allocator = luau.getallocator(L);

    var symbol_returns: DataType = DataTypes.Types.type_void;
    var args = std.ArrayList(DataType).init(allocator);
    defer args.deinit();

    _ = L.getfield(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    symbol_returns = try toFFIType(L, -1);
    L.pop(1);

    if (L.getfield(1, "args") != .Table)
        return error.InvalidArgs;

    var order: usize = 0;
    L.pushnil();
    while (L.next(-2)) {
        if (L.typeOf(-2) != .Number)
            return error.InvalidArgOrder;
        if (!isFFIType(L, -1))
            return error.InvalidArgType;

        const index = L.tointeger(-2) orelse unreachable;
        if (index != order + 1)
            return error.InvalidArgOrder;

        const t = try toFFIType(L, -1);

        if (t.size == 0)
            return error.VoidArg;

        try args.append(t);

        order += 1;
        L.pop(1);
    }

    const symbol_args = try args.toOwnedSlice();
    errdefer allocator.free(symbol_args);

    const state = try tinycc.new();
    errdefer state.deinit();

    state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
    state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

    var source = std.ArrayList(u8).init(allocator);
    defer source.deinit();
    const writer = source.writer();

    try generateExported(&source, "external_call", "void", &.{ "void*", "void**", "void*" });
    try generateExported(&source, "external_ptr", "void*", &.{});

    try writer.print("\n", .{});

    try generateTypesFromSymbol(&source, symbol_returns, symbol_args);

    try generateTypeFromSymbol(&source, symbol_returns, 0, false);
    try source.appendSlice(" call_closure_ffi(");
    for (symbol_args, 0..) |arg, i| {
        if (i != 0)
            try source.appendSlice(", ");
        try generateTypeFromSymbol(&source, arg, i + 1, false);
        try writer.print(" arg_{d}", .{i});
    }
    try source.appendSlice(") {\n  ");
    if (symbol_args.len > 0) {
        try writer.print("void* args[{d}];\n  ", .{symbol_args.len});
    }
    if (symbol_returns.size > 0) {
        try generateTypeFromSymbol(&source, symbol_returns, 0, false);
        try source.appendSlice(" ret;\n  ");
    }

    for (symbol_args, 0..) |_, i| {
        try writer.print("args[{d}] = (void*)&arg_{d};\n  ", .{ i, i });
    }

    try writer.print("external_call(&external_ptr, args, (void*)&ret);\n  ", .{});
    try writer.print("return ret;\n}}\n", .{});

    const call_ptr = try allocator.create(LuaClosure.CallInfo);
    errdefer allocator.destroy(call_ptr);

    call_ptr.* = .{
        .args = @intCast(symbol_args.len),
        .thread = undefined,
        .type = .{
            .returns = symbol_returns,
            .args = symbol_args,
        },
    };

    _ = state.add_symbol("external_ptr", @ptrCast(@alignCast(call_ptr)));
    _ = state.add_symbol("external_call", @ptrCast(@alignCast(&ffi_closure_inner)));

    const block = state.compileStringOnceAlloc(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    const callable = state.get_symbol("call_closure_ffi") orelse return error.BadCompilation;

    const thread = L.newthread();
    L.xpush(thread, 2);

    call_ptr.thread = thread;

    const data = L.newuserdatadtor(LuaClosure, LuaClosure.__dtor);

    data.* = .{
        .allocator = allocator,
        .callinfo = call_ptr,
        .callable = @ptrCast(@alignCast(callable)),
        .thread = thread,
        .ptr = @ptrCast(@alignCast(call_ptr)),
        .sym = .{
            .state = state,
            .block = block,
            .type = .{
                .returns = symbol_returns,
                .args = symbol_args,
            },
        },
    };

    L.createtable(0, 2);

    L.createtable(0, 1);
    {
        L.pushvalue(2);
        L.setfield(-2, "callback");
    }
    L.setfield(-2, luau.Metamethods.index);

    L.pushvalue(-3);
    L.setfield(-2, "thread");

    L.setreadonly(-1, true);

    _ = L.setmetatable(-2);

    const ptr = try LuaPointer.newStaticPtrWithRef(L, data.callable, -1);
    ptr.size = 0;

    return 1;
}

const FFIFunction = struct {
    allocator: std.mem.Allocator,
    code: *CallableFunction,
    ptr: *anyopaque,
    pointers: ?[]*allowzero anyopaque,
    lib: ?*LuaHandle = null,

    callable: FFICallable,

    pub const FFICallable = *const fn (lua_State: *anyopaque, fnPtr: *anyopaque, pointers: ?[*]*allowzero anyopaque) callconv(.c) void;

    pub fn fn_inner(L: *VM.lua.State) !i32 {
        const allocator = luau.getallocator(L);
        const self = L.touserdata(FFIFunction, VM.lua.upvalueindex(1)) orelse unreachable;

        if (self.lib) |lib|
            if (!lib.open)
                return error.LibraryNotOpen;

        const callable = self.callable;

        if (L.gettop() < self.code.sym.type.args.len)
            return L.Zerror("Invalid number of arguments");

        var arena: ?std.heap.ArenaAllocator = null;
        defer if (arena) |a| a.deinit();

        const pointers = self.pointers;
        if (pointers) |ptrs| {
            arena = std.heap.ArenaAllocator.init(allocator);
            const arena_allocator = arena.?.allocator();
            var order: usize = 0;
            for (self.code.sym.type.args, 1..) |arg, i| {
                switch (arg.kind) {
                    .pointer => {
                        defer order += 1;
                        const idx: i32 = @intCast(i);
                        switch (L.typeOf(idx)) {
                            .Userdata => {
                                const ptr = LuaPointer.value(L, idx) orelse return error.Fail;
                                if (ptr.destroyed)
                                    return error.NoAddressAvailable;
                                ptrs[order] = @ptrCast(@alignCast(ptr.ptr));
                            },
                            .String => {
                                const str: [:0]const u8 = L.tostring(idx).?;
                                const dup = try arena_allocator.dupeZ(u8, str);
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Buffer => {
                                const buf = L.tobuffer(idx).?;
                                const dup = try arena_allocator.dupe(u8, buf);
                                ptrs[order] = @ptrCast(@alignCast(dup.ptr));
                            },
                            .Nil => ptrs[order] = @ptrFromInt(0),
                            else => return error.InvalidArgType,
                        }
                    },
                    .@"struct" => {
                        defer order += 1;
                        const idx: i32 = @intCast(i);
                        if (L.typeOf(idx) != .Buffer)
                            return error.InvalidArgType;
                        const buf = L.tobuffer(idx).?;
                        const mem: []u8 = try arena_allocator.alloc(u8, arg.size);
                        if (buf.len != mem.len)
                            return error.InvalidStructSize;
                        @memcpy(mem, buf);
                        ptrs[order] = @ptrCast(@alignCast(mem.ptr));
                    },
                    else => {},
                }
            }
        }

        callable(
            @ptrCast(@alignCast(L)),
            self.ptr,
            if (pointers) |ptrs| @ptrCast(@alignCast(ptrs.ptr)) else null,
        );

        if (self.code.sym.type.returns.size > 0)
            return 1;
        return 0;
    }

    pub fn __dtor(self: *FFIFunction) void {
        const allocator = self.allocator;

        if (self.pointers) |ptrs|
            allocator.free(ptrs);

        self.code.unref();
    }
};

fn ffi_fn(L: *VM.lua.State) !i32 {
    try L.Zchecktype(1, .Table);
    const src = LuaPointer.value(L, 2) orelse return error.Failed;
    switch (src.type) {
        .Allocated => return error.PointerNotCallable,
        else => {},
    }
    const ptr: *anyopaque = src.ptr orelse return error.NoAddressAvailable;

    const allocator = luau.getallocator(L);

    var symbol_returns: DataType = DataTypes.Types.type_void;
    var args = std.ArrayList(DataType).init(allocator);
    defer args.deinit();

    _ = L.getfield(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    symbol_returns = try toFFIType(L, -1);
    L.pop(1);

    if (L.getfield(1, "args") != .Table)
        return error.InvalidArgs;

    var order: usize = 0;
    L.pushnil();
    while (L.next(-2)) {
        if (L.typeOf(-2) != .Number)
            return error.InvalidArgOrder;
        if (!isFFIType(L, -1))
            return error.InvalidArgType;

        const index = L.tointeger(-2) orelse unreachable;
        if (index != order + 1)
            return error.InvalidArgOrder;

        const t = try toFFIType(L, -1);

        if (t.size == 0)
            return error.VoidArg;

        try args.append(t);

        order += 1;
        L.pop(1);
    }

    const code = try fetchCallableFunction(symbol_returns, args.items);
    errdefer code.unref();
    const pointers = code.pointers;

    // Allocate space for the pointers
    const ffi_pointers: ?[]*allowzero anyopaque = if (pointers > 0) try allocator.alloc(*allowzero anyopaque, pointers) else null;
    errdefer if (ffi_pointers) |arr| allocator.free(arr);

    const data = L.newuserdatadtor(FFIFunction, FFIFunction.__dtor);

    data.* = .{
        .allocator = allocator,
        .pointers = ffi_pointers,
        .callable = @ptrCast(@alignCast(code.getSymbol())),
        .code = code,
        .ptr = ptr,
    };

    L.pushcclosure(VM.zapi.toCFn(FFIFunction.fn_inner), "ffi_fn", 1);

    return 1;
}

fn ffi_copy(L: *VM.lua.State) !i32 {
    const target_offset: usize = @intFromFloat(L.Lchecknumber(2));
    var target_bounds: ?usize = null;
    const target: [*]u8 = blk: {
        switch (L.typeOf(1)) {
            .Buffer => {
                const buf = L.tobuffer(1) orelse unreachable;
                target_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .Userdata => {
                const ptr = LuaPointer.value(L, 1) orelse return L.Zerror("Invalid pointer");
                if (ptr.destroyed or ptr.ptr == null)
                    return L.Zerror("No address available");
                target_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => return L.Zerror("Invalid type (expected buffer or userdata)"),
        }
    };
    const src_offset: usize = @intFromFloat(L.Lchecknumber(4));
    var src_bounds: ?usize = null;
    const src: [*]u8 = blk: {
        switch (L.typeOf(3)) {
            .Buffer => {
                const buf = L.tobuffer(3) orelse unreachable;
                src_bounds = buf.len;
                break :blk @ptrCast(@alignCast(buf.ptr));
            },
            .Userdata => {
                const ptr = LuaPointer.value(L, 3) orelse return L.Zerror("Invalid pointer");
                if (ptr.destroyed or ptr.ptr == null)
                    return L.Zerror("No address available");
                src_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => return L.Zerror("Invalid type (expected buffer or userdata)"),
        }
    };
    const len: usize = @intCast(try L.Zcheckvalue(i32, 5, null));

    if (target_bounds) |bounds| if (target_offset + len > bounds)
        return L.Zerror("Target OutOfBounds");

    if (src_bounds) |bounds| if (src_offset + len > bounds)
        return L.Zerror("Source OutOfBounds");

    @memcpy(target[target_offset .. target_offset + len], src[src_offset .. src_offset + len]);

    return 0;
}

fn ffi_sizeOf(L: *VM.lua.State) !i32 {
    const t = try toFFIType(L, 1);
    L.pushinteger(@intCast(t.size));
    return 1;
}

fn ffi_alignOf(L: *VM.lua.State) !i32 {
    const t = try toFFIType(L, 1);
    L.pushinteger(@intCast(t.alignment));
    return 1;
}

fn ffi_unsupported(L: *VM.lua.State) !i32 {
    return L.Zerror("ffi is not supported on this platform");
}

fn ffi_alloc(L: *VM.lua.State) !i32 {
    const len: usize = @intFromFloat(L.Lchecknumber(1));
    _ = try LuaPointer.allocBlockPtr(L, len);
    return 1;
}

fn ffi_free(L: *VM.lua.State) !i32 {
    const ptr = LuaPointer.value(L, 1) orelse return L.Zerror("Invalid pointer");
    if (!ptr.destroyed) {
        const allocator = luau.getallocator(L);
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
                    if (size > 0)
                        allocator.free(@as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size]);
                }
            },
        }
    } else return L.Zerror("Double free");
    return 0;
}

fn ffi_len(L: *VM.lua.State) !i32 {
    switch (L.typeOf(1)) {
        .Buffer => {
            const buf = L.tobuffer(1) orelse unreachable;
            L.pushinteger(@intCast(buf.len));
        },
        .Userdata => {
            const ptr = LuaPointer.value(L, 1) orelse return L.Zerror("Invalid pointer");
            if (ptr.destroyed or ptr.ptr == null)
                return L.Zerror("No address available");
            if (ptr.size) |size|
                L.pushinteger(@intCast(size))
            else
                L.pushnil();
        },
        else => return L.Zerror("Invalid type (expected buffer or userdata)"),
    }
    return 1;
}

fn ffi_dupe(L: *VM.lua.State) !i32 {
    switch (L.typeOf(1)) {
        .Buffer => {
            const buf = L.tobuffer(1) orelse unreachable;
            const ptr = try LuaPointer.allocBlockPtr(L, buf.len);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..buf.len],
                buf,
            );
        },
        .Userdata => {
            const ptr = LuaPointer.value(L, 1) orelse return error.Fail;
            if (ptr.destroyed or ptr.ptr == null)
                return error.NoAddressAvailable;
            const len = ptr.size orelse return L.Zerror("Unknown sized pointer");
            const dup_ptr = try LuaPointer.allocBlockPtr(L, len);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(dup_ptr.ptr)))[0..len],
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..len],
            );
        },
        else => return L.Zerror("Invalid type (expected buffer or userdata)"),
    }
    return 1;
}

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Lnewmetatable(LuaStructType.META);

        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaStructType.__namecall); // metatable.__namecall

        L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.setuserdatadtor(LuaStructType, tagged.FFI_STRUCT, LuaStructType.__dtor);
        L.setuserdatametatable(tagged.FFI_STRUCT, -1);
    }
    {
        _ = L.Lnewmetatable(LuaPointer.META);

        L.Zsetfieldfn(-1, luau.Metamethods.eq, LuaPointer.__eq); // metatable.__eq
        L.Zsetfieldfn(-1, luau.Metamethods.namecall, LuaPointer.__namecall); // metatable.__namecall
        L.Zsetfieldfn(-1, luau.Metamethods.tostring, LuaPointer.__tostring); // metatable.__tostring

        L.setuserdatadtor(LuaPointer, tagged.FFI_POINTER, LuaPointer.__dtor);
        L.setuserdatametatable(tagged.FFI_POINTER, -1);
    }

    L.createtable(0, 17);

    L.Zsetfieldfn(-1, "dlopen", ffi_dlopen);
    L.Zsetfieldfn(-1, "struct", ffi_struct);
    L.Zsetfieldfn(-1, "closure", ffi_closure);
    L.Zsetfieldfn(-1, "fn", ffi_fn);
    L.Zsetfield(-1, "supported", true);

    L.Zsetfieldfn(-1, "sizeOf", ffi_sizeOf);
    L.Zsetfieldfn(-1, "alignOf", ffi_alignOf);

    L.Zsetfieldfn(-1, "alloc", ffi_alloc);
    L.Zsetfieldfn(-1, "free", ffi_free);
    L.Zsetfieldfn(-1, "copy", ffi_copy);
    L.Zsetfieldfn(-1, "len", ffi_len);
    L.Zsetfieldfn(-1, "dupe", ffi_dupe);

    L.Zsetfieldfn(-1, "getRef", LuaPointer.getRef);
    L.Zsetfieldfn(-1, "createPtr", LuaPointer.ptrFromBuffer);

    L.createtable(0, @intCast(@typeInfo(DataTypes.Types).@"struct".decls.len));
    inline for (@typeInfo(DataTypes.Types).@"struct".decls, 0..) |decl, i| {
        L.pushstring(decl.name[5..]);
        L.pushlightuserdatatagged(@constCast(@ptrCast(@alignCast(DataTypes.order[i]))), tagged.FFI_STRUCT);
        L.settable(-3);
    }
    L.setreadonly(-1, true);
    L.setfield(-2, "types");

    switch (builtin.os.tag) {
        .linux => L.pushstring("so"),
        .macos => L.pushstring("dylib"),
        .windows => L.pushstring("dll"),
        else => L.pushstring(""),
    }
    L.setfield(-2, "suffix");

    switch (builtin.os.tag) {
        .windows => L.pushstring(""),
        else => L.pushstring("lib"),
    }
    L.setfield(-2, "prefix");

    L.setreadonly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "ffi" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"ffi.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total >= 0);
}
