const std = @import("std");
const tinycc = @import("tinycc");
const luau = @import("luau");
const builtin = @import("builtin");

const Engine = @import("../runtime/engine.zig");
const Scheduler = @import("../runtime/scheduler.zig");

const luaHelper = @import("../utils/luahelper.zig");
const tagged = @import("../../tagged.zig");

const Luau = luau.Luau;

pub const LIB_NAME = "ffi";

const cpu_endian = builtin.cpu.arch.endian();

inline fn intOutOfRange(comptime T: type, value: anytype) bool {
    return value < std.math.minInt(T) or value > std.math.maxInt(T);
}

inline fn floatOutOfRange(comptime T: type, value: f64) bool {
    return value < -std.math.floatMax(T) or value > std.math.floatMax(T);
}

pub const DataType = struct {
    size: usize,
    alignment: u29,
    kind: ?TypeKind = null,
    offsets: ?[]const usize = null,
    fields: ?[]const DataType = null,

    pub const TypeKind = enum {
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

        pub fn asType(self: TypeKind) type {
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
            }
        }
    };

    pub inline fn isConst(self: DataType) bool {
        return self.kind != null;
    }
    pub inline fn isStruct(self: DataType) bool {
        return self.offsets != null;
    }
    pub inline fn isSigned(self: DataType) bool {
        if (self.kind == null)
            return false;
        return switch (self.kind) {
            .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }
    pub inline fn isFloat(self: DataType) bool {
        if (self.kind == null)
            return false;
        return switch (self.kind) {
            .f32, .f64 => true,
            else => false,
        };
    }
    pub fn free(self: DataType, allocator: std.mem.Allocator) void {
        if (self.offsets) |offsets|
            allocator.free(offsets);
        if (self.fields) |fields|
            allocator.free(fields);
    }
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
        pub const type_pointer = DataType{ .size = 8, .alignment = 8, .kind = .pointer };
    };

    pub const order: []const *const DataType = &.{
        &Types.type_void,  &Types.type_i8,     &Types.type_i16,
        &Types.type_i32,   &Types.type_i64,    &Types.type_u8,
        &Types.type_u16,   &Types.type_u32,    &Types.type_u64,
        &Types.type_float, &Types.type_double, &Types.type_pointer,
    };

    pub fn writeCTypeName(datatype: DataType, writer: anytype, comptime pointer: bool) !void {
        if (datatype.kind) |kind| {
            switch (kind) {
                .void => return try writer.writeAll("void" ++ if (pointer) "*" else ""),
                .i8 => return try writer.writeAll("char" ++ if (pointer) "*" else ""),
                .i16 => return try writer.writeAll("short" ++ if (pointer) "*" else ""),
                .i32 => return try writer.writeAll("int" ++ if (pointer) "*" else ""),
                .i64 => return try writer.writeAll("long long" ++ if (pointer) "*" else ""),
                .u8 => return try writer.writeAll("unsigned char" ++ if (pointer) "*" else ""),
                .u16 => return try writer.writeAll("unsigned short" ++ if (pointer) "*" else ""),
                .u32 => return try writer.writeAll("unsigned int" ++ if (pointer) "*" else ""),
                .u64 => return try writer.writeAll("unsigned long long" ++ if (pointer) "*" else ""),
                .f32 => return try writer.writeAll("float" ++ if (pointer) "*" else ""),
                .f64 => return try writer.writeAll("double" ++ if (pointer) "*" else ""),
                .pointer => return try writer.writeAll("void*" ++ if (pointer) "*" else ""),
            }
        } else {
            return error.Unsupported;
        }
    }

    pub fn IsConstDataType(datatype: *DataType) bool {
        if (datatype.kind != null)
            return true;
        return false;
    }
};

fn alignForward(value: usize, alignment: usize) usize {
    return (value + (alignment - 1)) & ~(@as(usize, alignment - 1));
}

pub fn makeStruct(allocator: std.mem.Allocator, fields: []const DataType) !DataType {
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
    return DataType{ .size = size, .alignment = alignment, .offsets = offsets, .fields = try allocator.dupe(DataType, fields) };
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

        const ptr = L.newUserdataTaggedWithMetatable(LuaPointer, tagged.FFI_POINTER);

        ptr.* = .{
            .ptr = @ptrFromInt(std.mem.readVarInt(usize, buf[0..@sizeOf(usize)], cpu_endian)),
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

        const ptr = L.newUserdataTaggedWithMetatable(LuaPointer, tagged.FFI_POINTER);

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
        const ptr = L.newUserdataTaggedWithMetatable(LuaPointer, tagged.FFI_POINTER);

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

        const ptr = L.newUserdataTaggedWithMetatable(LuaPointer, tagged.FFI_POINTER);

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

    pub fn retain(ptr: *LuaPointer, L: *Luau) !void {
        if (ptr.local_ref != null) {
            ptr.retained = true;
            return;
        }
        const local = try L.ref(-1);
        ptr.retained = true;
        ptr.local_ref = local;
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
        L.pushValue(1);
        try retain(ptr, L);
        return 1;
    }

    pub fn method_release(ptr: *LuaPointer, L: *Luau) i32 {
        ptr.retained = false;
        if (ptr.local_ref) |ref|
            L.unref(ref);
        ptr.local_ref = null;
        L.pushValue(1);
        return 1;
    }

    pub fn method_drop(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        if (ptr.type == .Static)
            return L.Error("Cannot drop a static pointer");
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
        if (ptr.size) |size|
            if (size < offset)
                return L.Error("Offset OutOfBounds");

        const static = try LuaPointer.newStaticPtr(L, @as([*]u8, @ptrCast(ptr.ptr))[offset..], false);

        if (ptr.size) |size|
            static.size = size - offset;

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
                else => return L.Error("Invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(L.checkInteger(5));

        if (dest_bounds) |size| if (size < dest_offset + len)
            return L.Error("Target OutOfBounds");

        if (ptr.size) |size| if (size < src_offset + len)
            return L.Error("Source OutOfBounds");

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
                else => return L.Error("Invalid type (expected buffer or userdata)"),
            }
        };
        const len: usize = @intCast(L.checkInteger(5));

        if (ptr.size) |size| if (size < dest_offset + len)
            return L.Error("Target OutOfBounds");

        if (src_bounds) |size| if (size < src_offset + len)
            return L.Error("Source OutOfBounds");

        const dest: [*]u8 = @ptrCast(@alignCast(ptr.ptr));
        @memcpy(dest[dest_offset .. dest_offset + len], src[src_offset .. src_offset + len]);

        return 0;
    }

    pub fn GenerateReadMethod(comptime T: type) fn (ptr: *LuaPointer, L: *Luau) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot read void type");
        const ti = @typeInfo(T);
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *Luau) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.optInteger(2) orelse 0);

                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: [*]u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset..];

                switch (ti) {
                    .float => switch (len) {
                        4 => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, mem[0..len], cpu_endian))))),
                        8 => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, mem[0..len], cpu_endian)))),
                        else => unreachable,
                    },
                    .int => switch (len) {
                        1 => L.pushInteger(@intCast(@as(T, @bitCast(mem[0])))),
                        2...4 => L.pushInteger(@intCast(std.mem.readVarInt(T, mem[0..len], cpu_endian))),
                        8 => L.pushBuffer(mem[0..len]),
                        else => return error.Unsupported,
                    },
                    .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, mem[0..@sizeOf(usize)], cpu_endian)), false),
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    pub fn GenerateWriteMethod(comptime T: type) fn (ptr: *LuaPointer, L: *Luau) anyerror!i32 {
        if (comptime @sizeOf(T) == 0)
            @compileError("Cannot write void type");
        const ti = @typeInfo(T);
        const len = @sizeOf(T);
        return struct {
            fn inner(ptr: *LuaPointer, L: *Luau) !i32 {
                if (ptr.destroyed or ptr.ptr == null)
                    return error.NoAddressAvailable;
                const offset: usize = @intCast(L.optInteger(2) orelse 0);

                if (ptr.size) |size| if (size < len + offset)
                    return error.OutOfBounds;

                const mem: []u8 = @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[offset .. offset + len];

                switch (ti) {
                    .int, .float => try FFITypeConversion(T, mem, L, 3, 0),
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

    pub fn method_isNull(ptr: *LuaPointer, L: *Luau) i32 {
        if (ptr.destroyed) {
            L.pushBoolean(true);
            return 1;
        }
        L.pushBoolean(ptr.ptr == null);
        return 1;
    }

    pub fn method_setSize(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return L.Error("NoAddressAvailable");
        const size = L.checkNumber(2);
        if (size < 0)
            return L.Error("Size cannot be negative");

        const length: usize = @intFromFloat(size);

        switch (ptr.type) {
            .Allocated => return L.Error("Cannot set size of a known size pointer"),
            .Static => {
                if (ptr.size) |_|
                    return L.Error("Cannot set size of a known size pointer");
            },
        }

        ptr.size = length;

        return 0;
    }

    pub fn method_span(ptr: *LuaPointer, L: *Luau) !i32 {
        if (ptr.destroyed or ptr.ptr == null)
            return 0;
        const src_offset: usize = @intCast(L.optInteger(2) orelse 0);

        const target: [*c]u8 = @ptrCast(@alignCast(ptr.ptr));

        const bytes: [:0]const u8 = std.mem.span(target[src_offset..]);

        const buf = L.newBuffer(bytes.len + 1);
        @memcpy(buf[0..bytes.len], bytes);
        buf[bytes.len] = 0;

        return 1;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaPointer, 1) catch return L.Error("Invalid pointer");

        const namecall = L.nameCallAtom() catch return 0;

        return switch (NamecallMap.get(namecall) orelse return L.ErrorFmt("Unknown method: {s}", .{namecall})) {
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

    pub fn __eq(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr1 = L.toUserdata(LuaPointer, 1) catch return L.Error("Invalid pointer");

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

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaHandle, 1) catch return L.Error("Invalid handle");

        const namecall = L.nameCallAtom() catch return 0;

        if (!ptr.open)
            return L.Error("Library closed");

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
        } else return L.ErrorFmt("Unknown method: {s}", .{namecall});
        return 0;
    }

    pub fn __dtor(ptr: *LuaHandle) void {
        if (ptr.open)
            ptr.lib.close();
        ptr.open = false;
    }
};

const LuaClosure = struct {
    allocator: std.mem.Allocator,
    callinfo: *CallInfo,
    thread: *Luau,
    sym: FFIFunction.FFISymbol,

    callable: *anyopaque,

    pub const CallInfo = struct {
        args: c_uint,
        thread: *Luau,
        type: SymbolFunction,
    };

    pub fn __dtor(ptr: *LuaClosure) void {
        ptr.allocator.destroy(ptr.callinfo);
        ptr.sym.free(ptr.allocator);
    }
};

const LuaStructType = struct {
    type: DataType,
    fields: std.StringArrayHashMap(DataType),

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
        L.pushInteger(@intCast(ptr.type.size));
        return 1;
    }

    pub fn method_alignment(ptr: *LuaStructType, L: *Luau) !i32 {
        L.pushInteger(@intCast(ptr.type.alignment));
        return 1;
    }

    pub fn method_offset(ptr: *LuaStructType, L: *Luau) !i32 {
        const field = L.checkString(2);
        const order = ptr.fields.getIndex(field) orelse return L.ErrorFmt("Unknown field: {s}", .{field});
        L.pushInteger(@intCast(ptr.type.offsets.?[order]));
        return 1;
    }

    pub fn method_new(ptr: *LuaStructType, L: *Luau) !i32 {
        L.checkType(2, .table);
        const allocator = L.allocator();

        const mem = try allocator.alloc(u8, ptr.type.size);
        defer allocator.free(mem);

        @memset(mem, 0);

        for (ptr.fields.keys(), 0..) |field, order| {
            defer L.pop(1);
            L.pushLString(field);
            if (luau.isNoneOrNil(L.getTable(2)))
                return error.MissingField;
            const offset = ptr.type.offsets.?[order];

            const field_type = ptr.type.fields.?[order];
            if (field_type.isConst()) {
                switch (field_type.kind.?) {
                    .void => return error.InvalidArgType,
                    inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f32, .f64 => |T| try FFITypeConversion(T.asType(), mem, L, -1, offset),
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
            } else {
                if (L.typeOf(-1) != .buffer)
                    return error.InvalidArgType;
                const value = L.toBuffer(-1) catch unreachable;
                if (value.len != field_type.size)
                    return error.InvalidArgType;
                @memcpy(mem[offset .. offset + field_type.size], value);
            }
        }

        L.pushBuffer(mem);

        return 1;
    }

    pub fn __namecall(L: *Luau) !i32 {
        L.checkType(1, .userdata);
        const ptr = L.toUserdata(LuaStructType, 1) catch return L.Error("Invalid struct");

        const namecall = L.nameCallAtom() catch return 0;

        return switch (NamecallMap.get(namecall) orelse return L.ErrorFmt("Unknown method: {s}", .{namecall})) {
            .Size => ptr.method_size(L),
            .Alignment => ptr.method_alignment(L),
            .Offset => ptr.method_offset(L),
            .New => ptr.method_new(L),
        };
    }

    pub fn __dtor(_: *Luau, ptr: *LuaStructType) void {
        var iter = ptr.fields.iterator();
        while (iter.next()) |entry|
            ptr.fields.allocator.free(entry.key_ptr.*);
        ptr.type.free(ptr.fields.allocator);
        ptr.fields.deinit();
    }
};

const SymbolFunction = struct {
    returns_type: DataType,
    args_type: []DataType,
};

const FFITypeSize = std.meta.fields(DataType).len;
fn convertToFFIType(number: i32) !DataType {
    if (number < 0 or @as(u32, @intCast(number)) > FFITypeSize)
        return error.InvalidReturnType;
    return @enumFromInt(number);
}

fn isFFIType(L: *Luau, idx: i32) bool {
    switch (L.typeOf(idx)) {
        .userdata => {
            _ = L.toUserdataTagged(LuaStructType, idx, tagged.FFI_STRUCT) catch return false;
            return true;
        },
        .light_userdata => {
            const datatype = L.toUserdata(DataType, idx) catch unreachable;
            if (!DataTypes.IsConstDataType(datatype))
                return false;
            return true;
        },
        else => return false,
    }
}

fn toFFIType(L: *Luau, idx: i32) !DataType {
    switch (L.typeOf(idx)) {
        .userdata => {
            const lua_struct = L.toUserdataTagged(LuaStructType, idx, tagged.FFI_STRUCT) catch return error.InvalidFFIType;
            return lua_struct.*.type;
        },
        .light_userdata => {
            const datatype = L.toUserdata(DataType, idx) catch unreachable;
            if (!DataTypes.IsConstDataType(datatype))
                return error.InvalidFFIType;
            return datatype.*;
        },
        else => return error.InvalidType,
    }
}

pub fn FFITypeConversion(
    comptime T: type,
    mem: []u8,
    L: *Luau,
    index: comptime_int,
    offset: usize,
) !void {
    const ti = @typeInfo(T);
    if (ti != .int and ti != .float)
        @compileError("Unsupported type");
    const isFloat = ti == .float;
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
    comptime T: type,
    allocator: std.mem.Allocator,
    args: [][]u8,
    arg_idx: usize,
    L: *Luau,
    index: i32,
    comptime use_allocated: bool,
) !void {
    const ti = @typeInfo(T);
    if (ti != .int and ti != .float)
        @compileError("Unsupported type");
    const isFloat = ti == .float;
    const size = @sizeOf(T);
    switch (L.typeOf(index)) {
        .number => {
            const value = if (isFloat) L.toNumber(index) catch unreachable else L.toInteger(index) catch unreachable;
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return error.OutOfRange;
            const buf: []u8 = if (use_allocated) args[arg_idx] else try allocator.alloc(u8, size);
            var bytes: [size]u8 = @bitCast(@as(T, if (isFloat) @floatCast(value) else @intCast(value)));
            @memcpy(buf, &bytes);
            if (!use_allocated)
                args[arg_idx] = buf;
        },
        .boolean => {
            const buf: []u8 = if (use_allocated) args[arg_idx] else try allocator.alloc(u8, size);
            var bytes: [size]u8 = @bitCast(@as(T, if (L.toBoolean(index) == true) 1 else 0));
            @memcpy(buf, &bytes);
            if (!use_allocated)
                args[arg_idx] = buf;
        },
        .buffer => {
            const lua_buf = L.toBuffer(index) catch unreachable;
            if (lua_buf.len < size)
                return error.SmallBuffer;
            const buf: []u8 = if (use_allocated) args[arg_idx] else try allocator.alloc(u8, size);
            @memcpy(buf, lua_buf[0..size]);
            if (!use_allocated)
                args[arg_idx] = buf;
        },
        else => return error.InvalidArgType,
    }
}

fn load_ffi_args(
    allocator: std.mem.Allocator,
    L: *Luau,
    arg_types: []DataType,
    start_idx: usize,
    args: [][]u8,
    comptime pre_allocated: bool,
) !void {
    for (0..args.len) |i| {
        const lua_index: i32 = @intCast(start_idx + i);
        const ffitype = arg_types[i];
        if (ffitype.isConst()) {
            switch (ffitype.kind.?) {
                .void => std.debug.panic("Void arg", .{}),
                inline .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f32, .f64 => |T| try FFILoadTypeConversion(T.asType(), allocator, args, i, L, lua_index, pre_allocated),
                .pointer => {
                    switch (L.typeOf(lua_index)) {
                        .userdata => {
                            const ptr = try LuaPointer.value(L, lua_index);
                            if (ptr.destroyed)
                                return error.NoAddressAvailable;
                            const buf: []u8 = if (pre_allocated) args[i] else try allocator.alloc([]u8, @sizeOf(usize));
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(ptr.ptr)));
                            @memcpy(buf, &bytes);
                            if (!pre_allocated)
                                args[i] = buf;
                        },
                        .string => {
                            const str: [:0]const u8 = L.toString(lua_index) catch unreachable;
                            const dup = try allocator.dupeZ(u8, str);
                            errdefer allocator.free(dup);

                            const buf: []u8 = if (pre_allocated) args[i] else try allocator.alloc([]u8, @sizeOf(usize));
                            var bytes: [@sizeOf(usize)]u8 = @bitCast(@as(usize, @intFromPtr(dup.ptr)));
                            @memcpy(buf, &bytes);
                            if (!pre_allocated)
                                args[i] = buf;
                        },
                        .nil => {
                            const buf: []u8 = if (pre_allocated) args[i] else try allocator.alloc([]u8, @sizeOf(usize));
                            @memset(buf, 0);
                            if (!pre_allocated)
                                args[i] = buf;
                        },
                        else => return error.InvalidArgType,
                    }
                },
            }
        } else {
            if (L.typeOf(lua_index) != .buffer)
                return error.InvalidArgType;
            const buf = L.toBuffer(lua_index) catch unreachable;
            const mem: []u8 = if (pre_allocated) args[i] else try allocator.alloc(u8, ffitype.size);
            if (buf.len != mem.len)
                return error.InvalidStructSize;
            @memcpy(mem, buf);
            if (!pre_allocated)
                args[i] = mem;
        }
    }
}

fn alloc_ffi_args(allocator: std.mem.Allocator, args: []DataType) ![][]u8 {
    const alloc_args = try allocator.alloc([]u8, args.len);
    var alloc_len: usize = 0;
    errdefer allocator.free(alloc_args);
    errdefer {
        for (0..alloc_len) |i|
            allocator.free(alloc_args[i]);
    }

    // Allocate space for the arg types
    for (args, 0..) |arg, i| {
        alloc_args[i] = try allocator.alloc(u8, arg.size);
        alloc_len += 1;
    }

    return alloc_args;
}

fn ffi_struct(L: *Luau) !i32 {
    L.checkType(1, .table);

    const allocator = L.allocator();

    var struct_map = std.StringArrayHashMap(DataType).init(allocator);
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

    const data = L.newUserdataTaggedWithMetatable(LuaStructType, tagged.FFI_STRUCT);

    data.* = .{
        .type = try makeStruct(allocator, struct_map.values()),
        .fields = struct_map,
    };

    return 1;
}

fn generateTypeFromSymbol(source: *std.ArrayList(u8), symbol: DataType, order: usize, comptime pointer: bool) !void {
    const writer = source.writer();

    if (order == 0) {
        if (symbol.isStruct())
            try writer.print("struct anon_ret" ++ if (pointer) "*" else "", .{})
        else
            try DataTypes.writeCTypeName(symbol, writer, pointer);
    } else {
        if (symbol.isStruct())
            try writer.print("struct anon_{d}" ++ if (pointer) "*" else "", .{order - 1})
        else
            try DataTypes.writeCTypeName(symbol, writer, pointer);
    }
}

fn generateTypesFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []DataType) !void {
    const writer = source.writer();
    if (symbol_returns.isStruct())
        try writer.print("struct anon_ret {{ unsigned char _[{d}]; }};\n", .{symbol_returns.size});

    for (symbol_args, 0..) |arg, i| {
        if (!arg.isStruct())
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

fn generateSourceFromSymbol(source: *std.ArrayList(u8), symbol_returns: DataType, symbol_args: []DataType) !void {
    const writer = source.writer();

    try generateTypesFromSymbol(source, symbol_returns, symbol_args);

    try source.appendSlice("void call_fn_ffi(Fn fn, void** args, void* ret) {\n  ");
    if (symbol_returns.size > 0) {
        try source.appendSlice("*(");
        try generateTypeFromSymbol(source, symbol_returns, 0, true);
        try source.appendSlice(")ret = ");
    }
    try source.appendSlice("fn(");
    if (symbol_args.len > 0) {
        for (symbol_args, 0..) |arg, i| {
            if (i != 0)
                try source.append(',');
            try source.appendSlice("\n    *((");
            try generateTypeFromSymbol(source, arg, i + 1, true);
            try writer.print(")args[{d}])", .{i});
        }
        try source.appendSlice("\n  ");
    }
    try source.appendSlice(");\n}\n");
}

fn ffi_dlopen(L: *Luau) !i32 {
    const path = L.checkString(1);

    const allocator = L.allocator();

    L.checkType(2, .table);

    var func_map = std.StringArrayHashMap(SymbolFunction).init(allocator);
    defer func_map.deinit();
    defer {
        var iter = func_map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.args_type);
        }
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

        const args = try allocator.alloc(DataType, @intCast(args_len));
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
            if (args[order].size == 0)
                return error.VoidArg;

            order += 1;
        }
        L.pop(1); // drop: args

        const name_copy = try allocator.dupe(u8, name); // Zig owned string to prevent GC from Lua owned strings
        errdefer allocator.free(name_copy);
        try func_map.put(name_copy, .{
            .returns_type = returns_ffi_type,
            .args_type = args,
        });
    }

    const ptr = L.newUserdataDtor(LuaHandle, LuaHandle.__dtor);

    ptr.* = .{
        .lib = undefined,
        .open = false,
    };

    var lib = try std.DynLib.open(path);

    ptr.lib = lib;
    ptr.open = true;

    L.newTable();

    L.newTable();
    while (func_map.popOrNull()) |entry| {
        const key = entry.key;
        const value = entry.value;
        defer allocator.free(key);
        errdefer allocator.free(value.args_type);
        const namez = try allocator.dupeZ(u8, key);
        defer allocator.free(namez);
        const func = lib.lookup(*anyopaque, namez) orelse {
            std.debug.print("Symbol not found: {s}\n", .{key});
            return error.SymbolNotFound;
        };

        const symbol_returns = value.returns_type;
        const symbol_args = value.args_type;

        const state = try tinycc.new();
        errdefer state.deinit();

        state.set_output_type(tinycc.TCC_OUTPUT_MEMORY);
        state.set_options("-std=c11 -nostdlib -Wl,--export-all-symbols");

        var source = std.ArrayList(u8).init(allocator);
        defer source.deinit();

        try generateSourceFromSymbol(&source, symbol_returns, symbol_args);

        const block = state.compileStringOnceAlloc(allocator, source.items) catch |err| {
            std.debug.print("Internal FFI Error: {}\n", .{err});
            return error.CompilationError;
        };
        errdefer block.free();

        // Allocate space for the arg types
        const alloc_args: ?[][]u8 = if (symbol_args.len > 0) try alloc_ffi_args(allocator, symbol_args) else null;
        errdefer if (alloc_args) |arr| allocator.free(arr);
        const ffi_alloc_args: ?[]*anyopaque = if (symbol_args.len > 0) try allocator.alloc(*anyopaque, symbol_args.len) else null;
        errdefer if (ffi_alloc_args) |arr| allocator.free(arr);
        for (0..symbol_args.len) |i| {
            ffi_alloc_args.?[i] = @ptrCast(@alignCast(alloc_args.?[i].ptr));
        }
        // Allocate space for the return type
        const ret_size = symbol_returns.size;
        const alloc_ret: ?[]u8 = if (ret_size > 0) try allocator.alloc(u8, ret_size) else null;
        errdefer if (alloc_ret) allocator.free(alloc_ret);

        // Zig owned string to prevent GC from Lua owned strings
        L.pushLString(key);

        const data = L.newUserdataDtor(FFIFunction, FFIFunction.__dtor);
        data.* = .{
            .allocator = allocator,
            .state = state,
            .ret = alloc_ret,
            .args = alloc_args,
            .ffi_args = ffi_alloc_args,
            .lib = ptr,
            .callable = @ptrCast(@alignCast(state.get_symbol("call_fn_ffi") orelse @panic("Symbol not found"))),
            .sym = .{
                .ptr = func,
                .block = block,
                .type = value,
            },
        };
        L.pushValue(-5);
        L.pushClosure(luau.toCFn(FFIFunction.fn_inner), "ffi_func", 2);
        L.setTable(-3);
    }
    L.setField(-2, luau.Metamethods.index);

    L.setFieldFn(-1, luau.Metamethods.namecall, LuaHandle.__namecall);
    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setMetatable(-2);

    return 1;
}

fn FFIReturnTypeConversion(
    comptime T: type,
    ret_ptr: *anyopaque,
    L: *Luau,
) void {
    const isFloat = @typeInfo(T) == .float;
    const size = @sizeOf(T);
    const mem = @as([*]u8, @ptrCast(@alignCast(ret_ptr)))[0..size];
    switch (L.typeOf(-1)) {
        .number => {
            const value = if (isFloat) L.toNumber(-1) catch unreachable else L.toInteger(-1) catch unreachable;
            if (if (isFloat) floatOutOfRange(T, value) else intOutOfRange(T, value))
                return std.debug.panic("Out of range ('{s}')", .{@typeName(T)});
            var bytes: [size]u8 = @bitCast(@as(T, if (isFloat) @floatCast(value) else @intCast(value)));
            @memcpy(mem, &bytes);
        },
        .boolean => {
            var bytes: [size]u8 = @bitCast(@as(T, if (L.toBoolean(-1) == true) 1 else 0));
            @memcpy(mem, &bytes);
        },
        .buffer => {
            const lua_buf = L.toBuffer(-1) catch unreachable;
            if (lua_buf.len < size)
                return std.debug.panic("Small buffer ('{s}')", .{@typeName(T)});
            @memcpy(mem, lua_buf[0..size]);
        },
        else => std.debug.panic("Invalid return type (expected number for '{s}')", .{@typeName(T)}),
    }
}

fn ffi_closure_inner(cif: *LuaClosure.CallInfo, extern_args: [*]?*anyopaque, ret: ?*anyopaque) callconv(.c) void {
    const args = extern_args[0..cif.args];

    const subthread = cif.thread.newThread();
    defer cif.thread.pop(1);
    cif.thread.xPush(subthread, 1);

    for (cif.type.args_type, 0..) |arg_type, i| {
        if (arg_type.isConst()) {
            switch (arg_type.kind.?) {
                .void => unreachable,
                inline .i8, .u8, .i16, .u16, .u32 => |T| subthread.pushInteger(@intCast(@as(*T.asType(), @ptrCast(@alignCast(args[i]))).*)),
                .i32 => subthread.pushInteger(@as(*i32, @ptrCast(@alignCast(args[i]))).*),
                inline .i64, .u64 => |T| {
                    const bytes: [8]u8 = @bitCast(@as(*T.asType(), @ptrCast(@alignCast(args[i]))).*);
                    subthread.pushBuffer(&bytes);
                },
                .f32 => subthread.pushNumber(@floatCast(@as(f32, @bitCast(@as(*u32, @ptrCast(@alignCast(args[i]))).*)))),
                .f64 => subthread.pushNumber(@as(f64, @bitCast(@as(*u64, @ptrCast(@alignCast(args[i]))).*))),
                .pointer => _ = LuaPointer.newStaticPtr(subthread, @as(*[*]u8, @ptrCast(@alignCast(args[i]))).*, false) catch |err| std.debug.panic("Failed: {}", .{err}),
            }
        } else {
            const bytes: [*]u8 = @ptrCast(@alignCast(args[i]));
            subthread.pushBuffer(bytes[0..arg_type.size]);
        }
    }

    const has_return = cif.type.returns_type.size > 0;

    subthread.pcall(@intCast(args.len), if (has_return) 1 else 0, 0) catch {
        std.debug.panic("C Closure Runtime Error: {s}", .{subthread.toString(-1) catch "UnknownError"});
    };

    if (ret) |ret_ptr| {
        defer subthread.pop(1);
        if (cif.type.returns_type.isConst()) {
            switch (cif.type.returns_type.kind.?) {
                .void => unreachable,
                inline .i8,
                .u8,
                .i16,
                .u16,
                .i32,
                .u32,
                .i64,
                .u64,
                .f32,
                .f64,
                => |T| FFIReturnTypeConversion(T.asType(), ret_ptr, subthread),
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
                    else => return std.debug.panic("Invalid return type (expected buffer/nil for '*anyopaque')", .{}),
                },
            }
        } else {
            if (subthread.typeOf(-1) != .buffer)
                return std.debug.panic("Invalid return type (expected buffer for struct)", .{});
            const buf = subthread.toBuffer(-1) catch unreachable;
            if (buf.len != cif.type.returns_type.size)
                return std.debug.panic("Invalid return type (expected buffer of size {d} for struct)", .{cif.type.returns_type.size});
            @memcpy(@as([*]u8, @ptrCast(@alignCast(ret_ptr))), buf);
        }
    }
}

fn ffi_closure(L: *Luau) !i32 {
    L.checkType(1, .table);
    L.checkType(2, .function);

    const allocator = L.allocator();

    var symbol_returns: DataType = DataTypes.Types.type_void;
    var args = std.ArrayList(DataType).init(allocator);
    defer args.deinit();

    _ = L.getField(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    symbol_returns = try toFFIType(L, -1);
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

    try writer.print((if (builtin.os.tag == .windows) "__declspec(dllimport)" else "extern") ++ " void external_call(void*, void**, void*);\n", .{});
    try writer.print((if (builtin.os.tag == .windows) "__declspec(dllimport)" else "extern") ++ " void* external_ptr;\n\n", .{});

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
            .returns_type = symbol_returns,
            .args_type = symbol_args,
        },
    };

    _ = state.add_symbol("external_ptr", @ptrCast(@alignCast(call_ptr)));
    _ = state.add_symbol("external_call", @ptrCast(@alignCast(&ffi_closure_inner)));

    const block = state.compileStringOnceAlloc(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };

    const thread = L.newThread();
    L.xPush(thread, 2);

    call_ptr.thread = thread;

    const data = L.newUserdataDtor(LuaClosure, LuaClosure.__dtor);

    data.* = .{
        .allocator = allocator,
        .callinfo = call_ptr,
        .callable = @ptrCast(@alignCast(state.get_symbol("call_closure_ffi") orelse @panic("Symbol not found"))),
        .thread = thread,
        .sym = .{
            .ptr = @ptrCast(@alignCast(call_ptr)),
            .type = .{
                .returns_type = symbol_returns,
                .args_type = symbol_args,
            },
            .block = block,
        },
    };

    L.newTable();

    L.newTable();
    {
        L.pushValue(2);
        L.setField(-2, "callback");
    }
    L.setField(-2, luau.Metamethods.index);

    L.pushValue(-3);
    L.setField(-2, "thread");

    L.setReadOnly(-1, true);

    L.setMetatable(-2);

    const ptr = try LuaPointer.newStaticPtrWithRef(L, data.callable, -1);
    ptr.size = 0;

    return 1;
}

const FFIFunction = struct {
    allocator: std.mem.Allocator,
    state: *tinycc.TCCState,
    sym: FFISymbol,
    args: ?[][]u8,
    ffi_args: ?[]*anyopaque,
    ret: ?[]u8,
    lib: ?*LuaHandle = null,

    callable: FFICallable,

    pub const FFISymbol = struct {
        type: SymbolFunction,
        block: tinycc.DynMem,
        ptr: *anyopaque,

        pub fn free(self: *FFISymbol, allocator: std.mem.Allocator) void {
            self.block.free();
            allocator.free(self.type.args_type);
        }
    };

    pub const FFICallable = *const fn (fnPtr: *anyopaque, args: ?[*]*anyopaque, ret: ?*anyopaque) callconv(.c) void;

    pub fn fn_inner(L: *Luau) !i32 {
        const allocator = L.allocator();
        const ffi_func = L.toUserdata(FFIFunction, Luau.upvalueIndex(1)) catch unreachable;

        if (ffi_func.lib) |lib|
            if (!lib.open)
                return error.LibraryNotOpen;

        const callable = ffi_func.callable;

        const alloc_args = ffi_func.args;
        const alloc_ret = ffi_func.ret;

        if (alloc_args) |args| {
            if (@as(usize, @intCast(L.getTop())) != args.len)
                return L.Error("Invalid number of arguments");
        } else {
            if (L.getTop() != 0)
                return L.Error("Invalid number of arguments");
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (alloc_args) |args|
            try load_ffi_args(arena.allocator(), L, ffi_func.sym.type.args_type, 1, args, true);

        callable(ffi_func.sym.ptr, if (ffi_func.ffi_args) |args| @ptrCast(@alignCast(args)) else null, if (alloc_ret) |ret| @ptrCast(@alignCast(ret.ptr)) else null);

        if (alloc_ret) |ret| {
            const datatype = ffi_func.sym.type.returns_type;
            if (datatype.isConst()) {
                L.pushBuffer(ret);
                switch (datatype.kind.?) {
                    .void => unreachable,
                    .i8 => L.pushInteger(@intCast(@as(i8, @intCast(ret[0])))),
                    .u8 => L.pushInteger(@intCast(ret[0])),
                    inline .i16, .u16, .i32, .u32 => |T| L.pushInteger(@intCast(std.mem.readVarInt(T.asType(), ret, cpu_endian))),
                    .i64 => L.pushBuffer(ret),
                    .u64 => L.pushBuffer(ret),
                    .f32 => L.pushNumber(@floatCast(@as(f32, @bitCast(std.mem.readVarInt(u32, ret, cpu_endian))))),
                    .f64 => L.pushNumber(@as(f64, @bitCast(std.mem.readVarInt(u64, ret, cpu_endian)))),
                    .pointer => _ = try LuaPointer.newStaticPtr(L, @ptrFromInt(std.mem.readVarInt(usize, ret[0..@sizeOf(usize)], cpu_endian)), false),
                }
            } else {
                L.pushBuffer(ret);
            }
            return 1;
        }
        return 0;
    }

    pub fn __dtor(self: *FFIFunction) void {
        const allocator = self.allocator;
        if (self.args) |args| {
            for (args) |arg|
                allocator.free(arg);
            allocator.free(args);
        }

        if (self.ffi_args) |ffi_args|
            allocator.free(ffi_args);

        if (self.ret) |ret|
            allocator.free(ret);

        self.state.deinit();

        self.sym.free(allocator);
    }
};

fn ffi_fn(L: *Luau) !i32 {
    L.checkType(1, .table);
    const src = try LuaPointer.value(L, 2);
    switch (src.type) {
        .Allocated => return error.PointerNotCallable,
        else => {},
    }
    const ptr: *anyopaque = src.ptr orelse return error.NoAddressAvailable;

    const allocator = L.allocator();

    var symbol_returns: DataType = DataTypes.Types.type_void;
    var args = std.ArrayList(DataType).init(allocator);
    errdefer args.deinit();

    _ = L.getField(1, "returns");
    if (!isFFIType(L, -1))
        return error.InvalidReturnType;
    symbol_returns = try toFFIType(L, -1);
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

    try generateSourceFromSymbol(&source, symbol_returns, symbol_args);

    const block = state.compileStringOnceAlloc(allocator, source.items) catch |err| {
        std.debug.print("Internal FFI Error: {}\n", .{err});
        return error.CompilationError;
    };
    errdefer block.free();

    // Allocate space for the arguments
    const alloc_args: ?[][]u8 = if (symbol_args.len > 0) try alloc_ffi_args(allocator, symbol_args) else null;
    errdefer if (alloc_args) |arr| allocator.free(arr);
    const ffi_alloc_args: ?[]*anyopaque = if (symbol_args.len > 0) try allocator.alloc(*anyopaque, symbol_args.len) else null;
    errdefer if (ffi_alloc_args) |arr| allocator.free(arr);
    for (0..symbol_args.len) |i| {
        ffi_alloc_args.?[i] = @ptrCast(@alignCast(alloc_args.?[i].ptr));
    }
    // Allocate space for the return type
    const ret_size = symbol_returns.size;
    const alloc_ret: ?[]u8 = if (ret_size > 0) try allocator.alloc(u8, ret_size) else null;

    const data = L.newUserdataDtor(FFIFunction, FFIFunction.__dtor);

    data.* = .{
        .allocator = allocator,
        .state = state,
        .ret = alloc_ret,
        .args = alloc_args,
        .ffi_args = ffi_alloc_args,
        .callable = @ptrCast(@alignCast(state.get_symbol("call_fn_ffi") orelse @panic("Symbol not found"))),
        .sym = .{
            .ptr = ptr,
            .block = block,
            .type = .{
                .args_type = symbol_args,
                .returns_type = symbol_returns,
            },
        },
    };

    L.pushClosure(luau.toCFn(FFIFunction.fn_inner), "ffi_fn", 1);

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
                const ptr = LuaPointer.value(L, 1) catch return L.Error("Invalid pointer");
                if (ptr.destroyed or ptr.ptr == null)
                    return L.Error("No address available");
                target_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => return L.Error("Invalid type (expected buffer or userdata)"),
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
                const ptr = LuaPointer.value(L, 3) catch return L.Error("Invalid pointer");
                if (ptr.destroyed or ptr.ptr == null)
                    return L.Error("No address available");
                src_bounds = ptr.size;
                break :blk @ptrCast(@alignCast(ptr.ptr));
            },
            else => return L.Error("Invalid type (expected buffer or userdata)"),
        }
    };
    const len: usize = @intCast(L.checkInteger(5));

    if (target_bounds) |bounds| if (target_offset + len > bounds)
        return L.Error("Target OutOfBounds");

    if (src_bounds) |bounds| if (src_offset + len > bounds)
        return L.Error("Source OutOfBounds");

    @memcpy(target[target_offset .. target_offset + len], src[src_offset .. src_offset + len]);

    return 0;
}

fn ffi_sizeOf(L: *Luau) !i32 {
    const t = try toFFIType(L, 1);
    L.pushInteger(@intCast(t.size));
    return 1;
}

fn ffi_alignOf(L: *Luau) !i32 {
    const t = try toFFIType(L, 1);
    L.pushInteger(@intCast(t.alignment));
    return 1;
}

fn ffi_unsupported(L: *Luau) !i32 {
    return L.Error("ffi is not supported on this platform");
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
    const ptr = LuaPointer.value(L, 1) catch return L.Error("Invalid pointer");
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
                    if (size > 0)
                        allocator.free(@as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..size]);
                }
            },
        }
    } else return L.Error("Double free");
    return 0;
}

fn ffi_len(L: *Luau) !i32 {
    switch (L.typeOf(1)) {
        .buffer => {
            const buf = L.toBuffer(1) catch unreachable;
            L.pushInteger(@intCast(buf.len));
        },
        .userdata => {
            const ptr = LuaPointer.value(L, 1) catch return L.Error("Invalid pointer");
            if (ptr.destroyed or ptr.ptr == null)
                return L.Error("No address available");
            if (ptr.size) |size|
                L.pushInteger(@intCast(size))
            else
                L.pushNil();
        },
        else => return L.Error("Invalid type (expected buffer or userdata)"),
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
            const len = ptr.size orelse return L.Error("Unknown sized pointer");
            const dup_ptr = try LuaPointer.allocBlockPtr(L, len);
            @memcpy(
                @as([*]u8, @ptrCast(@alignCast(dup_ptr.ptr)))[0..len],
                @as([*]u8, @ptrCast(@alignCast(ptr.ptr)))[0..len],
            );
        },
        else => return L.Error("Invalid type (expected buffer or userdata)"),
    }
    return 1;
}

pub fn loadLib(L: *Luau) void {
    {
        L.newMetatable(LuaStructType.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.namecall, LuaStructType.__namecall); // metatable.__namecall

        L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");
        L.setUserdataDtor(LuaStructType, tagged.FFI_STRUCT, LuaStructType.__dtor);
        L.setUserdataMetatable(tagged.FFI_STRUCT, -1);
    }
    {
        L.newMetatable(LuaPointer.META) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

        L.setFieldFn(-1, luau.Metamethods.eq, LuaPointer.__eq); // metatable.__eq
        L.setFieldFn(-1, luau.Metamethods.namecall, LuaPointer.__namecall); // metatable.__namecall
        L.setFieldFn(-1, luau.Metamethods.tostring, LuaPointer.__tostring); // metatable.__tostring

        L.setUserdataDtor(LuaPointer, tagged.FFI_POINTER, LuaPointer.__dtor);
        L.setUserdataMetatable(tagged.FFI_POINTER, -1);
    }

    L.newTable();

    L.setFieldFn(-1, "dlopen", ffi_dlopen);
    L.setFieldFn(-1, "struct", ffi_struct);
    L.setFieldFn(-1, "closure", ffi_closure);
    L.setFieldFn(-1, "fn", ffi_fn);
    L.setFieldBoolean(-1, "supported", true);

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
    inline for (@typeInfo(DataTypes.Types).@"struct".decls, 0..) |decl, i| {
        L.pushString(decl.name[5..]);
        L.pushLightUserdata(@constCast(@ptrCast(@alignCast(DataTypes.order[i]))));
        L.setTable(-3);
    }
    L.setReadOnly(-1, true);
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

    L.setReadOnly(-1, true);
    luaHelper.registerModule(L, LIB_NAME);
}

test "ffi" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(std.testing.allocator, @import("zune-test-files").@"ffi.test", &.{}, true);

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total >= 0);
}
