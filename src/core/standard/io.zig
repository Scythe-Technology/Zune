const std = @import("std");
const xev = @import("xev").Dynamic;
const luau = @import("luau");
const builtin = @import("builtin");

const Zune = @import("zune");

const Fmt = Zune.Resolvers.Fmt;

const LuaHelper = Zune.Utils.LuaHelper;
const MethodMap = Zune.Utils.MethodMap;

const sysfd = @import("../utils/sysfd.zig");
const tagged = @import("../../tagged.zig");

const File = @import("../objects/filesystem/File.zig");

const Terminal = @import("../../commands/repl/Terminal.zig");

const VM = luau.VM;

const MAX_LUAU_SIZE = 1073741824; // 1 GB

const TAG_IO_STREAM = tagged.Tags.get("IO_STREAM").?;
const TAG_IO_BUFFERSINK = tagged.Tags.get("IO_BUFFERSINK").?;
const TAG_IO_BUFFERSTREAM = tagged.Tags.get("IO_BUFFERSTREAM").?;

pub const LIB_NAME = "io";

const LuaTerminal = struct {
    pub fn lua_enableRawMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        L.pushboolean(if (term.setRawMode()) true else |_| false);
        return 1;
    }

    pub fn lua_restoreMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        L.pushboolean(if (term.restoreSettings()) true else |_| false);
        return 1;
    }

    pub fn lua_getSize(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        const x, const y = term.getSize() catch |err| {
            if (err == error.NotATerminal) return 0;
            return err;
        };
        L.pushinteger(x);
        L.pushinteger(y);
        return 2;
    }

    pub fn lua_getCurrentMode(L: *VM.lua.State) !i32 {
        const term = &(TERMINAL orelse return L.Zerror("Terminal not initialized"));
        switch (term.mode) {
            .Plain => L.pushstring("normal"),
            .Virtual => L.pushstring("raw"),
        }
        return 1;
    }
};

const Stream = struct {
    vtable: *const VTable,
    ref: LuaHelper.Ref(*anyopaque),
    mode: Mode,

    pub const VTable = struct {
        write: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
        read: ?*const fn (*anyopaque, u32, bool) anyerror!?[]const u8 = null,
        seekTo: ?*const fn (*anyopaque, u32) anyerror!void = null,
        seekBy: ?*const fn (*anyopaque, i32) anyerror!void = null,
    };

    pub const Mode = packed struct {
        read: bool,
        write: bool,
        seek: bool,

        pub fn readable(seakable: bool) Mode {
            return .{ .read = true, .write = false, .seek = seakable };
        }
        pub fn writable(seakable: bool) Mode {
            return .{ .read = false, .write = true, .seek = seakable };
        }
        pub fn readwrite(seakable: bool) Mode {
            return .{ .read = true, .write = true, .seek = seakable };
        }
    };

    fn GenerateWriteLuaMethod(comptime T: type) fn (self: *Stream, L: *VM.lua.State) anyerror!i32 {
        const len = @sizeOf(T);
        if (len == 0)
            @compileError("Too small");
        return struct {
            fn inner(self: *Stream, L: *VM.lua.State) !i32 {
                if (!self.mode.write)
                    return L.Zerror("Stream is not writable");
                std.debug.assert(self.vtable.write != null);
                switch (comptime @typeInfo(T)) {
                    .int => |i| {
                        const value = if (i.signedness == .signed) L.Lcheckinteger(2) else L.Lcheckunsigned(2);
                        var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, @truncate(value)));
                        try self.vtable.write.?(self.ref.value, &bytes);
                    },
                    .float => {
                        const value = L.Lchecknumber(2);
                        var bytes: [@sizeOf(T)]u8 = @bitCast(@as(T, @floatCast(value)));
                        try self.vtable.write.?(self.ref.value, &bytes);
                    },
                    else => @compileError("Unsupported type"),
                }

                return 1;
            }
        }.inner;
    }

    fn GenericReadLuaMethod(comptime T: type) fn (self: *Stream, L: *VM.lua.State) anyerror!i32 {
        const len = @sizeOf(T);
        if (len == 0)
            @compileError("Too small");
        return struct {
            fn inner(self: *Stream, L: *VM.lua.State) anyerror!i32 {
                if (!self.mode.read)
                    return L.Zerror("Stream is not readable");
                std.debug.assert(self.vtable.read != null);
                const data = try self.vtable.read.?(self.ref.value, @sizeOf(T), true) orelse return error.EOF;
                const value = std.mem.bytesToValue(T, data[0..len]);
                switch (comptime @typeInfo(T)) {
                    .int => |i| {
                        if (i.signedness == .signed)
                            L.pushinteger(@intCast(value))
                        else
                            L.pushunsigned(@intCast(value));
                    },
                    .float => L.pushnumber(@as(f64, @floatCast(value))),
                    else => @compileError("Unsupported type"),
                }
                return 1;
            }
        }.inner;
    }

    pub fn lua_write(self: *Stream, L: *VM.lua.State) !i32 {
        if (!self.mode.write)
            return L.Zerror("Stream is not writable");
        std.debug.assert(self.vtable.write != null);
        const data = try L.Zcheckvalue([]const u8, 2, null);
        try self.vtable.write.?(self.ref.value, data);
        return 0;
    }

    pub fn lua_read(self: *Stream, L: *VM.lua.State) !i32 {
        if (!self.mode.read)
            return L.Zerror("Stream is not readable");
        std.debug.assert(self.vtable.read != null);
        const amount = L.Loptunsigned(2, MAX_LUAU_SIZE);
        const use_buffer = L.Loptboolean(3, true);
        const data = try self.vtable.read.?(self.ref.value, amount, false) orelse return error.EOF;
        if (use_buffer)
            L.Zpushbuffer(data)
        else
            L.pushlstring(data);
        return 1;
    }

    pub fn lua_seekTo(self: *Stream, L: *VM.lua.State) !i32 {
        if (!self.mode.seek)
            return L.Zerror("Stream is not seekable");
        std.debug.assert(self.vtable.seekTo != null);
        const pos = L.Lcheckunsigned(2);
        try self.vtable.seekTo.?(self.ref.value, pos);
        return 0;
    }

    pub fn lua_seekBy(self: *Stream, L: *VM.lua.State) !i32 {
        if (!self.mode.seek)
            return L.Zerror("Stream is not seekable");
        std.debug.assert(self.vtable.seekBy != null);
        const offset = L.Lcheckinteger(2);
        try self.vtable.seekBy.?(self.ref.value, offset);
        return 0;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(Stream, TAG_IO_STREAM, .{
        .{ "write", lua_write },
        .{ "writeu8", GenerateWriteLuaMethod(u8) },
        .{ "writeu16", GenerateWriteLuaMethod(u16) },
        .{ "writeu32", GenerateWriteLuaMethod(u32) },
        .{ "writei8", GenerateWriteLuaMethod(i8) },
        .{ "writei16", GenerateWriteLuaMethod(i16) },
        .{ "writei32", GenerateWriteLuaMethod(i32) },
        .{ "writef32", GenerateWriteLuaMethod(f32) },
        .{ "writef64", GenerateWriteLuaMethod(f64) },
        .{ "read", lua_read },
        .{ "readu8", GenericReadLuaMethod(u8) },
        .{ "readu16", GenericReadLuaMethod(u16) },
        .{ "readu32", GenericReadLuaMethod(u32) },
        .{ "readi8", GenericReadLuaMethod(i8) },
        .{ "readi16", GenericReadLuaMethod(i16) },
        .{ "readi32", GenericReadLuaMethod(i32) },
        .{ "readf32", GenericReadLuaMethod(f32) },
        .{ "readf64", GenericReadLuaMethod(f64) },
        .{ "seekTo", lua_seekTo },
        .{ "seekBy", lua_seekBy },
    });

    pub fn GenericWrite(
        comptime T: type,
        func: fn (self: *T, value: []const u8) anyerror!void,
    ) fn (ptr: *anyopaque, value: []const u8) anyerror!void {
        return struct {
            fn inner(self: *anyopaque, value: []const u8) anyerror!void {
                return @call(.always_inline, func, .{ @as(*T, @ptrCast(@alignCast(self))), value });
            }
        }.inner;
    }

    pub fn GenericRead(
        comptime T: type,
        func: fn (*T, u32, bool) anyerror!?[]const u8,
    ) fn (*anyopaque, u32, bool) anyerror!?[]const u8 {
        return struct {
            fn inner(self: *anyopaque, amount: u32, exact: bool) anyerror!?[]const u8 {
                return @call(.always_inline, func, .{ @as(*T, @ptrCast(@alignCast(self))), amount, exact });
            }
        }.inner;
    }

    pub fn GenericSeekTo(
        comptime T: type,
        func: fn (*T, u32) anyerror!void,
    ) fn (*anyopaque, u32) anyerror!void {
        return struct {
            fn inner(self: *anyopaque, pos: u32) anyerror!void {
                return @call(.always_inline, func, .{ @as(*T, @ptrCast(@alignCast(self))), pos });
            }
        }.inner;
    }

    pub fn GenericSeekBy(
        comptime T: type,
        func: fn (*T, i32) anyerror!void,
    ) fn (ptr: *anyopaque, i32) anyerror!void {
        return struct {
            fn inner(self: *anyopaque, offset: i32) anyerror!void {
                return @call(.always_inline, func, .{ @as(*T, @ptrCast(@alignCast(self))), offset });
            }
        }.inner;
    }

    pub fn GenericAccess(
        comptime T: type,
        func: fn (*T, *VM.lua.State, []const u8) anyerror!i32,
    ) fn (*anyopaque, *VM.lua.State, []const u8) anyerror!i32 {
        return struct {
            fn inner(self: *anyopaque, L: *VM.lua.State, index: []const u8) anyerror!i32 {
                return @call(.always_inline, func, .{ @as(*T, @ptrCast(@alignCast(self))), L, index });
            }
        }.inner;
    }

    pub fn __dtor(L: *VM.lua.State, self: *Stream) void {
        self.ref.deref(L);
    }
};

const BufferSink = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8),
    limit: u32 = MAX_LUAU_SIZE,
    closed: bool = false,

    ref_table: LuaHelper.RefTable,
    stream_writer: LuaHelper.Ref(void) = .empty,

    pub fn __index(L: *VM.lua.State) !i32 {
        try L.Zchecktype(1, .Userdata);
        const self = L.touserdata(BufferSink, 1) orelse return 0;
        const index = try L.Zcheckvalue([:0]const u8, 2, null);

        if (std.mem.eql(u8, index, "len")) {
            L.pushunsigned(@truncate(self.buf.items.len));
            return 1;
        } else if (std.mem.eql(u8, index, "closed")) {
            L.pushboolean(self.closed);
            return 1;
        }

        return 0;
    }

    pub fn write(self: *BufferSink, value: []const u8) !void {
        try self.buf.appendSlice(self.alloc, value);
    }

    pub fn lua_write(self: *BufferSink, L: *VM.lua.State) !i32 {
        if (self.closed)
            return error.Closed;
        const str = try L.Zcheckvalue([]const u8, 2, null);
        if (self.buf.items.len + str.len > self.limit)
            return L.Zerror("BufferSink limit exceeded");
        try self.write(str);
        return 0;
    }

    pub const StreamImpl: Stream.VTable = .{
        .write = Stream.GenericWrite(BufferSink, BufferSink.write),
        .read = null,
        .seekTo = null,
        .seekBy = null,
    };

    pub fn lua_writer(self: *BufferSink, L: *VM.lua.State) !i32 {
        if (self.stream_writer.push(L))
            return 1;

        const ref = LuaHelper.Ref(*anyopaque).init(L, 1, @ptrCast(@alignCast(self)));
        const stream = L.newuserdatataggedwithmetatable(Stream, TAG_IO_STREAM);

        stream.* = .{
            .vtable = &StreamImpl,
            .ref = ref,
            .mode = Stream.Mode.writable(false),
        };

        self.stream_writer = .initWithTable(L, -1, undefined, &self.ref_table);

        return 1;
    }

    pub fn lua_flush(self: *BufferSink, L: *VM.lua.State) !i32 {
        if (self.closed)
            return error.Closed;
        const use_buffer = L.Loptboolean(2, true);
        if (self.buf.items.len == 0)
            return 0;
        const buf = self.buf.items;
        defer self.buf.clearAndFree(self.alloc);
        if (use_buffer)
            L.Zpushbuffer(buf)
        else
            L.pushlstring(buf);
        return 1;
    }

    pub fn lua_clear(self: *BufferSink, _: *VM.lua.State) !i32 {
        if (self.closed)
            return error.Closed;
        defer self.buf.clearAndFree(self.alloc);
        return 0;
    }

    pub fn lua_close(self: *BufferSink, _: *VM.lua.State) !i32 {
        self.closed = true;
        return 0;
    }

    pub const __namecall = MethodMap.CreateNamecallMap(BufferSink, null, .{
        .{ "write", lua_write },
        .{ "writer", lua_writer },
        .{ "flush", lua_flush },
        .{ "clear", lua_clear },
        .{ "close", lua_close },
    });

    pub fn __dtor(L: *VM.lua.State, self: *BufferSink) void {
        self.buf.deinit(self.alloc);
        self.ref_table.deinit(L);
        self.stream_writer.deref(L);
    }
};

const BufferStream = struct {
    pos: u32,
    buf: LuaHelper.Ref([]u8),

    ref_table: LuaHelper.RefTable,
    stream_reader: LuaHelper.Ref(void) = .empty,
    stream_writer: LuaHelper.Ref(void) = .empty,

    pub fn lua_pos(self: *BufferStream, L: *VM.lua.State) !i32 {
        L.pushunsigned(self.pos);
        return 1;
    }

    pub fn lua_size(self: *BufferStream, L: *VM.lua.State) !i32 {
        L.pushunsigned(@truncate(self.buf.value.len));
        return 1;
    }

    pub fn lua_write(self: *BufferStream, L: *VM.lua.State) !i32 {
        try self.stream_write(try L.Zcheckvalue([]const u8, 2, null));
        return 0;
    }

    pub fn lua_read(self: *BufferStream, L: *VM.lua.State) !i32 {
        const amount = L.Loptunsigned(2, MAX_LUAU_SIZE);
        const use_buffer = L.Loptboolean(3, true);
        const data = try self.stream_read(amount, false) orelse return error.EOF;
        if (use_buffer)
            L.Zpushbuffer(data)
        else
            L.pushlstring(data);
        return 1;
    }

    pub fn lua_canRead(self: *BufferStream, L: *VM.lua.State) !i32 {
        const amount = L.Loptunsigned(2, 0);
        L.pushboolean(self.pos + amount <= self.buf.value.len);
        return 1;
    }

    pub fn lua_seekTo(self: *BufferStream, L: *VM.lua.State) !i32 {
        try self.stream_seekTo(try L.Zcheckvalue(u32, 2, null));
        return 0;
    }

    pub fn lua_seekBy(self: *BufferStream, L: *VM.lua.State) !i32 {
        try self.stream_seekBy(try L.Zcheckvalue(i32, 2, null));
        return 0;
    }

    pub fn lua_writer(self: *BufferStream, L: *VM.lua.State) !i32 {
        if (self.stream_writer.push(L))
            return 1;
        const ref = LuaHelper.Ref(*anyopaque).init(L, 1, @ptrCast(@alignCast(self)));
        const stream = L.newuserdatataggedwithmetatable(Stream, TAG_IO_STREAM);

        stream.* = .{
            .vtable = &BufferStream.Impl,
            .ref = ref,
            .mode = Stream.Mode.writable(false),
        };

        self.stream_writer = .initWithTable(L, -1, undefined, &self.ref_table);

        return 1;
    }

    pub fn lua_reader(self: *BufferStream, L: *VM.lua.State) !i32 {
        if (self.stream_reader.push(L))
            return 1;
        const ref = LuaHelper.Ref(*anyopaque).init(L, 1, @ptrCast(@alignCast(self)));
        const stream = L.newuserdatataggedwithmetatable(Stream, TAG_IO_STREAM);

        stream.* = .{
            .vtable = &BufferStream.Impl,
            .ref = ref,
            .mode = Stream.Mode.readable(false),
        };

        self.stream_reader = .initWithTable(L, -1, undefined, &self.ref_table);

        return 1;
    }

    pub const __index = MethodMap.CreateStaticIndexMap(BufferStream, TAG_IO_BUFFERSTREAM, .{
        .{ "pos", lua_pos },
        .{ "size", lua_size },
        .{ "canRead", lua_canRead },
        .{ "write", lua_write },
        .{ "read", lua_read },
        .{ "seekTo", lua_seekTo },
        .{ "seekBy", lua_seekBy },
        .{ "writer", lua_writer },
        .{ "reader", lua_reader },
    });

    pub fn __dtor(L: *VM.lua.State, self: *BufferStream) void {
        self.buf.deref(L);
        self.ref_table.deinit(L);
        self.stream_writer.deref(L);
        self.stream_reader.deref(L);
    }

    pub const Impl: Stream.VTable = .{
        .write = Stream.GenericWrite(BufferStream, stream_write),
        .read = Stream.GenericRead(BufferStream, stream_read),
        .seekTo = Stream.GenericSeekTo(BufferStream, stream_seekTo),
        .seekBy = Stream.GenericSeekBy(BufferStream, stream_seekBy),
    };
    pub fn stream_write(self: *BufferStream, value: []const u8) anyerror!void {
        const buf = self.buf.value;
        const end = self.pos + value.len;
        if (end > buf.len)
            return error.OutOfBounds;
        std.mem.copyForwards(u8, buf[self.pos..end], value);
        self.pos = @intCast(end);
    }
    pub fn stream_read(self: *BufferStream, amount: u32, exact: bool) anyerror!?[]const u8 {
        const buf = self.buf.value;
        const offset = if (exact) amount else 0;
        if (self.pos + offset > buf.len)
            return null;
        const result = buf[self.pos..@min(self.pos + amount, buf.len)];
        if (result.len == 0)
            return null;
        self.pos += @intCast(result.len);
        return result;
    }
    pub fn stream_seekTo(self: *BufferStream, pos: u32) !void {
        self.pos = @min(pos, self.buf.value.len);
    }
    pub fn stream_seekBy(self: *BufferStream, offset: i32) anyerror!void {
        const buf = self.buf.value;
        if (offset < 0) {
            const amount = std.math.cast(u32, @abs(offset)) orelse std.math.maxInt(u32);
            if (amount > self.pos)
                self.pos = 0
            else
                self.pos -= amount;
        } else {
            const new_pos = std.math.add(
                u32,
                self.pos,
                std.math.cast(u32, offset) orelse std.math.maxInt(u32),
            ) catch std.math.maxInt(u32);
            self.pos = @min(buf.len, new_pos);
        }
    }
};

pub fn lua_createBufferSink(L: *VM.lua.State) !i32 {
    const allocator = luau.getallocator(L);

    const opts = try L.Zcheckvalue(?struct {
        limit: ?u32,
    }, 1, null);

    const self = L.newuserdatataggedwithmetatable(BufferSink, TAG_IO_BUFFERSINK);

    self.* = .{
        .alloc = allocator,
        .buf = .{},
        .limit = if (opts) |o| o.limit orelse MAX_LUAU_SIZE else MAX_LUAU_SIZE,
        .closed = false,
        .ref_table = .init(L, true),
    };

    return 1;
}

pub fn lua_createFixedBufferStream(L: *VM.lua.State) !i32 {
    const buffer = try L.Zcheckvalue([]u8, 1, null);

    const self = L.newuserdatataggedwithmetatable(BufferStream, TAG_IO_BUFFERSTREAM);

    self.* = .{
        .pos = 0,
        .buf = .init(L, 1, buffer),
        .ref_table = .init(L, true),
    };

    return 1;
}

pub var TERMINAL: ?Terminal = null;

pub fn loadLib(L: *VM.lua.State) void {
    {
        _ = L.Znewmetatable(@typeName(BufferSink), .{
            .__index = BufferSink.__index,
            .__namecall = BufferSink.__namecall,
            .__metatable = "Metatable is locked",
            .__type = "BufferSink",
        });
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_IO_BUFFERSINK);
        L.setuserdatadtor(BufferSink, TAG_IO_BUFFERSINK, BufferSink.__dtor);
    }
    {
        _ = L.Znewmetatable(@typeName(Stream), .{
            .__metatable = "Metatable is locked",
            .__type = "Stream",
        });
        Stream.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_IO_STREAM);
        L.setuserdatadtor(Stream, TAG_IO_STREAM, Stream.__dtor);
    }
    {
        _ = L.Znewmetatable(@typeName(BufferStream), .{
            .__metatable = "Metatable is locked",
            .__type = "BufferStream",
        });
        BufferStream.__index(L, -1);
        L.setreadonly(-1, true);
        L.setuserdatametatable(TAG_IO_BUFFERSTREAM);
        L.setuserdatadtor(BufferStream, TAG_IO_BUFFERSTREAM, BufferStream.__dtor);
    }
    L.createtable(0, 16);

    L.Zsetfield(-1, "MAX_READ", MAX_LUAU_SIZE);

    const stdIn = std.io.getStdIn();
    const stdOut = std.io.getStdOut();
    const stdErr = std.io.getStdErr();

    // StdIn
    File.push(L, stdIn, .Tty, .readable(.none)) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stdin");

    // StdOut
    File.push(L, stdOut, .Tty, .writable(.none)) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stdout");

    // StdErr
    File.push(L, stdErr, .Tty, .writable(.none)) catch |err| std.debug.panic("{}", .{err});
    L.setfield(-2, "stderr");

    // Terminal
    TERMINAL = Terminal.init(stdIn, stdOut);
    {
        L.newtable();

        L.Zsetfieldfn(-1, "enableRawMode", LuaTerminal.lua_enableRawMode);
        L.Zsetfieldfn(-1, "restoreMode", LuaTerminal.lua_restoreMode);
        L.Zsetfieldfn(-1, "getSize", LuaTerminal.lua_getSize);
        L.Zsetfieldfn(-1, "getCurrentMode", LuaTerminal.lua_getCurrentMode);

        L.Zsetfield(-1, "isTTY", TERMINAL.?.stdin_istty and TERMINAL.?.stdout_istty);

        L.setreadonly(-1, true);
    }
    L.setfield(-2, "terminal");

    TERMINAL.?.setOutputMode() catch std.debug.print("[Win32] Failed to set output codepoint\n", .{});

    L.Zsetfieldfn(-1, "format", Fmt.args);

    L.Zsetfieldfn(-1, "createBufferSink", lua_createBufferSink);
    L.Zsetfieldfn(-1, "createFixedBufferStream", lua_createFixedBufferStream);

    L.setreadonly(-1, true);
    LuaHelper.registerModule(L, LIB_NAME);
}

test "io" {
    const TestRunner = @import("../utils/testrunner.zig");

    const testResult = try TestRunner.runTest(
        TestRunner.newTestFile("standard/io.test.luau"),
        &.{},
        .{},
    );

    try std.testing.expect(testResult.failed == 0);
    try std.testing.expect(testResult.total > 0);
}
