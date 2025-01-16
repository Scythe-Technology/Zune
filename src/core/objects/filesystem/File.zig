const std = @import("std");
const aio = @import("aio");
const luau = @import("luau");
const builtin = @import("builtin");

const tagged = @import("../../../tagged.zig");
const method_map = @import("../../utils/method_map.zig");
const luaHelper = @import("../../utils/luahelper.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const Luau = luau.Luau;

const File = @This();

pub const FileKind = enum {
    File,
    Tty,
};

handle: std.fs.File,
open: bool = true,
kind: FileKind = .File,

pub const ReadAsyncContext = struct {
    file: std.fs.File,
    lua_type: luau.LuaType = .string,
    auto_close: bool = true,

    offset: usize = 0,
    buffer_len: usize = 0,
    limit: usize = luaHelper.MAX_LUAU_SIZE,
    array: std.ArrayList(u8) = undefined,
    resumed: bool = false,

    out_read: usize = 0,
    out_error: aio.Read.Error = error.Unexpected,
    out_close_error: aio.CloseFile.Error = error.Unexpected,

    fn end(ctx: *ReadAsyncContext, L: *Luau, scheduler: *Scheduler, err: ?anyerror) void {
        if (ctx.auto_close) {
            scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.CloseFile{
                .file = ctx.file,
                .out_error = &ctx.out_close_error,
            }, finished) catch |e| {
                std.debug.print("Failed to queue close: {}\n", .{e});
            };
        }

        if (err) |e| {
            if (e != error.None) {
                defer if (!ctx.auto_close) ctx.cleanup(L);
                L.pushString(@errorName(e));
                ctx.resumeResult(L, .Bad);
            }
        }

        if (!ctx.auto_close) {
            defer ctx.cleanup(L);
            ctx.resumeResult(L, .Ok);
        }
    }

    fn completion(ctx: *ReadAsyncContext, L: *Luau, scheduler: *Scheduler, failed: bool) void {
        if (failed)
            return ctx.end(L, scheduler, ctx.out_error);

        ctx.offset += ctx.out_read;
        ctx.buffer_len += ctx.out_read;

        if (ctx.out_read == 0 or ctx.buffer_len > ctx.limit) {
            return ctx.end(L, scheduler, null);
        }

        ctx.array.ensureTotalCapacity(ctx.buffer_len + ctx.offset + 1) catch |err| return ctx.end(L, scheduler, err);
        if (ctx.array.capacity > ctx.limit)
            ctx.array.shrinkAndFree(ctx.limit);
        ctx.array.expandToCapacity();

        scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.Read{
            .file = ctx.file,
            .offset = ctx.offset,
            .buffer = ctx.array.items[ctx.offset..],
            .out_read = &ctx.out_read,
            .out_error = &ctx.out_error,
        }, completion) catch |err| return ctx.end(L, scheduler, err);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(ctx: *ReadAsyncContext, L: *Luau, comptime kind: Kind) void {
        if (ctx.resumed)
            return;
        ctx.resumed = true;
        switch (kind) {
            .Ok => {
                ctx.array.shrinkAndFree(ctx.buffer_len);
                switch (ctx.lua_type) {
                    .buffer => L.pushBuffer(ctx.array.items),
                    .string => L.pushLString(ctx.array.items),
                    else => unreachable,
                }
                _ = Scheduler.resumeState(L, null, 1) catch {};
            },
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    fn finished(ctx: *ReadAsyncContext, L: *Luau, _: *Scheduler, failed: bool) void {
        defer ctx.cleanup(L);

        if (failed) {
            L.pushString(@errorName(ctx.out_close_error));
            return ctx.resumeResult(L, .Bad);
        }

        ctx.resumeResult(L, .Ok);
    }

    fn cleanup(ctx: *ReadAsyncContext, L: *Luau) void {
        const allocator = L.allocator();
        defer allocator.destroy(ctx);
        defer ctx.array.deinit();
    }

    pub fn queue(
        L: *Luau,
        file: std.fs.File,
        useBuffer: bool,
        pre_alloc_size: usize,
        max_size: usize,
        auto_close: bool,
    ) !i32 {
        if (!L.isYieldable())
            return error.RaiseLuauYieldError;
        const scheduler = Scheduler.getScheduler(L);
        const allocator = L.allocator();

        const ctx = try allocator.create(ReadAsyncContext);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .file = file,
            .lua_type = if (useBuffer) .buffer else .string,
            .array = try std.ArrayList(u8).initCapacity(allocator, pre_alloc_size),
            .limit = max_size,
            .auto_close = auto_close,
        };

        ctx.array.expandToCapacity();

        try scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.Read{
            .file = file,
            .buffer = ctx.array.items[ctx.offset..],
            .out_read = &ctx.out_read,
            .out_error = &ctx.out_error,
        }, ReadAsyncContext.completion);

        return L.yield(0);
    }
};

pub const WriteAsyncContext = struct {
    auto_close: bool = true,

    file: std.fs.File,
    offset: usize = 0,
    data: []u8,
    buffer: []u8,
    resumed: bool = false,

    out_written: usize = 0,
    out_error: aio.Write.Error = error.Unexpected,
    out_close_error: aio.CloseFile.Error = error.Unexpected,

    fn end(ctx: *WriteAsyncContext, L: *Luau, scheduler: *Scheduler, err: ?anyerror) void {
        if (ctx.auto_close) {
            scheduler.queueIoCallbackCtx(WriteAsyncContext, ctx, L, aio.CloseFile{
                .file = ctx.file,
                .out_error = &ctx.out_close_error,
            }, finished) catch |e| {
                std.debug.print("Failed to queue close: {}\n", .{e});
            };
        }

        if (err) |e| {
            if (e != error.None) {
                defer if (!ctx.auto_close) ctx.cleanup(L);
                L.pushString(@errorName(e));
                ctx.resumeResult(L, .Bad);
            }
            return;
        }

        if (!ctx.auto_close) {
            defer ctx.cleanup(L);
            ctx.resumeResult(L, .Ok);
        }
    }

    fn completion(ctx: *WriteAsyncContext, L: *Luau, scheduler: *Scheduler, failed: bool) void {
        if (failed)
            return ctx.end(L, scheduler, ctx.out_error);

        ctx.offset += ctx.out_written;

        if (ctx.out_written == ctx.data.len) {
            return ctx.end(L, scheduler, null);
        }

        ctx.data = ctx.data[ctx.out_written..];

        scheduler.queueIoCallbackCtx(WriteAsyncContext, ctx, L, aio.Write{
            .file = ctx.file,
            .offset = ctx.offset,
            .buffer = ctx.data,
            .out_written = &ctx.out_written,
            .out_error = &ctx.out_error,
        }, completion) catch |err| return ctx.end(L, scheduler, err);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(ctx: *WriteAsyncContext, L: *Luau, comptime kind: Kind) void {
        if (ctx.resumed)
            return;
        ctx.resumed = true;
        switch (kind) {
            .Ok => _ = Scheduler.resumeState(L, null, 0) catch {},
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    fn finished(ctx: *WriteAsyncContext, L: *Luau, _: *Scheduler, failed: bool) void {
        defer ctx.cleanup(L);

        if (failed) {
            L.pushString(@errorName(ctx.out_close_error));
            return ctx.resumeResult(L, .Bad);
        }

        ctx.resumeResult(L, .Ok);
    }

    fn cleanup(ctx: *WriteAsyncContext, L: *Luau) void {
        const allocator = L.allocator();
        defer allocator.destroy(ctx);
        defer allocator.free(ctx.buffer);
    }

    pub fn queue(L: *Luau, file: std.fs.File, data: []const u8, auto_close: bool, offset: u64) !i32 {
        if (!L.isYieldable())
            return error.RaiseLuauYieldError;
        const scheduler = Scheduler.getScheduler(L);
        const allocator = L.allocator();

        const ctx = try allocator.create(File.WriteAsyncContext);
        errdefer allocator.destroy(ctx);

        const copy = try allocator.dupe(u8, data);
        errdefer allocator.free(copy);

        ctx.* = .{
            .file = file,
            .data = copy,
            .buffer = copy,
            .auto_close = auto_close,
        };

        try scheduler.queueIoCallbackCtx(File.WriteAsyncContext, ctx, L, aio.Write{
            .file = file,
            .buffer = ctx.data,
            .offset = offset,
            .out_written = &ctx.out_written,
            .out_error = &ctx.out_error,
        }, File.WriteAsyncContext.completion);

        return L.yield(0);
    }
};

pub fn __index(L: *Luau) i32 {
    L.checkType(1, .userdata);
    // const index = L.checkString(2);
    // const ptr = L.toUserdata(FileObject, 1) catch return 0;

    return 0;
}

fn write(self: *File, L: *Luau) !i32 {
    if (!self.open)
        return L.Error("File is closed");
    const data = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);

    const pos = try self.handle.getPos();

    return File.WriteAsyncContext.queue(L, self.handle, data, false, pos);
}

fn writeSync(self: *File, L: *Luau) !i32 {
    const data = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);

    try self.handle.writeAll(data);

    return 0;
}

fn append(self: *File, L: *Luau) !i32 {
    const string = if (L.isBuffer(2)) L.checkBuffer(2) else L.checkString(2);

    try self.handle.seekFromEnd(0);
    try self.handle.writeAll(string);

    return 0;
}

fn getSeekPosition(self: *File, L: *Luau) !i32 {
    L.pushInteger(@intCast(try self.handle.getPos()));
    return 1;
}

fn getSize(self: *File, L: *Luau) !i32 {
    L.pushInteger(@intCast(try self.handle.getEndPos()));
    return 1;
}

fn seekFromEnd(self: *File, L: *Luau) !i32 {
    try self.handle.seekFromEnd(@intCast(L.optInteger(2) orelse 0));
    return 0;
}

fn seekTo(self: *File, L: *Luau) !i32 {
    try self.handle.seekTo(@intCast(L.optInteger(2) orelse 0));
    return 0;
}

fn seekBy(self: *File, L: *Luau) !i32 {
    try self.handle.seekBy(@intCast(L.optInteger(2) orelse 1));
    return 0;
}

fn read(self: *File, L: *Luau) !i32 {
    // const scheduler = Scheduler.getScheduler(L);
    const size = L.optInteger(2) orelse luaHelper.MAX_LUAU_SIZE;
    const data = try self.handle.readToEndAlloc(L.allocator(), @intCast(size));
    defer L.allocator().free(data);

    return ReadAsyncContext.queue(L, self.handle, L.optBoolean(3) orelse false, 1024, @intCast(size), false);
}

fn readSync(self: *File, L: *Luau) !i32 {
    // const scheduler = Scheduler.getScheduler(L);
    const allocator = L.allocator();
    const size = L.optInteger(2) orelse luaHelper.MAX_LUAU_SIZE;
    const useBuffer = L.optBoolean(3) orelse false;
    const data = try self.handle.readToEndAlloc(allocator, @intCast(size));
    defer allocator.free(data);

    if (useBuffer)
        L.pushBuffer(data)
    else
        L.pushLString(data);

    return 1;
}

fn lock(self: *File, L: *Luau) !i32 {
    var lockOpt: std.fs.File.Lock = .exclusive;
    if (L.typeOf(2) == .string) {
        const lockType = L.toString(2) catch unreachable;
        if (std.mem.eql(u8, lockType, "shared")) {
            lockOpt = .shared;
        } else if (!std.mem.eql(u8, lockType, "exclusive")) {
            lockOpt = .exclusive;
        } else if (!std.mem.eql(u8, lockType, "none")) {
            lockOpt = .none;
        }
    }
    if (builtin.os.tag == .windows) {
        switch (lockOpt) {
            .none => {},
            .shared, .exclusive => {
                var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
                const range_off: std.os.windows.LARGE_INTEGER = 0;
                const range_len: std.os.windows.LARGE_INTEGER = 1;
                std.os.windows.LockFile(
                    self.handle.handle,
                    null,
                    null,
                    null,
                    &io_status_block,
                    &range_off,
                    &range_len,
                    null,
                    std.os.windows.FALSE, // non-blocking=false
                    @intFromBool(lockOpt == .exclusive),
                ) catch |err| switch (err) {
                    error.WouldBlock => unreachable, // non-blocking=false
                    else => |e| return e,
                };
            },
        }
        L.pushBoolean(true);
    } else {
        L.pushBoolean(try self.handle.tryLock(lockOpt));
    }
    return 1;
}

fn unlock(self: *File, L: *Luau) !i32 {
    _ = L;
    self.handle.unlock();
    return 0;
}

fn sync(self: *File, L: *Luau) !i32 {
    const scheduler = Scheduler.getScheduler(L);

    try scheduler.queueIoCallback(L, aio.Fsync{
        .file = self.handle,
    }, Scheduler.asyncIoResumeState);

    return L.yield(0);
}

fn readonly(self: *File, L: *Luau) !i32 {
    const meta = try self.handle.metadata();
    var permissions = meta.permissions();
    const enabled = L.optBoolean(2) orelse {
        L.pushBoolean(permissions.readOnly());
        return 1;
    };
    permissions.setReadOnly(enabled);
    try self.handle.setPermissions(permissions);
    return 0;
}

fn close(self: *File, L: *Luau) !i32 {
    _ = L;
    if (self.open) {
        self.handle.close();
    }
    self.open = false;
    return 0;
}

const __namecall = method_map.CreateNamecallMap(File, .{
    .{ "write", write },
    .{ "writeSync", writeSync },
    .{ "append", append },
    .{ "getSeekPosition", getSeekPosition },
    .{ "getSize", getSize },
    .{ "seekFromEnd", seekFromEnd },
    .{ "seekTo", seekTo },
    .{ "seekBy", seekBy },
    .{ "read", read },
    .{ "readSync", readSync },
    .{ "lock", lock },
    .{ "unlock", unlock },
    .{ "sync", sync },
    .{ "readonly", readonly },
    .{ "close", close },
});

pub fn __dtor(L: *Luau, ptr: *File) void {
    _ = L;
    if (ptr.open)
        ptr.handle.close();
    ptr.open = false;
}

pub inline fn load(L: *Luau) void {
    L.newMetatable(@typeName(@This())) catch std.debug.panic("InternalError (Luau Failed to create Internal Metatable)", .{});

    L.setFieldFn(-1, luau.Metamethods.index, __index); // metatable.__index
    L.setFieldFn(-1, luau.Metamethods.namecall, __namecall); // metatable.__namecall

    L.setFieldString(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setUserdataMetatable(tagged.FS_FILE, -1);
    L.setUserdataDtor(File, tagged.FS_FILE, __dtor);
}

pub fn pushFile(L: *Luau, file: std.fs.File, kind: FileKind) void {
    const ptr = L.newUserdataTaggedWithMetatable(File, tagged.FS_FILE);
    ptr.* = .{
        .handle = file,
        .kind = kind,
    };
}
