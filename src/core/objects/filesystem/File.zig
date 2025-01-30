const std = @import("std");
const aio = @import("aio");
const luau = @import("luau");
const builtin = @import("builtin");

const tagged = @import("../../../tagged.zig");
const method_map = @import("../../utils/method_map.zig");
const luaHelper = @import("../../utils/luahelper.zig");

const Scheduler = @import("../../runtime/scheduler.zig");

const VM = luau.VM;

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
    lua_type: VM.lua.Type = .String,
    auto_close: bool = true,

    offset: usize = 0,
    buffer_len: usize = 0,
    limit: usize = luaHelper.MAX_LUAU_SIZE,
    array: std.ArrayList(u8) = undefined,
    resumed: bool = false,

    out_read: usize = 0,
    out_error: aio.Read.Error = error.Unexpected,
    out_close_error: aio.CloseFile.Error = error.Unexpected,

    fn end(ctx: *ReadAsyncContext, L: *VM.lua.State, scheduler: *Scheduler, err: ?anyerror) void {
        if (ctx.auto_close) {
            scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.op(.close_file, .{
                .file = ctx.file,
                .out_error = &ctx.out_close_error,
            }, .unlinked), finished) catch |e| {
                std.debug.print("Failed to queue close: {}\n", .{e});
            };
        }

        if (err) |e| {
            if (e != error.None) {
                defer if (!ctx.auto_close) ctx.cleanup(L);
                L.pushstring(@errorName(e));
                ctx.resumeResult(L, .Bad);
            }
        }

        if (!ctx.auto_close) {
            defer ctx.cleanup(L);
            ctx.resumeResult(L, .Ok);
        }
    }

    fn completion(ctx: *ReadAsyncContext, L: *VM.lua.State, scheduler: *Scheduler, failed: bool) void {
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

        scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.op(.read, .{
            .file = ctx.file,
            .offset = ctx.offset,
            .buffer = ctx.array.items[ctx.offset..],
            .out_read = &ctx.out_read,
            .out_error = &ctx.out_error,
        }, .unlinked), completion) catch |err| return ctx.end(L, scheduler, err);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(ctx: *ReadAsyncContext, L: *VM.lua.State, comptime kind: Kind) void {
        if (ctx.resumed)
            return;
        ctx.resumed = true;
        switch (kind) {
            .Ok => {
                ctx.array.shrinkAndFree(ctx.buffer_len);
                switch (ctx.lua_type) {
                    .Buffer => L.Zpushbuffer(ctx.array.items),
                    .String => L.pushlstring(ctx.array.items),
                    else => unreachable,
                }
                _ = Scheduler.resumeState(L, null, 1) catch {};
            },
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    fn finished(ctx: *ReadAsyncContext, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
        defer ctx.cleanup(L);

        if (failed) {
            L.pushstring(@errorName(ctx.out_close_error));
            return ctx.resumeResult(L, .Bad);
        }

        ctx.resumeResult(L, .Ok);
    }

    fn cleanup(ctx: *ReadAsyncContext, L: *VM.lua.State) void {
        const allocator = luau.getallocator(L);
        defer allocator.destroy(ctx);
        defer ctx.array.deinit();
    }

    pub fn queue(
        L: *VM.lua.State,
        file: std.fs.File,
        useBuffer: bool,
        pre_alloc_size: usize,
        max_size: usize,
        auto_close: bool,
    ) !i32 {
        if (!L.isyieldable())
            return error.RaiseLuauYieldError;
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

        const ctx = try allocator.create(ReadAsyncContext);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .file = file,
            .lua_type = if (useBuffer) .Buffer else .String,
            .array = try std.ArrayList(u8).initCapacity(allocator, pre_alloc_size),
            .limit = max_size,
            .auto_close = auto_close,
        };

        ctx.array.expandToCapacity();

        try scheduler.queueIoCallbackCtx(ReadAsyncContext, ctx, L, aio.op(.read, .{
            .file = file,
            .buffer = ctx.array.items[ctx.offset..],
            .out_read = &ctx.out_read,
            .out_error = &ctx.out_error,
        }, .unlinked), ReadAsyncContext.completion);

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

    fn end(ctx: *WriteAsyncContext, L: *VM.lua.State, scheduler: *Scheduler, err: ?anyerror) void {
        if (ctx.auto_close) {
            scheduler.queueIoCallbackCtx(WriteAsyncContext, ctx, L, aio.op(.close_file, .{
                .file = ctx.file,
                .out_error = &ctx.out_close_error,
            }, .unlinked), finished) catch |e| {
                std.debug.print("Failed to queue close: {}\n", .{e});
            };
        }

        if (err) |e| {
            if (e != error.None) {
                defer if (!ctx.auto_close) ctx.cleanup(L);
                L.pushstring(@errorName(e));
                ctx.resumeResult(L, .Bad);
            }
            return;
        }

        if (!ctx.auto_close) {
            defer ctx.cleanup(L);
            ctx.resumeResult(L, .Ok);
        }
    }

    fn completion(ctx: *WriteAsyncContext, L: *VM.lua.State, scheduler: *Scheduler, failed: bool) void {
        if (failed)
            return ctx.end(L, scheduler, ctx.out_error);

        ctx.offset += ctx.out_written;

        if (ctx.out_written == ctx.data.len) {
            return ctx.end(L, scheduler, null);
        }

        ctx.data = ctx.data[ctx.out_written..];

        scheduler.queueIoCallbackCtx(WriteAsyncContext, ctx, L, aio.op(.write, .{
            .file = ctx.file,
            .offset = ctx.offset,
            .buffer = ctx.data,
            .out_written = &ctx.out_written,
            .out_error = &ctx.out_error,
        }, .unlinked), completion) catch |err| return ctx.end(L, scheduler, err);
    }

    const Kind = enum {
        Ok,
        Bad,
    };
    fn resumeResult(ctx: *WriteAsyncContext, L: *VM.lua.State, comptime kind: Kind) void {
        if (ctx.resumed)
            return;
        ctx.resumed = true;
        switch (kind) {
            .Ok => _ = Scheduler.resumeState(L, null, 0) catch {},
            .Bad => _ = Scheduler.resumeStateError(L, null) catch {},
        }
    }

    fn finished(ctx: *WriteAsyncContext, L: *VM.lua.State, _: *Scheduler, failed: bool) void {
        defer ctx.cleanup(L);

        if (failed) {
            L.pushstring(@errorName(ctx.out_close_error));
            return ctx.resumeResult(L, .Bad);
        }

        ctx.resumeResult(L, .Ok);
    }

    fn cleanup(ctx: *WriteAsyncContext, L: *VM.lua.State) void {
        const allocator = luau.getallocator(L);
        defer allocator.destroy(ctx);
        defer allocator.free(ctx.buffer);
    }

    pub fn queue(L: *VM.lua.State, file: std.fs.File, data: []const u8, auto_close: bool, offset: u64) !i32 {
        if (!L.isyieldable())
            return error.RaiseLuauYieldError;
        const scheduler = Scheduler.getScheduler(L);
        const allocator = luau.getallocator(L);

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

        try scheduler.queueIoCallbackCtx(File.WriteAsyncContext, ctx, L, aio.op(.write, .{
            .file = file,
            .buffer = ctx.data,
            .offset = offset,
            .out_written = &ctx.out_written,
            .out_error = &ctx.out_error,
        }, .unlinked), File.WriteAsyncContext.completion);

        return L.yield(0);
    }
};

pub fn __index(L: *VM.lua.State) i32 {
    L.Lchecktype(1, .Userdata);
    // const index = L.Lcheckstring(2);
    // const ptr = L.touserdata(FileObject, 1) catch return 0;

    return 0;
}

fn write(self: *File, L: *VM.lua.State) !i32 {
    const data = if (L.isbuffer(2)) L.Lcheckbuffer(2) else L.Lcheckstring(2);

    const pos = try self.handle.getPos();

    return File.WriteAsyncContext.queue(L, self.handle, data, false, pos);
}

fn writeSync(self: *File, L: *VM.lua.State) !i32 {
    const data = if (L.isbuffer(2)) L.Lcheckbuffer(2) else L.Lcheckstring(2);

    try self.handle.writeAll(data);

    return 0;
}

fn append(self: *File, L: *VM.lua.State) !i32 {
    const string = if (L.isbuffer(2)) L.Lcheckbuffer(2) else L.Lcheckstring(2);

    try self.handle.seekFromEnd(0);
    try self.handle.writeAll(string);

    return 0;
}

fn getSeekPosition(self: *File, L: *VM.lua.State) !i32 {
    L.pushinteger(@intCast(try self.handle.getPos()));
    return 1;
}

fn getSize(self: *File, L: *VM.lua.State) !i32 {
    L.pushinteger(@intCast(try self.handle.getEndPos()));
    return 1;
}

fn seekFromEnd(self: *File, L: *VM.lua.State) !i32 {
    try self.handle.seekFromEnd(@intCast(L.Loptinteger(2, 0)));
    return 0;
}

fn seekTo(self: *File, L: *VM.lua.State) !i32 {
    try self.handle.seekTo(@intCast(L.Loptinteger(2, 0)));
    return 0;
}

fn seekBy(self: *File, L: *VM.lua.State) !i32 {
    try self.handle.seekBy(@intCast(L.Loptinteger(2, 1)));
    return 0;
}

fn read(self: *File, L: *VM.lua.State) !i32 {
    // const scheduler = Scheduler.getScheduler(L);
    const size = L.Loptinteger(2, luaHelper.MAX_LUAU_SIZE);
    const data = try self.handle.readToEndAlloc(luau.getallocator(L), @intCast(size));
    defer luau.getallocator(L).free(data);

    return ReadAsyncContext.queue(L, self.handle, L.Loptboolean(3, false), 1024, @intCast(size), false);
}

fn readSync(self: *File, L: *VM.lua.State) !i32 {
    // const scheduler = Scheduler.getScheduler(L);
    const allocator = luau.getallocator(L);
    const size = L.Loptinteger(2, luaHelper.MAX_LUAU_SIZE);
    const useBuffer = L.Loptboolean(3, false);
    const data = try self.handle.readToEndAlloc(allocator, @intCast(size));
    defer allocator.free(data);

    if (useBuffer)
        L.Zpushbuffer(data)
    else
        L.pushlstring(data);

    return 1;
}

fn lock(self: *File, L: *VM.lua.State) !i32 {
    var lockOpt: std.fs.File.Lock = .exclusive;
    if (L.typeOf(2) == .String) {
        const lockType = L.tostring(2) orelse unreachable;
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
        L.pushboolean(true);
    } else {
        L.pushboolean(try self.handle.tryLock(lockOpt));
    }
    return 1;
}

fn unlock(self: *File, L: *VM.lua.State) !i32 {
    _ = L;
    self.handle.unlock();
    return 0;
}

fn sync(self: *File, L: *VM.lua.State) !i32 {
    const scheduler = Scheduler.getScheduler(L);

    try scheduler.queueIoCallback(L, aio.op(.fsync, .{
        .file = self.handle,
    }, .unlinked), Scheduler.asyncIoResumeState);

    return L.yield(0);
}

fn readonly(self: *File, L: *VM.lua.State) !i32 {
    const meta = try self.handle.metadata();
    var permissions = meta.permissions();
    const enabled = if (L.typeOf(2) != .Boolean) {
        L.pushboolean(permissions.readOnly());
        return 1;
    } else L.toboolean(2);
    permissions.setReadOnly(enabled);
    try self.handle.setPermissions(permissions);
    return 0;
}

fn closeAsync(self: *File, L: *VM.lua.State) !i32 {
    if (self.open) {
        self.open = false;
        const scheduler = Scheduler.getScheduler(L);
        try scheduler.queueIoCallback(L, aio.op(.close_file, .{
            .file = self.handle,
        }, .unlinked), Scheduler.asyncIoResumeState);
        return L.yield(0);
    }
    return 0;
}

fn before_method(self: *File, L: *VM.lua.State) !void {
    if (!self.open)
        return L.Zerror("File is closed");
}

const __namecall = method_map.CreateNamecallMap(File, .{
    .{ "write", method_map.WithFn(File, write, before_method) },
    .{ "writeSync", method_map.WithFn(File, writeSync, before_method) },
    .{ "append", method_map.WithFn(File, append, before_method) },
    .{ "getSeekPosition", method_map.WithFn(File, getSeekPosition, before_method) },
    .{ "getSize", method_map.WithFn(File, getSize, before_method) },
    .{ "seekFromEnd", method_map.WithFn(File, seekFromEnd, before_method) },
    .{ "seekTo", method_map.WithFn(File, seekTo, before_method) },
    .{ "seekBy", method_map.WithFn(File, seekBy, before_method) },
    .{ "read", method_map.WithFn(File, read, before_method) },
    .{ "readSync", method_map.WithFn(File, readSync, before_method) },
    .{ "lock", method_map.WithFn(File, lock, before_method) },
    .{ "unlock", method_map.WithFn(File, unlock, before_method) },
    .{ "sync", method_map.WithFn(File, sync, before_method) },
    .{ "readonly", method_map.WithFn(File, readonly, before_method) },
    .{ "close", closeAsync },
});

pub fn __dtor(L: *VM.lua.State, ptr: *File) void {
    _ = L;
    if (ptr.open)
        ptr.handle.close();
}

pub inline fn load(L: *VM.lua.State) void {
    _ = L.Lnewmetatable(@typeName(@This()));

    L.Zsetfieldfn(-1, luau.Metamethods.index, __index); // metatable.__index
    L.Zsetfieldfn(-1, luau.Metamethods.namecall, __namecall); // metatable.__namecall

    L.Zsetfield(-1, luau.Metamethods.metatable, "Metatable is locked");

    L.setuserdatametatable(tagged.FS_FILE, -1);
    L.setuserdatadtor(File, tagged.FS_FILE, __dtor);
}

pub fn push(L: *VM.lua.State, file: std.fs.File, kind: FileKind) void {
    const ptr = L.newuserdatataggedwithmetatable(File, tagged.FS_FILE);
    ptr.* = .{
        .handle = file,
        .kind = kind,
    };
}
